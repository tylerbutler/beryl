//// Binary frame parity for app-side dispatch: codecs without a binary
//// decoder fan raw frames out as one `Binary` event per joined topic in
//// sorted topic order; codecs with a binary decoder route the decoded
//// message through normal dispatch.

import app_test_helpers as h
import beryl
import beryl/socket.{AcceptJoin, Binary, Join, Next}
import beryl/transport
import beryl/wire
import beryl/wire/codec
import gleam/erlang/process
import gleam/option.{None}
import gleeunit

pub fn main() {
  gleeunit.main()
}

/// The Phoenix framing minus its binary decoder, so raw binary frames use
/// the per-topic fan-out path.
fn text_only_codec() -> codec.Codec {
  codec.new(
    decode_text: wire.decode_message,
    encode_reply: wire.reply_json,
    encode_push: wire.push,
    encode_heartbeat_reply: wire.heartbeat_reply,
  )
  |> codec.with_close_encoder(wire.channel_close)
  |> codec.with_error_encoder(wire.channel_error)
}

fn start_system(events: process.Subject(socket.Input(Nil))) -> beryl.Sockets {
  let assert Ok(channels) =
    beryl.start(
      beryl.config(text_only_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, ev) {
        process.send(events, ev)
        case ev {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          _ -> Next(model, [])
        }
      },
    )
  channels
}

pub fn raw_binary_fans_out_to_joined_topics_in_sorted_order_test() {
  let events = process.new_subject()
  let channels = start_system(events)
  let frames = h.connect(channels, "s1")
  // Join out of sorted order to prove delivery order is sorted.
  h.join(channels, "s1", "room:b", "jr-1", "r-1")
  let _reply_b = h.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  h.join(channels, "s1", "room:a", "jr-2", "r-2")
  let _reply_a = h.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  transport.route_binary(channels, "s1", <<1, 2, 3>>)

  let assert Ok(Binary("room:a", <<1, 2, 3>>)) = process.receive(events, 500)
  let assert Ok(Binary("room:b", <<1, 2, 3>>)) = process.receive(events, 500)
}

pub fn binary_to_unjoined_socket_is_dropped_test() {
  let events = process.new_subject()
  let channels = start_system(events)
  let _frames = h.connect(channels, "s1")

  transport.route_binary(channels, "s1", <<1, 2, 3>>)

  let assert Error(Nil) = process.receive(events, 100)
}
