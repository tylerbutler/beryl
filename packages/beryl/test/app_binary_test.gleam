//// Binary frame parity for app-side dispatch: codecs without a binary
//// decoder fan raw frames out as one `Binary` event per joined topic in
//// sorted topic order; codecs with a binary decoder route the decoded
//// message through normal dispatch.

import app_test_helper
import beryl
import beryl/socket.{Binary, Join}
import beryl/transport
import beryl/wire
import beryl/wire/codec
import gleam/erlang/process
import gleeunit/should

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
  start_with(beryl.config(text_only_codec()), events)
}

fn start_with(
  config: beryl.Config,
  events: process.Subject(socket.Input(Nil)),
) -> beryl.Sockets {
  app_test_helper.start_observed(config, events)
}

pub fn raw_binary_fans_out_to_joined_topics_in_sorted_order_test() -> Nil {
  let events = process.new_subject()
  let channels = start_system(events)
  let frames = app_test_helper.connect(channels, "s1")
  // Join out of sorted order to prove delivery order is sorted.
  app_test_helper.join(channels, "s1", "room:b", "jr-1", "r-1")
  let _reply_b = app_test_helper.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  app_test_helper.join(channels, "s1", "room:a", "jr-2", "r-2")
  let _reply_a = app_test_helper.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  transport.route_binary(channels, "s1", <<1, 2, 3>>)

  let assert Ok(Binary("room:a", <<1, 2, 3>>)) = process.receive(events, 500)
  let assert Ok(Binary("room:b", <<1, 2, 3>>)) = process.receive(events, 500)
  Nil
}

pub fn binary_to_unjoined_socket_is_dropped_test() -> Nil {
  let events = process.new_subject()
  let channels = start_system(events)
  let _frames = app_test_helper.connect(channels, "s1")

  transport.route_binary(channels, "s1", <<1, 2, 3>>)

  let assert Error(Nil) = process.receive(events, 100)
  Nil
}

pub fn raw_binary_consumes_one_message_rate_token_test() -> Nil {
  // Regression: raw binary delivered as an application `Binary` input
  // (codec has no binary decoder) consumes the runtime's message-rate
  // bucket exactly like a decoded text event does.
  let events = process.new_subject()
  let channels =
    start_with(
      beryl.config(text_only_codec())
        |> beryl.with_message_rate(per_second: 1, burst: 1),
      events,
    )
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = app_test_helper.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  // The first raw binary frame spends the single token and fans out.
  transport.route_binary(channels, "s1", <<1, 2, 3>>)
  let assert Ok(Binary("room:a", <<1, 2, 3>>)) = process.receive(events, 500)

  // The second is shed by the runtime's message limiter.
  transport.route_binary(channels, "s1", <<4, 5, 6>>)
  process.receive(events, 100) |> should.be_error
}
