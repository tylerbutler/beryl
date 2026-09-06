//// Error replies on the app runtime: `ReplyError` must reach the client as
//// a `phx_reply` with `"status": "error"` correlated to the client's ref
//// (Phoenix `push.receive("error", ...)`), unjoined-topic pushes get an
//// `unmatched topic` error, and refless errors are dropped.

import app_test_helper
import beryl
import beryl/socket.{
  AcceptJoin, Binary, Closed, Info, Join, Message, Next, ReplyError,
}
import beryl/wire
import gleam/json
import gleam/option.{Some}
import gleam/string
import gleeunit/should

/// Accepts every join; replies with an error to "fail" when the client
/// sent a ref (refless "fail" messages are unanswerable by construction).
fn start_with_error_app() -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, event) {
        case event {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, option.None)])
          Message(_topic, "fail", _payload, Some(ref)) ->
            Next(model, [
              ReplyError(ref, json.object([#("reason", json.string("nope"))])),
            ])
          Message(_, _, _, _) | Binary(_, _) | Closed(_, _) | Info(_) ->
            Next(model, [])
        }
      },
    )
  channels
}

pub fn reply_error_sends_error_status_reply_test() -> Nil {
  let channels = start_with_error_app()
  let frames = app_test_helper.connect(channels, "socket-1")
  app_test_helper.join(
    channels,
    "socket-1",
    "room:lobby",
    "join-ref",
    "join-ref",
  )
  let _join_reply = app_test_helper.recv(frames)

  app_test_helper.route(
    channels,
    "socket-1",
    "[null,\"ref-9\",\"room:lobby\",\"fail\",{}]",
  )

  let reply = app_test_helper.recv(frames)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("nope") |> should.be_true
  reply |> string.contains("ref-9") |> should.be_true

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn event_on_unjoined_topic_gets_unmatched_topic_error_test() -> Nil {
  let channels = start_with_error_app()
  let frames = app_test_helper.connect(channels, "socket-1")

  // Push to a topic this socket never joined: Phoenix clients expect an
  // immediate error reply rather than a push timeout.
  app_test_helper.route(
    channels,
    "socket-1",
    "[null,\"ref-1\",\"room:lobby\",\"hello\",{}]",
  )

  let reply = app_test_helper.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("unmatched topic") |> should.be_true
  reply |> string.contains("ref-1") |> should.be_true

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn unjoined_event_without_ref_is_dropped_test() -> Nil {
  let channels = start_with_error_app()
  let frames = app_test_helper.connect(channels, "socket-1")

  app_test_helper.route(
    channels,
    "socket-1",
    "[null,null,\"room:lobby\",\"hello\",{}]",
  )

  app_test_helper.recv_none(frames)

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn refless_fail_produces_no_error_frame_test() -> Nil {
  let channels = start_with_error_app()
  let frames = app_test_helper.connect(channels, "socket-1")
  app_test_helper.join(
    channels,
    "socket-1",
    "room:lobby",
    "join-ref",
    "join-ref",
  )
  let _join_reply = app_test_helper.recv(frames)

  // No ref on the inbound message: there is nothing to correlate an error
  // reply with, so no frame is sent.
  app_test_helper.route(
    channels,
    "socket-1",
    "[null,null,\"room:lobby\",\"fail\",{}]",
  )

  app_test_helper.recv_none(frames)

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}
