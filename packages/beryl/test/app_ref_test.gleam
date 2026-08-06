//// `Ref` validity and single-use semantics for app-side dispatch. A message
//// reply ref is single-use (a second reply against it is dropped) and stops
//// being valid once its topic closes — a stored ref replied to after the
//// topic left, or after a leave+rejoin, is dropped rather than sent as a
//// stale/duplicate reply. A ref stored while its topic stays open can still
//// be answered from a later turn (deferred reply).

import app_test_helpers as h
import beryl
import beryl/event.{type Ref, AcceptJoin, Info, Join, Message, Next, ReplyOk}
import beryl/wire
import gleam/erlang/process
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub type Msg {
  ReplyStashed
}

type Model {
  Model(stashed: Option(Ref))
}

/// - "double": reply to the same ref twice in one effects list (single-use).
/// - "stash": store the ref without replying (deferred reply).
/// - `Info(ReplyStashed)`: reply with the stored ref later.
fn start_system(senders: process.Subject(event.Sender(Msg))) -> beryl.Channels {
  let assert Ok(channels) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(info) {
        process.send(senders, info.self)
        #(Model(None), [])
      },
      update: fn(model: Model, ev) {
        case ev {
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
          _ -> Next(model, [])
        }
      },
    )
  channels
}

fn start() -> #(beryl.Channels, process.Subject(event.Sender(Msg))) {
  let senders = process.new_subject()
  #(start_system(senders), senders)
}

pub fn message_ref_is_single_use_test() {
  let #(channels, _senders) = start()
  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = h.recv(frames)

  h.push(channels, "s1", "room:a", "double", "r-2")

  // Only the first ReplyOk reaches the wire; the second is dropped because
  // the ref was already answered.
  let reply = h.recv(frames)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("r-2") |> should.be_true
  reply |> string.contains("\"n\":1") |> should.be_true
  h.recv_none(frames)
}

pub fn deferred_reply_from_info_is_delivered_test() {
  let #(channels, senders) = start()
  let frames = h.connect(channels, "s1")
  let assert Ok(sender) = process.receive(senders, 500)
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = h.recv(frames)

  // Stash the ref without replying; the topic stays open.
  h.push(channels, "s1", "room:a", "stash", "r-2")
  h.recv_none(frames)

  // A later turn answers the stored ref — still valid.
  event.notify(sender, ReplyStashed)
  let reply = h.recv(frames)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("r-2") |> should.be_true
  reply |> string.contains("\"late\":true") |> should.be_true
}

pub fn duplicate_outstanding_ref_is_rejected_then_reusable_test() {
  let senders = process.new_subject()
  let channels = start_system(senders)
  let frames = h.connect(channels, "s1")
  let assert Ok(sender) = process.receive(senders, 500)
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = h.recv(frames)

  // The first request stays outstanding. An explicit join_ref on the second
  // frame is the same effective key as the first frame's omitted join_ref.
  h.push(channels, "s1", "room:a", "stash", "r-2")
  h.route(channels, "s1", "[\"jr-1\",\"r-2\",\"room:a\",\"stash\",{}]")
  let duplicate = h.recv(frames)
  duplicate |> string.contains("\"status\":\"error\"") |> should.be_true
  duplicate |> string.contains("duplicate_ref") |> should.be_true

  // Completing the original request frees the key.
  event.notify(sender, ReplyStashed)
  let first_reply = h.recv(frames)
  first_reply |> string.contains("\"status\":\"ok\"") |> should.be_true

  // The same effective key can be used again after completion.
  h.push(channels, "s1", "room:a", "stash", "r-2")
  h.recv_none(frames)
  event.notify(sender, ReplyStashed)
  let reused_reply = h.recv(frames)
  reused_reply |> string.contains("\"status\":\"ok\"") |> should.be_true
  reused_reply |> string.contains("\"later\":true") |> should.be_true
}

pub fn reply_after_topic_close_is_dropped_test() {
  let #(channels, senders) = start()
  let frames = h.connect(channels, "s1")
  let assert Ok(sender) = process.receive(senders, 500)
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = h.recv(frames)

  h.push(channels, "s1", "room:a", "stash", "r-2")

  // Leave the topic: reply to the leave ref, then the terminal close frame.
  h.route(channels, "s1", "[\"jr-1\",\"r-3\",\"room:a\",\"phx_leave\",{}]")
  let _leave_reply = h.recv(frames)
  let close_frame = h.recv(frames)
  close_frame |> string.contains("phx_close") |> should.be_true

  // The stored ref is stale now that its topic closed: the late reply is
  // dropped rather than sent.
  event.notify(sender, ReplyStashed)
  h.recv_none(frames)
}

pub fn reply_after_rejoin_is_dropped_test() {
  let #(channels, senders) = start()
  let frames = h.connect(channels, "s1")
  let assert Ok(sender) = process.receive(senders, 500)
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = h.recv(frames)

  h.push(channels, "s1", "room:a", "stash", "r-2")

  // Leave and rejoin the same topic under a fresh join_ref.
  h.route(channels, "s1", "[\"jr-1\",\"r-3\",\"room:a\",\"phx_leave\",{}]")
  let _leave_reply = h.recv(frames)
  let _close_frame = h.recv(frames)
  h.join(channels, "s1", "room:a", "jr-2", "r-4")
  let rejoin_reply = h.recv(frames)
  rejoin_reply |> string.contains("\"status\":\"ok\"") |> should.be_true

  // The socket is joined again, but the ref stashed under the previous
  // instance is stale: replying with it is dropped, not delivered against
  // the new join.
  event.notify(sender, ReplyStashed)
  h.recv_none(frames)
}
