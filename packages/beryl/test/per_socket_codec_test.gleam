import app_test_helper
import beryl
import beryl/socket
import beryl/transport
import beryl/wire
import beryl/wire/codec
import gleam/erlang/process
import gleam/json
import gleam/option
import gleam/string
import gleeunit/should

// A framing that is unmistakably not Phoenix, so the codec that encoded a
// frame is readable from the frame text alone.
fn tagged_codec() -> codec.Codec {
  codec.new(
    decode_text: wire.decode_message,
    encode_reply: fn(_join_ref, _ref, topic, _status, payload) {
      codec.TextFrame(
        "TAGGED-REPLY|" <> topic <> "|" <> json.to_string(payload),
      )
    },
    encode_push: fn(topic, event, payload) {
      codec.TextFrame(
        "TAGGED-PUSH|"
        <> topic
        <> "|"
        <> event
        <> "|"
        <> json.to_string(payload),
      )
    },
    encode_heartbeat_reply: fn(_ref) { codec.TextFrame("TAGGED-HB") },
  )
}

fn start_sockets() -> beryl.Sockets {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, input) {
        case input {
          socket.Join(_, _, ref) ->
            socket.Next(model, [socket.AcceptJoin(ref, option.None)])
          socket.Message(topic, _, _, _) ->
            socket.Next(model, [socket.Push(topic, "echoed", json.object([]))])
          _ -> socket.Next(model, [])
        }
      },
    )
  sockets
}

fn connect(
  channels: beryl.Sockets,
  socket_id: String,
  socket_codec: option.Option(codec.Codec),
) -> process.Subject(String) {
  let sent = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(channels)
  transport.admit_socket(
    sockets: channels,
    owner: owner,
    socket_id: socket_id,
    send: fn(text) {
      process.send(sent, text)
      Ok(Nil)
    },
    send_binary: fn(_data) { Ok(Nil) },
    codec: socket_codec,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
  |> should.equal(Ok(Nil))
  sent
}

fn route(channels: beryl.Sockets, socket_id: String, frame: String) -> Nil {
  let assert Ok(input) =
    codec.decode_text(transport.active_codec(channels))(frame)
  transport.route_decoded(channels, socket_id, input)
}

// A socket announced with an explicit codec is framed with that codec,
// not the coordinator's configured one.
pub fn socket_codec_overrides_configured_codec_test() -> Nil {
  let channels = start_sockets()
  let sent = connect(channels, "tagged", option.Some(tagged_codec()))

  route(channels, "tagged", "[null,\"jr\",\"room:lobby\",\"phx_join\",{}]")
  let assert Ok(join_reply) = process.receive(sent, 500)
  join_reply |> string.starts_with("TAGGED-REPLY|") |> should.be_true

  route(channels, "tagged", "[null,null,\"room:lobby\",\"ping\",{}]")
  let assert Ok(push) = process.receive(sent, 500)
  push |> string.starts_with("TAGGED-PUSH|room:lobby|echoed") |> should.be_true
}

// Runtime-cleanup replays must keep protocol replies on the socket's
// negotiated codec rather than falling back to the app-wide codec.
pub fn socket_codec_encodes_heartbeat_reply_test() -> Nil {
  let channels = start_sockets()
  let sent = connect(channels, "tagged-heartbeat", option.Some(tagged_codec()))

  route(
    channels,
    "tagged-heartbeat",
    "[null,\"heartbeat-ref\",\"phoenix\",\"heartbeat\",{}]",
  )

  let assert Ok(reply) = process.receive(sent, 500)
  reply |> should.equal("TAGGED-HB")
}

// A socket announced without a codec inherits the configured one.
pub fn socket_without_codec_inherits_configured_codec_test() -> Nil {
  let channels = start_sockets()
  let sent = connect(channels, "plain", option.None)

  route(channels, "plain", "[null,\"jr\",\"room:lobby\",\"phx_join\",{}]")
  let assert Ok(join_reply) = process.receive(sent, 500)
  join_reply |> string.contains("phx_reply") |> should.be_true

  route(channels, "plain", "[null,null,\"room:lobby\",\"ping\",{}]")
  let assert Ok(push) = process.receive(sent, 500)
  push |> string.contains("\"echoed\"") |> should.be_true
  push |> string.starts_with("TAGGED-") |> should.be_false
}

// The dual-mode case: sockets speaking different framings share one
// coordinator, one channel and one topic, and each receives the same
// broadcast in its own wire format.
pub fn sockets_with_different_codecs_share_a_topic_test() -> Nil {
  let channels = start_sockets()
  let phoenix_sent = connect(channels, "phoenix-socket", option.None)
  let tagged_sent =
    connect(channels, "tagged-socket", option.Some(tagged_codec()))

  route(
    channels,
    "phoenix-socket",
    "[null,\"jr\",\"room:lobby\",\"phx_join\",{}]",
  )
  let assert Ok(_) = process.receive(phoenix_sent, 500)
  route(
    channels,
    "tagged-socket",
    "[null,\"jr\",\"room:lobby\",\"phx_join\",{}]",
  )
  let assert Ok(_) = process.receive(tagged_sent, 500)

  beryl.broadcast(channels, "room:lobby", "op", json.object([]))

  let assert Ok(phoenix_frame) = process.receive(phoenix_sent, 500)
  phoenix_frame
  |> string.starts_with("[null,null,\"room:lobby\",\"op\"")
  |> should.be_true

  let assert Ok(tagged_frame) = process.receive(tagged_sent, 500)
  tagged_frame |> should.equal("TAGGED-PUSH|room:lobby|op|{}")
}
