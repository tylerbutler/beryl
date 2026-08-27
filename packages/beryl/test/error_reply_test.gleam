//// Error replies on the app runtime: `ReplyError` must reach the client as
//// a `phx_reply` with `"status": "error"` correlated to the client's ref
//// (Phoenix `push.receive("error", ...)`), unjoined-topic pushes get an
//// `unmatched topic` error, and refless errors are dropped.

import app_test_helpers as h
import beryl
import beryl/socket.{AcceptJoin, Join, Message, Next, ReplyError}
import beryl/wire
import gleam/json
import gleam/option.{Some}
import gleam/string
import gleeunit/should

/// Accepts every join; replies with an error to "fail" when the client
/// sent a ref (refless "fail" messages are unanswerable by construction).
fn start_with_error_app() -> beryl.Sockets {
  let assert Ok(channels) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, ev) {
        case ev {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, option.None)])
          Message(_topic, "fail", _payload, Some(ref)) ->
            Next(model, [
              ReplyError(ref, json.object([#("reason", json.string("nope"))])),
            ])
          _ -> Next(model, [])
        }
      },
    )
  channels
}

pub fn reply_error_sends_error_status_reply_test() {
  let channels = start_with_error_app()
  let frames = h.connect(channels, "socket-1")
  h.join(channels, "socket-1", "room:lobby", "join-ref", "join-ref")
  let _join_reply = h.recv(frames)

  h.route(channels, "socket-1", "[null,\"ref-9\",\"room:lobby\",\"fail\",{}]")

  let reply = h.recv(frames)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("nope") |> should.be_true
  reply |> string.contains("ref-9") |> should.be_true

  beryl.stop(channels)
}

pub fn event_on_unjoined_topic_gets_unmatched_topic_error_test() {
  let channels = start_with_error_app()
  let frames = h.connect(channels, "socket-1")

  // Push to a topic this socket never joined: Phoenix clients expect an
  // immediate error reply rather than a push timeout.
  h.route(channels, "socket-1", "[null,\"ref-1\",\"room:lobby\",\"hello\",{}]")

  let reply = h.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("unmatched topic") |> should.be_true
  reply |> string.contains("ref-1") |> should.be_true

  beryl.stop(channels)
}

pub fn unjoined_event_without_ref_is_dropped_test() {
  let channels = start_with_error_app()
  let frames = h.connect(channels, "socket-1")

  h.route(channels, "socket-1", "[null,null,\"room:lobby\",\"hello\",{}]")

  h.recv_none(frames)

  beryl.stop(channels)
}

pub fn refless_fail_produces_no_error_frame_test() {
  let channels = start_with_error_app()
  let frames = h.connect(channels, "socket-1")
  h.join(channels, "socket-1", "room:lobby", "join-ref", "join-ref")
  let _join_reply = h.recv(frames)

  // No ref on the inbound message: there is nothing to correlate an error
  // reply with, so no frame is sent.
  h.route(channels, "socket-1", "[null,null,\"room:lobby\",\"fail\",{}]")

  h.recv_none(frames)

  beryl.stop(channels)
}
