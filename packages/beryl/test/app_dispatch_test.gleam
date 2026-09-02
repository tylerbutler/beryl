//// Core app-side dispatch tests (`beryl.child_spec`): join accept/reject,
//// fail-closed unanswered joins, replies, typed `Info` via `Sender`,
//// duplicate-join replacement, and `Closed` delivery on leave/disconnect.

import app_test_helper
import beryl
import beryl/socket.{
  type JoinRef, AcceptJoin, Closed, Info, Join, Message, Next, RejectJoin,
  ReplyError, ReplyOk,
}
import beryl/transport
import beryl/wire
import gleam/erlang/process
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import test_helper

pub type Msg {
  Note(String)
}

type JoinRaceMode {
  ReplaceWithCurrentReject
  RetryWithCurrentAccept
}

type JoinRaceModel {
  JoinRaceModel(previous: Option(JoinRef), mode: JoinRaceMode)
}

fn start_join_race(mode: JoinRaceMode) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(JoinRaceModel(previous: None, mode: mode), []) },
      update: fn(model, ev) {
        case ev {
          Join(_, _, current_ref) ->
            case model.previous {
              None -> {
                let next_model =
                  JoinRaceModel(..model, previous: Some(current_ref))
                case model.mode {
                  ReplaceWithCurrentReject ->
                    Next(next_model, [AcceptJoin(current_ref, None)])
                  RetryWithCurrentAccept ->
                    Next(next_model, [
                      RejectJoin(
                        current_ref,
                        json.object([
                          #("reason", json.string("initial rejection")),
                        ]),
                      ),
                    ])
                }
              }
              Some(stale_ref) ->
                case model.mode {
                  ReplaceWithCurrentReject ->
                    Next(model, [
                      AcceptJoin(
                        stale_ref,
                        Some(
                          json.object([
                            #("source", json.string("stale completion")),
                          ]),
                        ),
                      ),
                      RejectJoin(
                        current_ref,
                        json.object([
                          #("reason", json.string("current rejection")),
                        ]),
                      ),
                    ])
                  RetryWithCurrentAccept ->
                    Next(model, [
                      RejectJoin(
                        stale_ref,
                        json.object([
                          #("reason", json.string("stale completion")),
                        ]),
                      ),
                      AcceptJoin(
                        current_ref,
                        Some(
                          json.object([
                            #("source", json.string("current completion")),
                          ]),
                        ),
                      ),
                    ])
                }
            }
          _ -> Next(model, [])
        }
      },
    )
  channels
}

/// A start system that accepts `room:*`, rejects `secret:*`, ignores
/// `limbo:*` (leaving the join unanswered), replies ok/error to "echo" and
/// "fail", pushes on `Info`, and forwards every event to an observer.
fn start_observed(
  events: process.Subject(socket.Input(Msg)),
  senders: process.Subject(socket.Sender(Msg)),
) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(info) {
        process.send(senders, info.self)
        #(Nil, [])
      },
      update: fn(model, ev) {
        process.send(events, ev)
        case ev {
          Join("room:" <> _, _payload, ref) ->
            Next(model, [
              AcceptJoin(ref, Some(json.object([#("ok", json.bool(True))]))),
            ])
          Join("secret:" <> _, _payload, ref) ->
            Next(model, [
              RejectJoin(
                ref,
                json.object([#("reason", json.string("forbidden"))]),
              ),
            ])
          Join(_, _, _) -> Next(model, [])
          Message(_topic, "echo", _payload, Some(ref)) ->
            Next(model, [
              ReplyOk(ref, json.object([#("echoed", json.bool(True))])),
            ])
          Message(_topic, "fail", _payload, Some(ref)) ->
            Next(model, [
              ReplyError(ref, json.object([#("no", json.bool(True))])),
            ])
          Info(Note(text)) ->
            Next(model, [
              socket.Push(
                "room:a",
                "note",
                json.object([
                  #("text", json.string(text)),
                ]),
              ),
            ])
          _ -> Next(model, [])
        }
      },
    )
  channels
}

fn start_system() -> #(
  beryl.Sockets,
  process.Subject(socket.Input(Msg)),
  process.Subject(socket.Sender(Msg)),
) {
  let events = process.new_subject()
  let senders = process.new_subject()
  #(start_observed(events, senders), events, senders)
}

pub fn accept_join_sends_ok_reply_test() -> Nil {
  let #(channels, _events, _senders) = start_system()
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")

  let reply = app_test_helper.recv(frames)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
  reply |> string.contains("jr-1") |> should.be_true
  reply |> string.contains("r-1") |> should.be_true
  reply |> string.contains("\"ok\":true") |> should.be_true
}

pub fn reject_join_sends_error_reply_test() -> Nil {
  let #(channels, _events, _senders) = start_system()
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "secret:a", "jr-1", "r-1")

  let reply = app_test_helper.recv(frames)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("forbidden") |> should.be_true
}

pub fn unanswered_join_is_rejected_test() -> Nil {
  let #(channels, _events, _senders) = start_system()
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "limbo:a", "jr-1", "r-1")

  let reply = app_test_helper.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("join not acknowledged") |> should.be_true

  // The topic was never subscribed: events on it get "unmatched topic".
  app_test_helper.push(channels, "s1", "limbo:a", "echo", "r-2")
  let rejected = app_test_helper.recv(frames)
  rejected |> string.contains("unmatched topic") |> should.be_true
}

pub fn reply_ok_and_error_correlate_to_ref_test() -> Nil {
  let #(channels, _events, _senders) = start_system()
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = app_test_helper.recv(frames)

  app_test_helper.push(channels, "s1", "room:a", "echo", "r-2")
  let reply = app_test_helper.recv(frames)
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
  reply |> string.contains("\"echoed\":true") |> should.be_true
  reply |> string.contains("r-2") |> should.be_true

  app_test_helper.push(channels, "s1", "room:a", "fail", "r-3")
  let error_reply = app_test_helper.recv(frames)
  error_reply |> string.contains("\"status\":\"error\"") |> should.be_true
  error_reply |> string.contains("r-3") |> should.be_true
}

pub fn sender_delivers_typed_info_test() -> Nil {
  let #(channels, events, senders) = start_system()
  let frames = app_test_helper.connect(channels, "s1")
  let assert Ok(sender) = process.receive(senders, 500)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = app_test_helper.recv(frames)

  socket.notify(sender, Note("hello"))

  // The observer sees the typed Info event...
  let assert Join(_, _, _) = app_test_helper.next_event(events)
  let assert Info(Note("hello")) = app_test_helper.next_event(events)
  // ...and the update's Push reaches the wire.
  let push = app_test_helper.recv(frames)
  push |> string.contains("note") |> should.be_true
  push |> string.contains("hello") |> should.be_true
}

pub fn leave_acks_then_closes_and_delivers_closed_test() -> Nil {
  let #(channels, events, _senders) = start_system()
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = app_test_helper.recv(frames)
  let assert Join(_, _, _) = app_test_helper.next_event(events)

  app_test_helper.route(
    channels,
    "s1",
    "[\"jr-1\",\"r-2\",\"room:a\",\"phx_leave\",{}]",
  )

  // Reply to the leave ref first, then the terminal close frame.
  let leave_reply = app_test_helper.recv(frames)
  leave_reply |> string.contains("phx_reply") |> should.be_true
  leave_reply |> string.contains("r-2") |> should.be_true
  let close_frame = app_test_helper.recv(frames)
  close_frame |> string.contains("phx_close") |> should.be_true

  let assert Closed("room:a", socket.Normal) =
    app_test_helper.next_event(events)
  Nil
}

pub fn disconnect_delivers_closed_for_every_topic_test() -> Nil {
  let #(channels, events, _senders) = start_system()
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply_a = app_test_helper.recv(frames)
  app_test_helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _reply_b = app_test_helper.recv(frames)
  let assert Join(_, _, _) = app_test_helper.next_event(events)
  let assert Join(_, _, _) = app_test_helper.next_event(events)

  transport_disconnect(channels, "s1")

  // Closed for both topics, in sorted topic order.
  let assert Closed("room:a", socket.Normal) =
    app_test_helper.next_event(events)
  let assert Closed("room:b", socket.Normal) =
    app_test_helper.next_event(events)
  Nil
}

pub fn duplicate_join_closes_previous_instance_first_test() -> Nil {
  let #(channels, events, _senders) = start_system()
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _first_reply = app_test_helper.recv(frames)
  let assert Join(_, _, _) = app_test_helper.next_event(events)

  app_test_helper.join(channels, "s1", "room:a", "jr-2", "r-2")

  // Old instance closes (Closed delivered, phx_close sent), then the new
  // join is delivered and accepted.
  let assert Closed("room:a", socket.Normal) =
    app_test_helper.next_event(events)
  let assert Join("room:a", _, _) = app_test_helper.next_event(events)
  let close_frame = app_test_helper.recv(frames)
  close_frame |> string.contains("phx_close") |> should.be_true
  let rejoin_reply = app_test_helper.recv(frames)
  rejoin_reply |> string.contains("phx_reply") |> should.be_true
  rejoin_reply |> string.contains("jr-2") |> should.be_true
}

pub fn delayed_stale_accept_cannot_override_current_replacement_reject_test() -> Nil {
  let channels = start_join_race(ReplaceWithCurrentReject)
  let frames = app_test_helper.connect(channels, "s1")

  app_test_helper.join(channels, "s1", "room:a", "jr-same", "r-same")
  app_test_helper.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true

  app_test_helper.join(channels, "s1", "room:a", "jr-same", "r-same")
  app_test_helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  let replacement_reply = app_test_helper.recv(frames)
  replacement_reply
  |> string.contains("\"status\":\"error\"")
  |> should.be_true
  replacement_reply
  |> string.contains("current rejection")
  |> should.be_true
  replacement_reply |> string.contains("jr-same") |> should.be_true
  app_test_helper.recv_none(frames)
}

pub fn delayed_stale_reject_cannot_override_current_retry_accept_test() -> Nil {
  let channels = start_join_race(RetryWithCurrentAccept)
  let frames = app_test_helper.connect(channels, "s1")

  app_test_helper.join(channels, "s1", "room:a", "jr-same", "r-same")
  app_test_helper.recv(frames)
  |> string.contains("initial rejection")
  |> should.be_true

  app_test_helper.join(channels, "s1", "room:a", "jr-same", "r-same")
  let retry_reply = app_test_helper.recv(frames)
  retry_reply |> string.contains("\"status\":\"ok\"") |> should.be_true
  retry_reply
  |> string.contains("current completion")
  |> should.be_true
  retry_reply |> string.contains("jr-same") |> should.be_true
  app_test_helper.recv_none(frames)
}

pub fn runtime_is_supervised_and_restarts_with_dispatch_intact_test() -> Nil {
  let #(channels, _events, _senders) = start_system()
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)

  // Kill the runtime process outright: the internal supervisor must
  // restart it with the app's init/update intact (per-socket state is
  // dropped on restart).
  let assert Ok(old_pid) = beryl.app_runtime_pid(channels)
  process.kill(old_pid)
  test_helper.wait_until(
    fn() {
      case beryl.app_runtime_pid(channels) {
        Ok(new_pid) -> new_pid != old_pid
        Error(Nil) -> False
      }
    },
    2000,
    10,
  )

  // A fresh socket joins and is served by the restarted runtime.
  let frames2 = app_test_helper.connect(channels, "s2")
  app_test_helper.join(channels, "s2", "room:b", "jr-2", "r-2")
  let reply = app_test_helper.recv(frames2)
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
}

pub fn heartbeat_gets_reply_test() -> Nil {
  let #(channels, _events, _senders) = start_system()
  let frames = app_test_helper.connect(channels, "s1")

  app_test_helper.route(
    channels,
    "s1",
    "[null,\"hb-1\",\"phoenix\",\"heartbeat\",{}]",
  )

  let reply = app_test_helper.recv(frames)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("hb-1") |> should.be_true
}

fn transport_disconnect(channels: beryl.Sockets, socket_id: String) -> Nil {
  transport.socket_disconnected(channels, socket_id)
}
