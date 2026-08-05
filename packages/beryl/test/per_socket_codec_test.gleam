import beryl
import beryl/socket.{AcceptJoin, Broadcast, Join, Message, Next}
import beryl/transport
import beryl/wire
import beryl/wire/codec
import gleam/erlang/process
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

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
    beryl.start(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, input) {
        case input {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          Message(topic, "cast", _, _) ->
            Next(model, [Broadcast(topic, "op", json.object([]))])
          Message(topic, _, _, _) ->
            Next(model, [socket.Push(topic, "echoed", json.object([]))])
          _ -> Next(model, [])
        }
      },
    )
  sockets
}

fn connect(
  sockets: beryl.Sockets,
  socket_id: String,
  socket_codec: Option(codec.Codec),
) -> process.Subject(String) {
  let sent = process.new_subject()
  transport.socket_connected_with_codec(
    sockets: sockets,
    socket_id: socket_id,
    send: fn(text) {
      process.send(sent, text)
      Ok(Nil)
    },
    send_binary: fn(_data) { Ok(Nil) },
    codec: socket_codec,
    seed: socket.empty_seed(),
  )
  process.sleep(10)
  sent
}

fn route(
  sockets: beryl.Sockets,
  socket_id: String,
  inbound_codec: codec.Codec,
  frame: String,
) -> Nil {
  let assert Ok(message) = codec.decode_text(inbound_codec)(frame)
  transport.route_decoded(sockets, socket_id, message)
}

pub fn socket_codec_overrides_configured_codec_test() {
  let sockets = start_sockets()
  let tagged = tagged_codec()
  let sent = connect(sockets, "tagged", Some(tagged))

  route(
    sockets,
    "tagged",
    tagged,
    "[null,\"jr\",\"room:lobby\",\"phx_join\",{}]",
  )
  let assert Ok(join_reply) = process.receive(sent, 500)
  join_reply |> string.starts_with("TAGGED-REPLY|") |> should.be_true

  route(sockets, "tagged", tagged, "[null,null,\"room:lobby\",\"ping\",{}]")
  let assert Ok(push) = process.receive(sent, 500)
  push |> string.starts_with("TAGGED-PUSH|room:lobby|echoed") |> should.be_true
}

pub fn socket_without_codec_inherits_configured_codec_test() {
  let sockets = start_sockets()
  let phoenix = wire.phoenix_codec()
  let sent = connect(sockets, "plain", None)

  route(
    sockets,
    "plain",
    phoenix,
    "[null,\"jr\",\"room:lobby\",\"phx_join\",{}]",
  )
  let assert Ok(join_reply) = process.receive(sent, 500)
  join_reply |> string.contains("phx_reply") |> should.be_true

  route(sockets, "plain", phoenix, "[null,null,\"room:lobby\",\"ping\",{}]")
  let assert Ok(push) = process.receive(sent, 500)
  push |> string.contains("\"echoed\"") |> should.be_true
  push |> string.starts_with("TAGGED-") |> should.be_false
}

pub fn sockets_with_different_codecs_share_a_topic_test() {
  let sockets = start_sockets()
  let phoenix = wire.phoenix_codec()
  let tagged = tagged_codec()
  let phoenix_sent = connect(sockets, "phoenix-socket", None)
  let tagged_sent = connect(sockets, "tagged-socket", Some(tagged))

  route(
    sockets,
    "phoenix-socket",
    phoenix,
    "[null,\"jr\",\"room:lobby\",\"phx_join\",{}]",
  )
  let assert Ok(_) = process.receive(phoenix_sent, 500)
  route(
    sockets,
    "tagged-socket",
    tagged,
    "[null,\"jr\",\"room:lobby\",\"phx_join\",{}]",
  )
  let assert Ok(_) = process.receive(tagged_sent, 500)

  route(
    sockets,
    "phoenix-socket",
    phoenix,
    "[null,null,\"room:lobby\",\"cast\",{}]",
  )

  let assert Ok(phoenix_frame) = process.receive(phoenix_sent, 500)
  phoenix_frame
  |> string.starts_with("[null,null,\"room:lobby\",\"op\"")
  |> should.be_true

  let assert Ok(tagged_frame) = process.receive(tagged_sent, 500)
  tagged_frame |> should.equal("TAGGED-PUSH|room:lobby|op|{}")
}
