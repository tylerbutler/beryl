//// `ReplyRef` validity and single-use semantics for app-side dispatch. A
//// reply ref is single-use (a second reply against it is dropped) and stops
//// being valid once its topic closes — a stored ref replied to after the
//// topic left, or after a leave+rejoin, is dropped rather than sent as a
//// stale/duplicate reply. A ref stored while its topic stays open can still
//// be answered from a later turn (deferred reply).

import app_test_helper
import beryl
import beryl/socket.{
  type ReplyRef, AcceptJoin, Info, Join, Message, Next, ReplyOk,
}
import beryl/wire
import gleam/erlang/process
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should

pub type AppMessage {
  ReplyStashed
}

type Model {
  Model(stashed: Option(ReplyRef))
}

/// - "double": reply to the same ref twice in one effects list (single-use).
/// - "stash": store the ref without replying (deferred reply).
/// - `Info(ReplyStashed)`: reply with the stored ref later.
fn start_system(
  senders: process.Subject(socket.Sender(AppMessage)),
) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(info) {
        process.send(senders, info.self)
        #(Model(None), [])
      },
      update: fn(model: Model, event) {
        case event {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          Message(_topic, "double", _payload, Some(ref)) ->
            Next(model, [
              ReplyOk(ref, json.object([#("n", json.int(1))])),
              ReplyOk(ref, json.object([#("n", json.int(2))])),
            ])
          Message(_topic, "stash", _payload, Some(ref)) ->
            Next(Model(Some(ref)), [])
          Info(ReplyStashed) ->
            case model.stashed {
              Some(ref) ->
                Next(model, [
                  ReplyOk(ref, json.object([#("late", json.bool(True))])),
                ])
              None -> Next(model, [])
            }
          Message(..) | socket.Binary(..) | socket.Closed(..) -> Next(model, [])
        }
      },
    )
  channels
}

fn start() -> #(beryl.Sockets, process.Subject(socket.Sender(AppMessage))) {
  let senders = process.new_subject()
  #(start_system(senders), senders)
}

pub fn message_ref_is_single_use_test() -> Nil {
  let #(channels, _senders) = start()
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = app_test_helper.recv(frames)

  app_test_helper.push(channels, "s1", "room:a", "double", "r-2")

  // Only the first ReplyOk reaches the wire; the second is dropped because
  // the ref was already answered.
  let reply = app_test_helper.recv(frames)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("r-2") |> should.be_true
  reply |> string.contains("\"n\":1") |> should.be_true
  app_test_helper.recv_none(frames)
}

pub fn deferred_reply_from_info_is_delivered_test() -> Nil {
  let #(channels, senders) = start()
  let frames = app_test_helper.connect(channels, "s1")
  let assert Ok(sender) = process.receive(senders, 500)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = app_test_helper.recv(frames)

  // Stash the ref without replying; the topic stays open.
  app_test_helper.push(channels, "s1", "room:a", "stash", "r-2")
  app_test_helper.recv_none(frames)

  // A later turn answers the stored ref — still valid.
  socket.notify(sender, ReplyStashed)
  let reply = app_test_helper.recv(frames)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("r-2") |> should.be_true
  reply |> string.contains("\"late\":true") |> should.be_true
}

pub fn duplicate_outstanding_ref_is_rejected_then_reusable_test() -> Nil {
  let senders = process.new_subject()
  let channels = start_system(senders)
  let frames = app_test_helper.connect(channels, "s1")
  let assert Ok(sender) = process.receive(senders, 500)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = app_test_helper.recv(frames)

  // The first request stays outstanding. An explicit join_ref on the second
  // frame is the same effective key as the first frame's omitted join_ref.
  app_test_helper.push(channels, "s1", "room:a", "stash", "r-2")
  app_test_helper.route(
    channels,
    "s1",
    "[\"jr-1\",\"r-2\",\"room:a\",\"stash\",{}]",
  )
  let duplicate = app_test_helper.recv(frames)
  duplicate |> string.contains("\"status\":\"error\"") |> should.be_true
  duplicate |> string.contains("duplicate_ref") |> should.be_true

  // Completing the original request frees the key.
  socket.notify(sender, ReplyStashed)
  let first_reply = app_test_helper.recv(frames)
  first_reply |> string.contains("\"status\":\"ok\"") |> should.be_true

  // The same effective key can be used again after completion.
  app_test_helper.push(channels, "s1", "room:a", "stash", "r-2")
  app_test_helper.recv_none(frames)
  socket.notify(sender, ReplyStashed)
  let reused_reply = app_test_helper.recv(frames)
  reused_reply |> string.contains("\"status\":\"ok\"") |> should.be_true
  reused_reply |> string.contains("\"late\":true") |> should.be_true
}

pub fn reply_after_topic_close_is_dropped_test() -> Nil {
  let #(channels, senders) = start()
  let frames = app_test_helper.connect(channels, "s1")
  let assert Ok(sender) = process.receive(senders, 500)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = app_test_helper.recv(frames)

  app_test_helper.push(channels, "s1", "room:a", "stash", "r-2")

  // Leave the topic: reply to the leave ref, then the terminal close frame.
  app_test_helper.route(
    channels,
    "s1",
    "[\"jr-1\",\"r-3\",\"room:a\",\"phx_leave\",{}]",
  )
  let _leave_reply = app_test_helper.recv(frames)
  let close_frame = app_test_helper.recv(frames)
  close_frame |> string.contains("phx_close") |> should.be_true

  // The stored ref is stale now that its topic closed: the late reply is
  // dropped rather than sent.
  socket.notify(sender, ReplyStashed)
  app_test_helper.recv_none(frames)
}

pub fn reply_after_rejoin_is_dropped_test() -> Nil {
  let #(channels, senders) = start()
  let frames = app_test_helper.connect(channels, "s1")
  let assert Ok(sender) = process.receive(senders, 500)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = app_test_helper.recv(frames)

  app_test_helper.push(channels, "s1", "room:a", "stash", "r-2")

  // Leave and rejoin the same topic under a fresh join_ref.
  app_test_helper.route(
    channels,
    "s1",
    "[\"jr-1\",\"r-3\",\"room:a\",\"phx_leave\",{}]",
  )
  let _leave_reply = app_test_helper.recv(frames)
  let _close_frame = app_test_helper.recv(frames)
  app_test_helper.join(channels, "s1", "room:a", "jr-2", "r-4")
  let rejoin_reply = app_test_helper.recv(frames)
  rejoin_reply |> string.contains("\"status\":\"ok\"") |> should.be_true

  // The socket is joined again, but the ref stashed under the previous
  // instance is stale: replying with it is dropped, not delivered against
  // the new join.
  socket.notify(sender, ReplyStashed)
  app_test_helper.recv_none(frames)
}
