import aquamarine
import aquamarine/error as aquamarine_error
import aquamarine/phoenix
import beryl
import beryl/channel as bchannel
import beryl/transport/mist as mist_transport
import beryl/wire
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
}

@external(erlang, "beryl_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil

pub fn main() {
  gleeunit.main()
}

pub fn start_test_server_uses_dynamic_port_test() {
  let events = process.new_subject()
  let assert Ok(server) = start_test_server(register_lobby, events)
  should.be_true(server.port > 0)
  stop_test_server(server)
}

pub fn aquamarine_client_joins_real_beryl_server_test() {
  let events = process.new_subject()
  let assert Ok(server) = start_test_server(register_lobby, events)

  let assert Ok(channel) =
    aquamarine.connect(
      host: "127.0.0.1",
      port: server.port,
      path: socket_path,
      topic: "test:lobby",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  let assert Ok(Joined("test:lobby")) = process.receive(events, 1000)

  let assert Ok(Nil) = aquamarine.close(channel)
  stop_test_server(server)
}

fn start_test_server(
  register: fn(beryl.Channels, process.Subject(TestEvent)) -> Nil,
  events: process.Subject(TestEvent),
) -> Result(TestServer, Nil) {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  register(channels, events)
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

fn stop_test_server(server: TestServer) -> Nil {
  stop_supervisor(server.supervisor.pid)
}

fn register_lobby(
  channels: beryl.Channels,
  events: process.Subject(TestEvent),
) -> Nil {
  let lobby =
    bchannel.new(fn(topic, _payload, socket) {
      process.send(events, Joined(topic))
      bchannel.JoinOk(
        reply: option.Some(json.object([#("welcome", json.bool(True))])),
        socket: socket,
      )
    })
  let assert Ok(_) = beryl.register(channels, "test:lobby", lobby)
  Nil
}

pub fn aquamarine_client_sees_join_rejection_test() {
  let events = process.new_subject()
  let assert Ok(server) = start_test_server(register_rejected, events)

  let result =
    aquamarine.connect(
      host: "127.0.0.1",
      port: server.port,
      path: socket_path,
      topic: "test:rejected",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  result |> should.equal(Error(aquamarine_error.JoinRejected("error")))
  stop_test_server(server)
}

pub fn aquamarine_push_gets_server_reply_test() {
  let events = process.new_subject()
  let assert Ok(server) = start_test_server(register_echo, events)

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
  let assert Ok(server) = start_test_server(register_lobby, events)

  let assert Ok(channel) =
    aquamarine.connect(
      host: "127.0.0.1",
      port: server.port,
      path: socket_path,
      topic: "test:lobby",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  let assert Ok(Joined("test:lobby")) = process.receive(events, 1000)
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

fn register_rejected(
  channels: beryl.Channels,
  _events: process.Subject(TestEvent),
) -> Nil {
  let rejected =
    bchannel.new(fn(_topic, _payload, _socket) {
      bchannel.JoinError(reason: bchannel.error("nope"))
    })
  let assert Ok(_) = beryl.register(channels, "test:rejected", rejected)
  Nil
}

fn register_echo(
  channels: beryl.Channels,
  _events: process.Subject(TestEvent),
) -> Nil {
  let echo_channel =
    bchannel.new(fn(_topic, _payload, socket) {
      bchannel.JoinOk(reply: option.Some(json.object([])), socket: socket)
    })
    |> bchannel.with_handle_in(fn(_event, payload, socket) {
      let body =
        bchannel.decode_payload(payload, {
          use body <- decode.field("body", decode.string)
          decode.success(body)
        })
        |> result.unwrap("")

      bchannel.Reply(
        event: "reply",
        payload: json.object([#("body", json.string(body))]),
        socket: socket,
      )
    })

  let assert Ok(_) = beryl.register(channels, "test:echo", echo_channel)
  Nil
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
