//// A custom binary codec driven through the app runtime: decoded binary
//// frames become `Join`/`Message` events, replies and broadcasts are
//// encoded back through the codec's binary frames, and codecs without a
//// binary decoder fan raw frames out as `Binary` events.

import app_test_helper
import beryl
import beryl/socket.{
  AcceptJoin, Binary, Closed, Info, Join, Message, Next, ReplyOk,
}
import beryl/transport
import beryl/wire
import beryl/wire/codec
import binary_test_codec
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should

/// Connect a socket capturing both text and binary outbound frames.
fn connect_binary(
  channels: beryl.Sockets,
  socket_id: String,
) -> #(process.Subject(String), process.Subject(BitArray)) {
  let sent_text = process.new_subject()
  let sent_binary = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(channels)
  transport.admit_socket(
    sockets: channels,
    owner: owner,
    socket_id: socket_id,
    send: fn(text) {
      process.send(sent_text, text)
      Ok(Nil)
    },
    send_binary: fn(data) {
      process.send(sent_binary, data)
      Ok(Nil)
    },
    codec: None,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
  |> should.equal(Ok(Nil))
  #(sent_text, sent_binary)
}

pub fn binary_codec_routes_join_message_and_reply_over_binary_test() -> Nil {
  let seen_payload = process.new_subject()
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(binary_test_codec.new()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, event) {
        case event {
          Join(_topic, payload, ref) -> {
            let user_decoder = {
              use user <- decode.field("user", decode.string)
              decode.success(user)
            }
            let assert Ok(user) = decode.run(payload, user_decoder)
            process.send(seen_payload, user)
            Next(model, [
              AcceptJoin(ref, Some(json.object([#("joined", json.bool(True))]))),
            ])
          }
          Message(_topic, event_name, payload, Some(ref)) -> {
            let body_decoder = {
              use body <- decode.field("body", decode.string)
              decode.success(body)
            }
            let assert Ok(body) = decode.run(payload, body_decoder)
            process.send(seen_payload, event_name <> ":" <> body)
            Next(model, [ReplyOk(ref, json.object([#("ok", json.bool(True))]))])
          }
          Message(_, _, _, None) | Binary(_, _) | Closed(_, _) | Info(_) ->
            Next(model, [])
        }
      },
    )

  let #(sent_text, sent_binary) = connect_binary(channels, "socket-1")

  transport.route_binary(
    channels,
    "socket-1",
    bit_array.from_string("J|join-ref|join-1|room:lobby|{\"user\":\"alice\"}"),
  )

  process.receive(seen_payload, 500) |> should.equal(Ok("alice"))
  let assert Ok(join_reply_bits) = process.receive(sent_binary, 500)
  bit_array.to_string(join_reply_bits)
  |> should.equal(Ok("R|join-1|room:lobby|ok|{\"joined\":true}"))

  transport.route_binary(
    channels,
    "socket-1",
    bit_array.from_string("E|event-1|room:lobby|ping|{\"body\":\"hi\"}"),
  )

  process.receive(seen_payload, 500) |> should.equal(Ok("ping:hi"))
  let assert Ok(event_reply_bits) = process.receive(sent_binary, 500)
  bit_array.to_string(event_reply_bits)
  |> should.equal(Ok("R|event-1|room:lobby|ok|{\"ok\":true}"))

  process.receive(sent_text, 50) |> should.be_error

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn binary_codec_event_consumes_one_message_rate_token_test() -> Nil {
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(binary_test_codec.new())
        |> beryl.with_message_rate(per_second: 100, burst: 2),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, event) {
        case event {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          Message(_topic, event_name, _payload, Some(ref)) -> {
            let _ = event_name
            Next(model, [ReplyOk(ref, json.object([#("ok", json.bool(True))]))])
          }
          Message(_, _, _, None) | Binary(_, _) | Closed(_, _) | Info(_) ->
            Next(model, [])
        }
      },
    )

  let #(_sent_text, sent_binary) = connect_binary(channels, "socket-1")

  transport.route_binary(
    channels,
    "socket-1",
    bit_array.from_string("J|join-ref|join-1|room:lobby|{}"),
  )
  let assert Ok(_join_reply_bits) = process.receive(sent_binary, 500)

  transport.route_binary(
    channels,
    "socket-1",
    bit_array.from_string("E|event-1|room:lobby|ping|{}"),
  )
  let assert Ok(first_reply_bits) = process.receive(sent_binary, 500)
  bit_array.to_string(first_reply_bits)
  |> should.equal(Ok("R|event-1|room:lobby|ok|{\"ok\":true}"))

  transport.route_binary(
    channels,
    "socket-1",
    bit_array.from_string("E|event-2|room:lobby|ping|{}"),
  )
  let assert Ok(second_reply_bits) = process.receive(sent_binary, 500)
  bit_array.to_string(second_reply_bits)
  |> should.equal(Ok("R|event-2|room:lobby|ok|{\"ok\":true}"))

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn binary_codec_broadcast_uses_binary_send_test() -> Nil {
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(binary_test_codec.new()),
      init: fn(_info: socket.ConnectInfo(Nil)) { #(Nil, []) },
      update: fn(model, event) {
        case event {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          Message(_, _, _, _) | Binary(_, _) | Closed(_, _) | Info(_) ->
            Next(model, [])
        }
      },
    )

  let #(sent_text, sent_binary) = connect_binary(channels, "socket-1")

  transport.route_binary(
    channels,
    "socket-1",
    bit_array.from_string("J|join-ref|join-1|room:lobby|{}"),
  )
  let assert Ok(_join_reply) = process.receive(sent_binary, 500)

  beryl.broadcast(
    channels,
    "room:lobby",
    "announcement",
    json.object([#("body", json.string("hello"))]),
  )

  let assert Ok(broadcast_bits) = process.receive(sent_binary, 500)
  bit_array.to_string(broadcast_bits)
  |> should.equal(Ok("P|room:lobby|announcement|{\"body\":\"hello\"}"))
  process.receive(sent_text, 50) |> should.be_error

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn codec_without_binary_decoder_delivers_raw_binary_events_test() -> Nil {
  let seen_binary = process.new_subject()
  // A text-only codec (no binary decoder): raw binary frames fan out to the
  // app as `Binary` events. The Phoenix codec now ships its own binary
  // decoder, so this path applies only to custom codecs that opt out.
  let text_only =
    codec.new(
      decode_text: wire.decode_message,
      encode_reply: wire.reply_json,
      encode_push: wire.push,
      encode_heartbeat_reply: wire.heartbeat_reply,
    )
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(text_only),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, event) {
        case event {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          Binary(_topic, data) -> {
            process.send(seen_binary, data)
            Next(model, [])
          }
          Message(_, _, _, _) | Closed(_, _) | Info(_) -> Next(model, [])
        }
      },
    )

  let #(sent_text, _sent_binary) = connect_binary(channels, "socket-1")

  let assert Ok(message) =
    codec.decode_text(transport.active_codec(channels))(
      "[null,\"join-ref\",\"room:lobby\",\"phx_join\",{}]",
    )
  transport.route_decoded(channels, "socket-1", message)
  let assert Ok(_join_reply) = process.receive(sent_text, 500)

  transport.route_binary(channels, "socket-1", bit_array.from_string("raw"))

  let assert Ok(raw_bits) = process.receive(seen_binary, 500)
  bit_array.to_string(raw_bits) |> should.equal(Ok("raw"))

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}
