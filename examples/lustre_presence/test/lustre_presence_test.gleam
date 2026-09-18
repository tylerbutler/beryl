import beryl
import beryl/channel
import beryl/socket
import beryl/transport
import beryl/wire
import beryl/wire/codec
import gleam/bit_array
import gleam/erlang/process
import gleam/http/request
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/string
import gleeunit
import gleeunit/should
import lustre_presence/auth
import lustre_presence/dashboard

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn signed_session_authenticates_request_test() {
  let secret = bit_array.from_string("test-secret")
  let assert Ok(user) = auth.find_user("ada")
  let cookie = auth.session_cookie(user, secret)
  let http_request =
    request.new()
    |> request.set_header("cookie", cookie)

  auth.authenticate_request(http_request, secret)
  |> should.equal(Ok(user))
}

pub fn tampered_session_is_rejected_test() {
  let secret = bit_array.from_string("test-secret")
  let http_request =
    request.new()
    |> request.set_header("cookie", "beryl_session=not-a-valid-token")

  auth.authenticate_request(http_request, secret)
  |> should.equal(Error(Nil))
}

pub fn dashboard_join_requires_authenticated_metadata_test() {
  let assert Ok(#(channels, specification)) =
    channel.child_spec(beryl.config(wire.phoenix_codec()), handlers: [
      dashboard.channel(),
    ])
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(specification)
    |> static_supervisor.start()

  let unauthenticated = connect(channels, "anonymous", [])
  join(channels, "anonymous")
  receive_frame(unauthenticated)
  |> string.contains("unauthorized")
  |> should.be_true

  let assert Ok(user) = auth.find_user("ada")
  let authenticated = connect(channels, "ada", auth.metadata(user))
  join(channels, "ada")
  let reply = receive_frame(authenticated)
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
  reply |> string.contains("\"user_id\":\"ada\"") |> should.be_true

  beryl.stop(channels) |> should.equal(Ok(Nil))
}

fn connect(
  channels: beryl.Sockets,
  socket_id: String,
  metadata: List(#(String, String)),
) -> process.Subject(String) {
  let frames = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(channels)
  transport.admit_socket(
    sockets: channels,
    owner: owner,
    socket_id: socket_id,
    send: fn(frame) {
      process.send(frames, frame)
      Ok(Nil)
    },
    send_binary: fn(_) { Ok(Nil) },
    codec: None,
    seed: socket.ConnectSeed(path: "", query: [], headers: [], metadata:),
    close: fn() { Nil },
  )
  |> should.equal(Ok(Nil))
  frames
}

fn join(channels: beryl.Sockets, socket_id: String) -> Nil {
  let assert Ok(decoded) =
    codec.decode_text(transport.active_codec(channels))(
      "[\"jr-1\",\"r-1\",\"page:dashboard\",\"phx_join\",{}]",
    )
  transport.route_decoded(channels, socket_id, decoded)
  |> should.equal(Ok(Nil))
}

fn receive_frame(frames: process.Subject(String)) -> String {
  let assert Ok(frame) = process.receive(frames, 500)
  frame
}
