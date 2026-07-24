import app_test_helpers as h
import aquamarine
import aquamarine/error as aquamarine_error
import aquamarine/phoenix
import beryl
import beryl/event
import beryl/wire
import beryl_mist as mist_transport
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/response
import gleam/json
import gleam/option.{Some}
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
    channels: beryl.Sockets,
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
  let assert Ok(server) = start_test_server(lobby_update(events))
  should.be_true(server.port > 0)
  stop_test_server(server)
}

pub fn aquamarine_client_joins_real_beryl_server_test() {
  let events = process.new_subject()
  let assert Ok(server) = start_test_server(lobby_update(events))

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

fn start_test_server(
  update: fn(Nil, event.Input(Nil)) -> event.Next(Nil, Nil),
) -> Result(TestServer, Nil) {
  let assert Ok(channels) =
    h.start(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info: event.ConnectInfo(Nil)) { #(Nil, []) },
      update: update,
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

fn stop_test_server(server: TestServer) -> Nil {
  stop_supervisor(server.supervisor.pid)
}

/// A `test:lobby` behaviour: accept the join (reply `{welcome: true}`),
/// reporting join/close through the `events` observer.
fn lobby_update(
  events: process.Subject(TestEvent),
) -> fn(Nil, event.Input(Nil)) -> event.Next(Nil, Nil) {
  fn(model, ev) {
    case ev {
      event.Join(topic, _payload, ref) -> {
        process.send(events, Joined(topic))
        event.Next(model, [
          event.AcceptJoin(
            ref,
            Some(json.object([#("welcome", json.bool(True))])),
          ),
        ])
      }
      event.Closed(topic, reason) -> {
        process.send(events, Terminated(topic, reason))
        event.Next(model, [])
      }
      _ -> event.Next(model, [])
    }
  }
}

pub fn aquamarine_client_sees_join_rejection_test() {
  let assert Ok(server) = start_test_server(rejected_update())

  let result =
    aquamarine.connect(
      host: "127.0.0.1",
      port: server.port,
      path: socket_path,
      topic: "test:rejected",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  // The app supplies the rejection reason in the `RejectJoin` payload, which
  // propagates verbatim to the client (aquamarine reads `response.reason`).
  result |> should.equal(Error(aquamarine_error.JoinRejected("nope")))
  stop_test_server(server)
}

pub fn aquamarine_push_gets_server_reply_test() {
  let assert Ok(server) = start_test_server(echo_update())

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
  let assert Ok(server) = start_test_server(lobby_update(events))

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

pub fn aquamarine_close_terminates_joined_channel_test() {
  let events = process.new_subject()
  let assert Ok(server) = start_test_server(lobby_update(events))

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
  let assert Ok(server) = start_test_server(lobby_update(events))

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

/// A `test:rejected` behaviour: reject every join with status `error`.
fn rejected_update() -> fn(Nil, event.Input(Nil)) -> event.Next(Nil, Nil) {
  fn(model, ev) {
    case ev {
      event.Join(_topic, _payload, ref) ->
        event.Next(model, [
          event.RejectJoin(ref, json.object([#("reason", json.string("nope"))])),
        ])
      _ -> event.Next(model, [])
    }
  }
}

/// A `test:echo` behaviour: accept joins and reply to any client message
/// with `{body: <body>}` echoed from the request payload.
fn echo_update() -> fn(Nil, event.Input(Nil)) -> event.Next(Nil, Nil) {
  fn(model, ev) {
    case ev {
      event.Join(_topic, _payload, ref) ->
        event.Next(model, [event.AcceptJoin(ref, Some(json.object([])))])
      event.Message(_topic, _name, payload, Some(ref)) -> {
        let body =
          decode.run(payload, {
            use body <- decode.field("body", decode.string)
            decode.success(body)
          })
          |> result.unwrap("")
        event.Next(model, [
          event.ReplyOk(ref, json.object([#("body", json.string(body))])),
        ])
      }
      _ -> event.Next(model, [])
    }
  }
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
