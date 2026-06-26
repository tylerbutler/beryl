import beryl
import beryl/channel as bchannel
import beryl/transport/mist as mist_transport
import beryl/wire
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/json
import gleam/option
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleeunit
import gleeunit/should
import mist

const socket_path = "/socket/websocket"

pub type TestEvent {
  Terminated(topic: String, reason: bchannel.StopReason)
}

type TestServer {
  TestServer(
    channels: beryl.Channels,
    port: Int,
    supervisor: actor.Started(Supervisor),
  )
}

@external(erlang, "beryl_test_port_ffi", "available_port")
fn available_port() -> Result(Int, Nil)

@external(erlang, "beryl_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil

pub fn main() {
  gleeunit.main()
}

pub fn start_test_server_uses_dynamic_port_test() {
  let events = process.new_subject()
  case start_test_server(fn(channels, _events) {
    register_lobby(channels)
  }, events) {
    Ok(server) -> {
      should.be_true(server.port > 0)
      stop_test_server(server)
    }
    Error(_) -> panic as "failed to start test server"
  }
}

fn start_test_server(
  register: fn(beryl.Channels, process.Subject(TestEvent)) -> Nil,
  events: process.Subject(TestEvent),
) -> Result(TestServer, Nil) {
  let assert Ok(port) = available_port()
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  register(channels, events)

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
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.start
  {
    Ok(supervisor) -> Ok(TestServer(channels, port, supervisor))
    Error(_) -> Error(Nil)
  }
}

fn stop_test_server(server: TestServer) -> Nil {
  stop_supervisor(server.supervisor.pid)
}

fn register_lobby(channels: beryl.Channels) -> Nil {
  let lobby =
    bchannel.new(fn(_topic, _payload, socket) {
      bchannel.JoinOk(
        reply: option.Some(json.object([#("welcome", json.bool(True))])),
        socket: socket,
      )
    })
  let assert Ok(_) = beryl.register(channels, "test:lobby", lobby)
  Nil
}
