import beryl
import beryl/channel
import beryl/coordinator
import beryl/internal/unsupervised
import beryl/transport
import beryl/wire
import beryl/wire/codec
import gleam/dynamic
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

fn echo_channel() -> channel.Channel(Nil, info) {
  channel.new(fn(_topic, _payload, socket) {
    channel.JoinOk(reply: option.None, socket: socket)
  })
  |> channel.with_handle_in(fn(_event, _payload, socket) {
    channel.Push("echoed", json.object([]), socket)
  })
}

fn start_channels() -> beryl.Channels {
  let assert Ok(channels) =
    unsupervised.start(beryl.config(wire.phoenix_codec()))
  let assert Ok(_) = beryl.register(channels, "room:*", echo_channel())
  channels
}

fn connect(
  channels: beryl.Channels,
  socket_id: String,
  socket_codec: option.Option(codec.Codec),
) -> process.Subject(String) {
  let sent = process.new_subject()
  transport.socket_connected_with_codec(
    channels: channels,
    socket_id: socket_id,
    send: fn(text) {
      process.send(sent, text)
      Ok(Nil)
    },
    send_binary: fn(_data) { Ok(Nil) },
    codec: socket_codec,
    assigns: dynamic.nil(),
  )
  sent
}

fn route(channels: beryl.Channels, socket_id: String, frame: String) -> Nil {
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    socket_id,
    frame,
  )
}

// A socket announced with an explicit codec is framed with that codec,
// not the coordinator's configured one.
pub fn socket_codec_overrides_configured_codec_test() {
  let channels = start_channels()
  let sent = connect(channels, "tagged", option.Some(tagged_codec()))

  route(channels, "tagged", "[null,\"jr\",\"room:lobby\",\"phx_join\",{}]")
  let assert Ok(join_reply) = process.receive(sent, 500)
  join_reply |> string.starts_with("TAGGED-REPLY|") |> should.be_true

  route(channels, "tagged", "[null,null,\"room:lobby\",\"ping\",{}]")
  let assert Ok(push) = process.receive(sent, 500)
  push |> string.starts_with("TAGGED-PUSH|room:lobby|echoed") |> should.be_true
}

// A socket announced without a codec inherits the configured one.
pub fn socket_without_codec_inherits_configured_codec_test() {
  let channels = start_channels()
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
pub fn sockets_with_different_codecs_share_a_topic_test() {
  let channels = start_channels()
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
