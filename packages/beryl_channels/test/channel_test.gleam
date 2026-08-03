//// Tests for the public channel API: handler sealing, join accept/reject,
//// typed callback dispatch, ordered actions, close/socket-stop results,
//// and typed server-side sends through the layer-owned `Sender`.

import beryl/presence
import beryl/socket
import beryl_channels/channel
import gleam/bit_array
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

/// A channel-local server-side message type, used to prove typed `info`
/// values survive a `Sender` round trip without erasure.
pub type Note {
  Note(text: String)
  Bye
}

// --- helpers ---------------------------------------------------------------

fn context(
  topic topic: String,
  payload payload: dynamic.Dynamic,
  deliver deliver: fn(channel.Mail) -> Nil,
) -> channel.JoinContext {
  channel.JoinContext(
    socket_id: "socket-1",
    seed: socket.empty_seed(),
    topic: topic,
    payload: payload,
    deliver: deliver,
  )
}

fn quiet_context(topic: String) -> channel.JoinContext {
  context(topic: topic, payload: dynamic.nil(), deliver: fn(_mail) { Nil })
}

fn client_message(event: String) -> channel.Message {
  channel.Message(
    topic: "room:lobby",
    event: event,
    payload: dynamic.nil(),
    reply: option.None,
  )
}

fn describe(action: channel.Action) -> String {
  case action {
    channel.PushAction(event, payload) ->
      "push/" <> event <> "/" <> json.to_string(payload)
    channel.BroadcastAction(event, payload) ->
      "broadcast/" <> event <> "/" <> json.to_string(payload)
    channel.BroadcastFromAction(event, payload) ->
      "broadcast_from/" <> event <> "/" <> json.to_string(payload)
    channel.ReplyOkAction(_reply, payload) ->
      "reply_ok/" <> json.to_string(payload)
    channel.ReplyErrorAction(_reply, payload) ->
      "reply_error/" <> json.to_string(payload)
    channel.PresenceTrackAction(key, meta) ->
      "presence_track/" <> key <> "/" <> json.to_string(meta)
    channel.PresenceUntrackAction(key) -> "presence_untrack/" <> key
    channel.PushPresenceAction(event, encode) ->
      "push_presence/" <> event <> "/" <> json.to_string(encode([]))
    channel.BroadcastPresenceAction(event, encode) ->
      "broadcast_presence/" <> event <> "/" <> json.to_string(encode([]))
  }
}

fn rendered(actions: List(channel.Action)) -> String {
  actions
  |> list.map(describe)
  |> string.join(",")
}

fn accepted_channel(outcome: channel.JoinOutcome) -> channel.LiveChannel {
  let assert channel.Accepted(_reply, _actions, live) = outcome
    as "expected the join to be accepted"
  live
}

/// A minimal counting channel: every `"bump"` message adds one and pushes
/// the running total; `"quit"` closes the channel; `"boom"` stops the socket.
fn counter_handler(pattern: String) -> channel.Handler {
  channel.handler(pattern, fn(info, topic, _payload) {
    let callbacks =
      channel.callbacks()
      |> channel.on_message(fn(count, message) {
        case message.event {
          "bump" ->
            channel.continue_with(
              count + 1,
              channel.actions()
                |> channel.push("total", json.int(count + 1))
                |> channel.broadcast("bumped", json.string(topic)),
            )
          "quit" ->
            channel.close_with(
              channel.actions() |> channel.push("bye", json.int(count)),
            )
          "boom" -> channel.stop_socket(socket.Errored("boom"))
          _ -> channel.continue(count)
        }
      })
      |> channel.on_binary(fn(count, data) {
        channel.continue_with(
          count,
          channel.actions()
            |> channel.push("bytes", json.int(bit_array.byte_size(data))),
        )
      })
      |> channel.on_info(fn(count, note) {
        case note {
          Note(text) ->
            channel.continue_with(
              count,
              channel.actions()
                |> channel.push(
                  "note",
                  json.string(info.socket_id <> ":" <> text),
                ),
            )
          Bye -> channel.close()
        }
      })

    channel.accept(channel.joined(0, callbacks))
  })
}

// --- handler registration --------------------------------------------------

pub fn handler_exposes_its_pattern_test() {
  counter_handler("room:*")
  |> channel.pattern
  |> should.equal("room:*")
}

// --- join results ----------------------------------------------------------

pub fn join_accepts_without_a_reply_test() {
  case channel.open(counter_handler("room:*"), quiet_context("room:lobby")) {
    channel.Accepted(reply, _actions, _live) -> reply |> should.be_none
    channel.Rejected(_) -> should.fail()
  }
}

pub fn join_accepts_with_a_reply_payload_test() {
  let handler =
    channel.handler("room:*", fn(_info, _topic, _payload) {
      channel.accept_with(
        channel.joined(Nil, channel.callbacks()),
        json.object([#("ok", json.bool(True))]),
      )
    })

  case channel.open(handler, quiet_context("room:lobby")) {
    channel.Accepted(reply, _actions, _live) ->
      reply
      |> should.be_some
      |> json.to_string
      |> should.equal("{\"ok\":true}")
    channel.Rejected(_) -> should.fail()
  }
}

pub fn join_can_be_rejected_test() {
  let handler =
    channel.handler("secret:*", fn(_info, _topic, _payload) {
      channel.reject(json.object([#("reason", json.string("forbidden"))]))
    })

  case channel.open(handler, quiet_context("secret:vault")) {
    channel.Accepted(_, _, _) -> should.fail()
    channel.Rejected(reason) ->
      reason
      |> json.to_string
      |> should.equal("{\"reason\":\"forbidden\"}")
  }
}

pub fn join_receives_the_topic_and_payload_test() {
  let handler =
    channel.handler("room:*", fn(info, topic, payload) {
      let decoded =
        decode.run(payload, decode.string) |> result.unwrap("<undecodable>")
      channel.accept_with(
        channel.joined(Nil, channel.callbacks()),
        json.object([
          #("socket", json.string(info.socket_id)),
          #("topic", json.string(topic)),
          #("payload", json.string(decoded)),
        ]),
      )
    })

  let outcome =
    channel.open(
      handler,
      context(
        topic: "room:lobby",
        payload: dynamic.string("hello"),
        deliver: fn(_mail) { Nil },
      ),
    )

  case outcome {
    channel.Accepted(reply, _actions, _live) ->
      reply
      |> should.be_some
      |> json.to_string
      |> should.equal(
        "{\"socket\":\"socket-1\",\"topic\":\"room:lobby\",\"payload\":\"hello\"}",
      )
    channel.Rejected(_) -> should.fail()
  }
}

// --- callback dispatch and state threading ---------------------------------

pub fn message_actions_keep_their_order_test() {
  let live =
    channel.open(counter_handler("room:*"), quiet_context("room:lobby"))
    |> accepted_channel

  case live.on_message(client_message("bump")) {
    channel.StepContinue(_next, actions) ->
      actions
      |> rendered
      |> should.equal("push/total/1,broadcast/bumped/\"room:lobby\"")
    _ -> should.fail()
  }
}

pub fn channel_state_is_threaded_across_messages_test() {
  let live =
    channel.open(counter_handler("room:*"), quiet_context("room:lobby"))
    |> accepted_channel

  let assert channel.StepContinue(after_first, _) =
    live.on_message(client_message("bump"))
  let assert channel.StepContinue(after_second, _) =
    after_first.on_message(client_message("bump"))

  case after_second.on_message(client_message("bump")) {
    channel.StepContinue(_next, actions) ->
      actions
      |> rendered
      |> should.equal("push/total/3,broadcast/bumped/\"room:lobby\"")
    _ -> should.fail()
  }
}

pub fn unhandled_events_continue_without_actions_test() {
  let handler =
    channel.handler("room:*", fn(_info, _topic, _payload) {
      channel.accept(channel.joined(Nil, channel.callbacks()))
    })

  let live =
    channel.open(handler, quiet_context("room:lobby")) |> accepted_channel

  case live.on_message(client_message("anything")) {
    channel.StepContinue(_next, actions) -> actions |> should.equal([])
    _ -> should.fail()
  }
}

pub fn binary_frames_reach_the_binary_callback_test() {
  let live =
    channel.open(counter_handler("room:*"), quiet_context("room:lobby"))
    |> accepted_channel

  case live.on_binary(<<1, 2, 3>>) {
    channel.StepContinue(_next, actions) ->
      actions |> rendered |> should.equal("push/bytes/3")
    _ -> should.fail()
  }
}

// --- close and socket stop -------------------------------------------------

pub fn close_carries_its_final_actions_test() {
  let live =
    channel.open(counter_handler("room:*"), quiet_context("room:lobby"))
    |> accepted_channel

  case live.on_message(client_message("quit")) {
    channel.StepClose(actions) ->
      actions |> rendered |> should.equal("push/bye/0")
    _ -> should.fail()
  }
}

pub fn stop_socket_carries_only_a_reason_test() {
  let live =
    channel.open(counter_handler("room:*"), quiet_context("room:lobby"))
    |> accepted_channel

  case live.on_message(client_message("boom")) {
    channel.StepStop(reason) -> reason |> should.equal(socket.Errored("boom"))
    _ -> should.fail()
  }
}

pub fn terminate_runs_the_terminate_callback_test() {
  let observed = process.new_subject()
  let handler =
    channel.handler("room:*", fn(_info, _topic, _payload) {
      let callbacks =
        channel.callbacks()
        |> channel.on_terminate(fn(_state, reason) {
          process.send(observed, reason)
          channel.actions()
        })
      channel.accept(channel.joined(Nil, callbacks))
    })

  let live =
    channel.open(handler, quiet_context("room:lobby")) |> accepted_channel
  let _actions = live.on_terminate(socket.Shutdown)

  process.receive(observed, 100) |> should.equal(Ok(socket.Shutdown))
}

// --- typed server-side sends -----------------------------------------------

pub fn sender_seals_typed_info_into_one_mail_per_send_test() {
  let outbox = process.new_subject()
  let senders = process.new_subject()

  let handler =
    channel.handler("room:*", fn(info, _topic, _payload) {
      process.send(senders, info.self)
      let callbacks =
        channel.callbacks()
        |> channel.on_info(fn(_state, note) {
          case note {
            Note(text) ->
              channel.continue_with(
                Nil,
                channel.actions() |> channel.push("note", json.string(text)),
              )
            Bye -> channel.close()
          }
        })
      channel.accept(channel.joined(Nil, callbacks))
    })

  let live =
    channel.open(
      handler,
      context(topic: "room:lobby", payload: dynamic.nil(), deliver: fn(mail) {
        process.send(outbox, mail)
      }),
    )
    |> accepted_channel

  let assert Ok(sender) = process.receive(senders, 100)
  channel.notify(sender, Note("hi"))
  channel.notify(sender, Note("again"))

  // One send, one mail: no coalescing.
  let assert Ok(first) = process.receive(outbox, 100)
  let assert Ok(second) = process.receive(outbox, 100)
  process.receive(outbox, 0) |> should.equal(Error(Nil))

  let assert channel.StepContinue(next, first_actions) = live.on_mail(first)
  first_actions |> rendered |> should.equal("push/note/\"hi\"")

  case next.on_mail(second) {
    channel.StepContinue(_next, actions) ->
      actions |> rendered |> should.equal("push/note/\"again\"")
    _ -> should.fail()
  }
}

pub fn an_unrun_mail_delivers_nothing_test() {
  let outbox = process.new_subject()
  let senders = process.new_subject()

  let handler =
    channel.handler("room:*", fn(info, _topic, _payload) {
      process.send(senders, info.self)
      let callbacks =
        channel.callbacks()
        |> channel.on_info(fn(count, note) {
          let assert Note(text) = note as "only Note values are sent here"
          channel.continue_with(
            count + 1,
            channel.actions() |> channel.push("note", json.string(text)),
          )
        })
      channel.accept(channel.joined(0, callbacks))
    })

  let live =
    channel.open(
      handler,
      context(topic: "room:lobby", payload: dynamic.nil(), deliver: fn(mail) {
        process.send(outbox, mail)
      }),
    )
    |> accepted_channel

  let assert Ok(sender) = process.receive(senders, 100)
  channel.notify(sender, Note("dropped"))
  channel.notify(sender, Note("kept"))

  // The router drops the first mail instead of running it — as it does for
  // a stale generation — so its payload reaches nothing at all, and the
  // channel's state is untouched by it.
  let assert Ok(_dropped) = process.receive(outbox, 100)
  let assert Ok(kept) = process.receive(outbox, 100)

  case live.on_mail(kept) {
    channel.StepContinue(_next, actions) ->
      actions |> rendered |> should.equal("push/note/\"kept\"")
    _ -> should.fail()
  }
}

pub fn a_mail_addressed_to_another_join_delivers_nothing_test() {
  let outbox = process.new_subject()
  let senders = process.new_subject()

  let handler =
    channel.handler("room:*", fn(info, _topic, _payload) {
      process.send(senders, info.self)
      let callbacks =
        channel.callbacks()
        |> channel.on_info(fn(_state, note) {
          case note {
            Note(text) ->
              channel.continue_with(
                Nil,
                channel.actions() |> channel.push("note", json.string(text)),
              )
            Bye -> channel.close()
          }
        })
      channel.accept(channel.joined(Nil, callbacks))
    })

  let join_context =
    context(topic: "room:lobby", payload: dynamic.nil(), deliver: fn(mail) {
      process.send(outbox, mail)
    })
  let first = channel.open(handler, join_context) |> accepted_channel
  let second = channel.open(handler, join_context) |> accepted_channel

  let assert Ok(sender_of_first) = process.receive(senders, 100)
  let assert Ok(_sender_of_second) = process.receive(senders, 100)
  channel.notify(sender_of_first, Note("mine"))
  let assert Ok(mail) = process.receive(outbox, 100)

  // Handing one join's mail to another join delivers nothing and leaves
  // the mail sealed: the value is only ever readable by its own join.
  case second.on_mail(mail) {
    channel.StepContinue(_next, actions) -> actions |> should.equal([])
    _ -> should.fail()
  }

  // ...so it is still intact and still the first join's message when the
  // join that sealed it runs it.
  case first.on_mail(mail) {
    channel.StepContinue(_next, actions) ->
      actions |> rendered |> should.equal("push/note/\"mine\"")
    _ -> should.fail()
  }
}

pub fn info_can_close_the_channel_test() {
  let outbox = process.new_subject()
  let senders = process.new_subject()
  let handler =
    channel.handler("room:*", fn(info, _topic, _payload) {
      process.send(senders, info.self)
      let callbacks =
        channel.callbacks()
        |> channel.on_info(fn(_state, note) {
          case note {
            Bye -> channel.close()
            Note(_) -> channel.continue(Nil)
          }
        })
      channel.accept(channel.joined(Nil, callbacks))
    })

  let live =
    channel.open(
      handler,
      context(topic: "room:lobby", payload: dynamic.nil(), deliver: fn(mail) {
        process.send(outbox, mail)
      }),
    )
    |> accepted_channel
  let assert Ok(sender) = process.receive(senders, 100)
  channel.notify(sender, Bye)
  let assert Ok(mail) = process.receive(outbox, 100)

  case live.on_mail(mail) {
    channel.StepClose(actions) -> actions |> should.equal([])
    _ -> should.fail()
  }
}

// --- actions ---------------------------------------------------------------
pub fn actions_cover_the_core_effect_capabilities_test() {
  let reply =
    socket.make_message_ref(
      topic: "room:lobby",
      join_ref: option.Some("1"),
      msg_ref: option.Some("2"),
    )

  let built =
    channel.actions()
    |> channel.push("push", json.int(1))
    |> channel.broadcast("broadcast", json.int(2))
    |> channel.broadcast_from("broadcast_from", json.int(3))
    |> channel.reply_ok(reply, json.int(4))
    |> channel.reply_error(reply, json.int(5))
    |> channel.presence_track("user:1", json.int(6))
    |> channel.presence_untrack("user:1")
    |> channel.push_presence("state", fn(entries) {
      json.int(list.length(entries))
    })
    |> channel.broadcast_presence("state", fn(entries) {
      json.int(list.length(entries) + 10)
    })

  channel.action_list(built)
  |> rendered
  |> should.equal(
    "push/push/1,broadcast/broadcast/2,broadcast_from/broadcast_from/3,"
    <> "reply_ok/4,reply_error/5,presence_track/user:1/6,"
    <> "presence_untrack/user:1,push_presence/state/0,"
    <> "broadcast_presence/state/10",
  )
}

pub fn presence_encoders_run_against_supplied_entries_test() {
  let built =
    channel.actions()
    |> channel.push_presence("state", fn(entries) {
      entries
      |> list.map(fn(entry) { entry.key })
      |> json.array(json.string)
    })

  case channel.action_list(built) {
    [channel.PushPresenceAction(_event, encode)] ->
      encode([presence.PresenceEntry("s1", "user:1", json.null())])
      |> json.to_string
      |> should.equal("[\"user:1\"]")
    _ -> should.fail()
  }
}

pub fn an_empty_action_list_is_empty_test() {
  channel.action_list(channel.actions()) |> should.equal([])
}
