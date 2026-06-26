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

type TestServer {
  TestServer(
    channels: beryl.Channels,
    port: Int,
    supervisor: actor.Started(Supervisor),
  )
}

@external(erlang, "beryl_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil

pub fn main() {
  gleeunit.main()
}

pub fn start_test_server_uses_dynamic_port_test() {
  case start_test_server(fn(channels) {
    register_lobby(channels)
  }) {
    Ok(server) -> {
      should.be_true(server.port > 0)
      stop_test_server(server)
    }
    Error(_) -> panic as "failed to start test server"
  }
}

fn start_test_server(
  register: fn(beryl.Channels) -> Nil,
) -> Result(TestServer, Nil) {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  register(channels)
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
