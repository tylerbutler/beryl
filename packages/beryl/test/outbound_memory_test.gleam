import app_test_helper
import beryl
import beryl/socket
import beryl/transport
import beryl/transport/server
import beryl/wire
import beryl/wire/codec
import gleam/bit_array
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import test_helper
import unitest

const backing_bytes = 8_388_608

@external(erlang, "beryl_diagnostic_test_ffi", "retained_slice")
fn retained_slice() -> BitArray

@external(erlang, "beryl_diagnostic_test_ffi", "referenced_byte_size")
fn referenced_byte_size(data: BitArray) -> Int

type FrameKind {
  Text
  Binary
}

type Connection {
  Connection(
    state: server.ConnectionState,
    selector: process.Selector(server.SendRequest),
    sender: socket.Sender(Nil),
    evicted: process.Subject(Nil),
  )
}

fn frame(kind: FrameKind) -> codec.Frame {
  let data = retained_slice()
  bit_array.byte_size(data) |> should.equal(128)
  referenced_byte_size(data) |> should.equal(backing_bytes)
  case kind {
    Text -> {
      let assert Ok(text) = bit_array.to_string(data)
      codec.TextFrame(text)
    }
    Binary -> codec.BinaryFrame(data)
  }
}

fn start_app(
  kind: FrameKind,
) -> #(beryl.Sockets, process.Subject(socket.Sender(Nil))) {
  let connected = process.new_subject()
  let codec =
    codec.new(
      decode_text: wire.decode_message,
      encode_reply: fn(_, _, _, _, _) { frame(kind) },
      encode_push: fn(_, _, _) { frame(kind) },
      encode_heartbeat_reply: fn(_) { frame(kind) },
    )
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(codec),
      init: fn(info) {
        process.send(connected, info.self)
        #(Nil, [])
      },
      update: fn(model, input) {
        case input {
          socket.Message(_, _, _, Some(ref)) ->
            socket.Next(model, [socket.ReplyOk(ref, json.null())])
          socket.Join(..)
          | socket.Message(_, _, _, None)
          | socket.Binary(..)
          | socket.Closed(..)
          | socket.Info(..) -> app_test_helper.accepting_update(model, input)
        }
      },
    )
  #(sockets, connected)
}

fn connect(
  sockets: beryl.Sockets,
  connected: process.Subject(socket.Sender(Nil)),
  max_frames: Int,
  max_bytes: Int,
) -> Connection {
  let assert Ok(config) =
    server.default_config("/socket")
    |> server.with_outbound_limits(max_frames:, max_bytes:)
  let assert Ok(connection_permit) =
    transport.acquire_connection_slot(sockets, "127.0.0.1")
  let evicted = process.new_subject()
  let #(state, selector) =
    server.init_connection(
      sockets:,
      seed: socket.empty_seed(),
      connection_permit:,
      base_selector: process.new_selector(),
      config:,
      force_close: fn() {
        process.send(evicted, Nil)
        Ok(Nil)
      },
      logger_name: "beryl.outbound.memory.test",
      telemetry: transport.telemetry(sockets, transport.Mist),
      codec: None,
    )
  let assert Ok(sender) = process.receive(connected, 500)
  Connection(state, selector, sender, evicted)
}

fn join(connection: Connection) -> Nil {
  let assert server.Continue(_) =
    server.handle_text_frame(
      connection.state,
      "[\"join\",\"join\",\"room:test\",\"phx_join\",{}]",
    )
  Nil
}

fn reply(connection: Connection) -> Nil {
  let assert server.Continue(_) =
    server.handle_text_frame(
      connection.state,
      "[\"join\",\"reply\",\"room:test\",\"echo\",{}]",
    )
  Nil
}

fn receive_frame(connection: Connection, kind: FrameKind) -> Int {
  let assert Ok(request) = process.selector_receive(connection.selector, 500)
  let #(data, bytes) = case kind, request {
    Text, server.SendText(text, bytes) -> #(bit_array.from_string(text), bytes)
    Binary, server.SendBinary(data, bytes) -> #(data, bytes)
    _, _ -> panic as "Unexpected outbound request"
  }
  bit_array.byte_size(data) |> should.equal(128)
  referenced_byte_size(data) |> should.equal(backing_bytes)
  bytes |> should.equal(backing_bytes)
  // The runtime has released both callback output and pending reply leases.
  test_helper.wait_until(
    fn() {
      let assert Ok(occupancy) = socket.queue_snapshot(connection.sender)
      occupancy.items == 0 && occupancy.bytes == 0
    },
    500,
    1,
  )
  bytes
}

fn complete(connection: Connection, bytes: Int) -> Nil {
  let assert server.Continue(_) =
    server.finish_outbound_write(connection.state, bytes, True)
  Nil
}

fn assert_evicted(connection: Connection) -> Nil {
  process.receive(connection.evicted, 500) |> should.equal(Ok(Nil))
  process.selector_receive(connection.selector, 0) |> should.equal(Error(Nil))
}

pub fn retained_text_and_binary_exceed_logical_byte_budget_test() -> Nil {
  list.each([Text, Binary], fn(kind) {
    let #(sockets, connected) = start_app(kind)
    let connection = connect(sockets, connected, 10, 256)
    join(connection)
    assert_evicted(connection)
    server.close_connection(connection.state)
    let assert Ok(Nil) = beryl.stop(sockets)
  })
}

pub fn retained_bytes_remain_charged_after_runtime_release_test() -> Nil {
  use <- unitest.tag("serial")
  list.each([Text, Binary], fn(kind) {
    let #(sockets, connected) = start_app(kind)
    let slow = connect(sockets, connected, 10, 2 * backing_bytes)
    let healthy = connect(sockets, connected, 1, backing_bytes)
    join(slow)
    let first = receive_frame(slow, kind)
    reply(slow)
    let second = receive_frame(slow, kind)
    reply(slow)
    assert_evicted(slow)
    complete(slow, first)
    complete(slow, second)
    server.close_connection(slow.state)

    join(healthy)
    complete(healthy, receive_frame(healthy, kind))
    reply(healthy)
    complete(healthy, receive_frame(healthy, kind))
    process.receive(healthy.evicted, 0) |> should.equal(Error(Nil))
    server.close_connection(healthy.state)
    let assert Ok(Nil) = beryl.stop(sockets)
  })
}

pub fn retained_frames_still_obey_frame_count_limit_test() -> Nil {
  use <- unitest.tag("serial")
  list.each([Text, Binary], fn(kind) {
    let #(sockets, connected) = start_app(kind)
    let connection = connect(sockets, connected, 1, 2 * backing_bytes)
    join(connection)
    let bytes = receive_frame(connection, kind)
    reply(connection)
    assert_evicted(connection)
    complete(connection, bytes)
    server.close_connection(connection.state)
    let assert Ok(Nil) = beryl.stop(sockets)
  })
}

pub fn retained_completion_releases_only_its_own_charge_test() -> Nil {
  use <- unitest.tag("serial")
  list.each([Text, Binary], fn(kind) {
    let #(sockets, connected) = start_app(kind)
    let connection = connect(sockets, connected, 10, 2 * backing_bytes)
    join(connection)
    let first = receive_frame(connection, kind)
    reply(connection)
    let second = receive_frame(connection, kind)
    complete(connection, first)
    reply(connection)
    let third = receive_frame(connection, kind)
    reply(connection)
    assert_evicted(connection)
    complete(connection, second)
    complete(connection, third)
    server.close_connection(connection.state)
    let assert Ok(Nil) = beryl.stop(sockets)
  })
}

pub fn retained_reservations_close_on_write_failure_test() -> Nil {
  use <- unitest.tag("serial")
  list.each([Text, Binary], fn(kind) {
    let #(sockets, connected) = start_app(kind)
    let connection = connect(sockets, connected, 2, 2 * backing_bytes)
    join(connection)
    let first = receive_frame(connection, kind)
    reply(connection)
    let second = receive_frame(connection, kind)
    let assert server.Stop =
      server.finish_outbound_write(connection.state, first, False)
    complete(connection, second)
    reply(connection)
    assert_evicted(connection)
    server.close_connection(connection.state)
    let assert Ok(Nil) = beryl.stop(sockets)
  })
}

pub fn retained_reservations_allow_late_completion_after_close_test() -> Nil {
  use <- unitest.tag("serial")
  list.each([Text, Binary], fn(kind) {
    let #(sockets, connected) = start_app(kind)
    let connection = connect(sockets, connected, 1, backing_bytes)
    join(connection)
    let bytes = receive_frame(connection, kind)
    let assert Ok(Nil) = beryl.stop(sockets)
    process.selector_receive(connection.selector, 500)
    |> should.equal(Ok(server.Close))
    server.close_connection(connection.state)
    complete(connection, bytes)
    server.close_connection(connection.state)
  })
}
