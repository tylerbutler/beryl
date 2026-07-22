import aquamarine
import aquamarine/error as aquamarine_error
import aquamarine/phoenix
import beryl
import beryl/event.{AcceptJoin, Closed, Join, Message, Next, RejectJoin, ReplyOk}
import beryl/wire
import beryl_mist as mist_transport
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/response
import gleam/json
import gleam/option
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/result
import gleeunit
import gleeunit/should
import gluegun/websocket
import mist

const socket_path = "/socket/websocket"

type TestServer {
  TestServer(
    channels: beryl.Channels,
    port: Int,
    supervisor: actor.Started(Supervisor),
  )
}

type TestEvent {
  Joined(String)
  Terminated(String, event.StopReason)
}

@external(erlang, "beryl_mist_transport_test_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil

pub fn main() {
  gleeunit.main()
}

pub fn start_test_server_uses_dynamic_port_test() {
  let events = process.new_subject()
  let assert Ok(server) = start_test_server(events)
  should.be_true(server.port > 0)
  stop_test_server(server)
}

pub fn aquamarine_client_joins_real_beryl_server_test() {
  let events = process.new_subject()
  let assert Ok(server) = start_test_server(events)

  let assert Ok(channel) =
    aquamarine.connect(
      host: "127.0.0.1",
      port: server.port,
      path: socket_path,
      topic: "test:lobby",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  let assert Ok(Nil) = receive_joined(events, "test:lobby")

  let assert Ok(Nil) = aquamarine.close(channel)
  stop_test_server(server)
}

/// Start a mist-served app-dispatch system handling the contract topics:
/// `test:lobby` (accepted, welcome reply, join/close observed),
/// `test:rejected` (rejected), and `test:echo` (echoes "body" in a reply).
fn start_test_server(
  events: process.Subject(TestEvent),
) -> Result(TestServer, Nil) {
  let assert Ok(channels) =
    beryl.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, ev) { update(events, model, ev) },
    )
  let port_subject = process.new_subject()

  let handler = fn(req) {
    mist_transport.upgrade(
      req,
      channels,
      mist_transport.default_config(socket_path),
      fn() {
        response.new(404)
        |> response.set_body(mist.Bytes(bytes_tree.new()))
      },
    )
  }

  case
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _scheme, _ip_address) {
      process.send(port_subject, port)
    })
    |> mist.start
  {
    Ok(supervisor) -> {
      let assert Ok(port) = process.receive(port_subject, 1000)
      Ok(TestServer(channels, port, supervisor))
    }
    Error(_) -> Error(Nil)
  }
}

fn update(
  events: process.Subject(TestEvent),
  model: Nil,
  ev: event.Event(Nil),
) -> event.Next(Nil, Nil) {
  case ev {
    Join("test:lobby", _payload, ref) -> {
      process.send(events, Joined("test:lobby"))
      Next(model, [
        AcceptJoin(
          ref,
          option.Some(json.object([#("welcome", json.bool(True))])),
        ),
      ])
    }
    Join("test:rejected", _payload, ref) ->
      Next(model, [
        RejectJoin(ref, json.object([#("reason", json.string("nope"))])),
      ])
    Join("test:echo", _payload, ref) ->
      Next(model, [AcceptJoin(ref, option.Some(json.object([])))])
    Join(_, _, _) -> Next(model, [])

    Message("test:echo", _event, payload, option.Some(ref)) -> {
      let body =
        decode.run(payload, {
          use body <- decode.field("body", decode.string)
          decode.success(body)
        })
        |> result.unwrap("")
      Next(model, [ReplyOk(ref, json.object([#("body", json.string(body))]))])
    }

    Closed(topic, reason) -> {
      process.send(events, Terminated(topic, reason))
      Next(model, [])
    }

    _ -> Next(model, [])
  }
}

fn stop_test_server(server: TestServer) -> Nil {
  stop_supervisor(server.supervisor.pid)
}

pub fn aquamarine_client_sees_join_rejection_test() {
  let events = process.new_subject()
  let assert Ok(server) = start_test_server(events)

  let result =
    aquamarine.connect(
      host: "127.0.0.1",
      port: server.port,
      path: socket_path,
      topic: "test:rejected",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  // The app's reject payload carries `reason`, which the Phoenix client
  // surfaces directly (previously only the bare "error" status was visible).
  result |> should.equal(Error(aquamarine_error.JoinRejected("nope")))
  stop_test_server(server)
}

pub fn aquamarine_push_gets_server_reply_test() {
  let events = process.new_subject()
  let assert Ok(server) = start_test_server(events)

  let assert Ok(channel) =
    aquamarine.connect(
      host: "127.0.0.1",
      port: server.port,
      path: socket_path,
      topic: "test:echo",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  let assert Ok(Nil) =
    aquamarine.push(
      channel,
      "say",
      json.object([#("body", json.string("hello"))]),
    )

  let assert Ok(incoming) = aquamarine.receive(channel)
  incoming.event |> should.equal(phoenix.codec().reply_event)
  incoming.topic |> should.equal("test:echo")
  decode_body(incoming.payload) |> should.equal(Ok("hello"))

  let assert Ok(Nil) = aquamarine.close(channel)
  stop_test_server(server)
}

pub fn aquamarine_client_receives_server_broadcast_test() {
  let events = process.new_subject()
  let assert Ok(server) = start_test_server(events)

  let assert Ok(channel) =
    aquamarine.connect(
      host: "127.0.0.1",
      port: server.port,
      path: socket_path,
      topic: "test:lobby",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  let assert Ok(Nil) = receive_joined(events, "test:lobby")
  process.sleep(25)

  beryl.broadcast(
    server.channels,
    "test:lobby",
    "tick",
    json.object([#("n", json.int(42))]),
  )

  let assert Ok(incoming) = aquamarine.receive(channel)
  incoming.event |> should.equal("tick")
  incoming.topic |> should.equal("test:lobby")
  decode_n(incoming.payload) |> should.equal(Ok(42))

  let assert Ok(Nil) = aquamarine.close(channel)
  stop_test_server(server)
}

pub fn aquamarine_close_delivers_closed_event_test() {
  let events = process.new_subject()
  let assert Ok(server) = start_test_server(events)

  let assert Ok(channel) =
    aquamarine.connect(
      host: "127.0.0.1",
      port: server.port,
      path: socket_path,
      topic: "test:lobby",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  let assert Ok(Nil) = receive_joined(events, "test:lobby")
  let assert Ok(Nil) = aquamarine.close(channel)
  let assert Ok(reason) = receive_terminated(events, "test:lobby")
  reason |> should.equal(event.Normal)

  stop_test_server(server)
}

pub fn gluegun_raw_malformed_frame_gets_error_reply_test() {
  let events = process.new_subject()
  let assert Ok(server) = start_test_server(events)

  let result =
    websocket.with_socket(
      host: "127.0.0.1",
      port: server.port,
      path: socket_path,
      options: websocket.options(),
      callback: fn(socket) {
        let assert Ok(Nil) = websocket.send_text(socket, "not json")
        websocket.receive_app_frame(socket)
      },
    )

  // Current Beryl contract: malformed text frames time out rather than reply.
  result |> should.be_error

  stop_test_server(server)
}

fn decode_body(payload) -> Result(String, Nil) {
  let decoder = {
    use body <- decode.subfield(["response", "body"], decode.string)
    decode.success(body)
  }

  decode.run(payload, decoder)
  |> result.map_error(fn(_) { Nil })
}

fn decode_n(payload) -> Result(Int, Nil) {
  let decoder = {
    use n <- decode.field("n", decode.int)
    decode.success(n)
  }

  decode.run(payload, decoder)
  |> result.map_error(fn(_) { Nil })
}

fn receive_joined(
  events: process.Subject(TestEvent),
  topic: String,
) -> Result(Nil, Nil) {
  case process.receive(events, 500) {
    Ok(Joined(joined_topic)) if joined_topic == topic -> Ok(Nil)
    _ -> Error(Nil)
  }
}

fn receive_terminated(
  events: process.Subject(TestEvent),
  topic: String,
) -> Result(event.StopReason, Nil) {
  case process.receive(events, 500) {
    Ok(Terminated(stopped_topic, reason)) if stopped_topic == topic ->
      Ok(reason)
    _ -> Error(Nil)
  }
}
