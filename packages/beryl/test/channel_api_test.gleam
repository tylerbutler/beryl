//// Tests for the public channel API: handler sealing, join accept/reject,
//// typed callback dispatch, ordered actions, close/socket-stop results,
//// and typed server-side sends through the layer-owned `Sender`.

import beryl/channel
import beryl/presence
import beryl/socket
import gleam/bit_array
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleeunit/should
import vouch

pub fn main() {
  vouch.main()
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
) -> channel.RoutedJoinContext {
  channel.RoutedJoinContext(
    socket_id: "socket-1",
    seed: socket.empty_seed(),
    topic: topic,
    params: [],
    payload: payload,
    deliver: deliver,
  )
}

fn quiet_context(topic: String) -> channel.RoutedJoinContext {
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

fn describe(effect: socket.Effect) -> String {
  case effect {
    socket.Push(event: event, payload: payload, ..) ->
      "push/" <> event <> "/" <> json.to_string(payload)
    socket.Broadcast(event: event, payload: payload, ..) ->
      "broadcast/" <> event <> "/" <> json.to_string(payload)
    socket.BroadcastFrom(event: event, payload: payload, ..) ->
      "broadcast_from/" <> event <> "/" <> json.to_string(payload)
    socket.ReplyOk(payload: payload, ..) ->
      "reply_ok/" <> json.to_string(payload)
    socket.ReplyError(payload: payload, ..) ->
      "reply_error/" <> json.to_string(payload)
    socket.PresenceTrack(key: key, meta: meta, ..) ->
      "presence_track/" <> key <> "/" <> json.to_string(meta)
    socket.PresenceUntrack(key: key, ..) -> "presence_untrack/" <> key
    socket.PushPresence(event: event, encode: encode, ..) ->
      "push_presence/" <> event <> "/" <> json.to_string(encode([]))
    socket.BroadcastPresence(event: event, encode: encode, ..) ->
      "broadcast_presence/" <> event <> "/" <> json.to_string(encode([]))
    _ -> "other"
  }
}

fn rendered(actions: List(channel.Action(phase))) -> String {
  channel.effects("room:lobby", actions)
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
  channel.handler(pattern, fn(context) {
    let callbacks =
      channel.callbacks()
      |> channel.on_message(fn(count, message) {
        case message.event {
          "bump" ->
            channel.next(count + 1, [
              channel.push("total", json.int(count + 1)),
              channel.broadcast("bumped", json.string(context.topic)),
            ])
          "quit" -> channel.close([channel.push("bye", json.int(count))])
          "boom" -> channel.stop_socket(socket.Errored("boom"))
          _ -> channel.next(count, [])
        }
      })
      |> channel.on_binary(fn(count, data) {
        channel.next(count, [
          channel.push("bytes", json.int(bit_array.byte_size(data))),
        ])
      })
      |> channel.on_info(fn(count, note) {
        case note {
          Note(text) ->
            channel.next(count, [
              channel.push(
                "note",
                json.string(context.socket_id <> ":" <> text),
              ),
            ])
          Bye -> channel.close([])
        }
      })

    channel.accept(0, callbacks)
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
    channel.handler("room:*", fn(_context) {
      channel.accept(Nil, channel.callbacks())
      |> channel.with_reply(json.object([#("ok", json.bool(True))]))
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
    channel.handler("secret:*", fn(_context) {
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
    channel.handler("room:*", fn(context) {
      let decoded =
        decode.run(context.payload, decode.string)
        |> result.unwrap("<undecodable>")
      channel.accept(Nil, channel.callbacks())
      |> channel.with_reply(
        json.object([
          #("socket", json.string(context.socket_id)),
          #("topic", json.string(context.topic)),
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
    channel.StepClose(..) | channel.StepStop(..) -> should.fail()
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
    channel.StepClose(..) | channel.StepStop(..) -> should.fail()
  }
}

pub fn unhandled_events_continue_without_actions_test() {
  let handler =
    channel.handler("room:*", fn(_context) {
      channel.accept(Nil, channel.callbacks())
    })

  let live =
    channel.open(handler, quiet_context("room:lobby")) |> accepted_channel

  case live.on_message(client_message("anything")) {
    channel.StepContinue(_next, actions) -> actions |> should.equal([])
    channel.StepClose(..) | channel.StepStop(..) -> should.fail()
  }
}

pub fn binary_frames_reach_the_binary_callback_test() {
  let live =
    channel.open(counter_handler("room:*"), quiet_context("room:lobby"))
    |> accepted_channel

  case live.on_binary(<<1, 2, 3>>) {
    channel.StepContinue(_next, actions) ->
      actions |> rendered |> should.equal("push/bytes/3")
    channel.StepClose(..) | channel.StepStop(..) -> should.fail()
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
    channel.StepContinue(..) | channel.StepStop(..) -> should.fail()
  }
}

pub fn stop_socket_carries_only_a_reason_test() {
  let live =
    channel.open(counter_handler("room:*"), quiet_context("room:lobby"))
    |> accepted_channel

  case live.on_message(client_message("boom")) {
    channel.StepStop(reason) -> reason |> should.equal(socket.Errored("boom"))
    channel.StepContinue(..) | channel.StepClose(..) -> should.fail()
  }
}

pub fn terminate_runs_the_terminate_callback_test() {
  let observed = process.new_subject()
  let handler =
    channel.handler("room:*", fn(_context) {
      let callbacks =
        channel.callbacks()
        |> channel.on_terminate(fn(_state, reason) {
          process.send(observed, reason)
          []
        })
      channel.accept(Nil, callbacks)
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
    channel.handler("room:*", fn(context) {
      process.send(senders, context.self)
      let callbacks =
        channel.callbacks()
        |> channel.on_info(fn(_state, note) {
          case note {
            Note(text) ->
              channel.next(Nil, [channel.push("note", json.string(text))])
            Bye -> channel.close([])
          }
        })
      channel.accept(Nil, callbacks)
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
    channel.StepClose(..) | channel.StepStop(..) -> should.fail()
  }
}

pub fn an_unrun_mail_delivers_nothing_test() {
  let outbox = process.new_subject()
  let senders = process.new_subject()

  let handler =
    channel.handler("room:*", fn(context) {
      process.send(senders, context.self)
      let callbacks =
        channel.callbacks()
        |> channel.on_info(fn(count, note) {
          let assert Note(text) = note as "only Note values are sent here"
          channel.next(count + 1, [
            channel.push("note", json.string(text)),
          ])
        })
      channel.accept(0, callbacks)
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
    channel.StepClose(..) | channel.StepStop(..) -> should.fail()
  }
}

pub fn a_mail_addressed_to_another_join_delivers_nothing_test() {
  let outbox = process.new_subject()
  let senders = process.new_subject()

  let handler =
    channel.handler("room:*", fn(context) {
      process.send(senders, context.self)
      let callbacks =
        channel.callbacks()
        |> channel.on_info(fn(_state, note) {
          case note {
            Note(text) ->
              channel.next(Nil, [channel.push("note", json.string(text))])
            Bye -> channel.close([])
          }
        })
      channel.accept(Nil, callbacks)
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
    channel.StepClose(..) | channel.StepStop(..) -> should.fail()
  }

  // ...so it is still intact and still the first join's message when the
  // join that sealed it runs it.
  case first.on_mail(mail) {
    channel.StepContinue(_next, actions) ->
      actions |> rendered |> should.equal("push/note/\"mine\"")
    channel.StepClose(..) | channel.StepStop(..) -> should.fail()
  }
}

pub fn info_can_close_the_channel_test() {
  let outbox = process.new_subject()
  let senders = process.new_subject()
  let handler =
    channel.handler("room:*", fn(context) {
      process.send(senders, context.self)
      let callbacks =
        channel.callbacks()
        |> channel.on_info(fn(_state, note) {
          case note {
            Bye -> channel.close([])
            Note(_) -> channel.next(Nil, [])
          }
        })
      channel.accept(Nil, callbacks)
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
    channel.StepContinue(..) | channel.StepStop(..) -> should.fail()
  }
}

// --- actions ---------------------------------------------------------------
fn shared_active_actions() -> List(channel.Action(channel.Active)) {
  [
    channel.broadcast("broadcast", json.int(1)),
    channel.presence_untrack("user:1"),
    channel.broadcast_presence("state", fn(_entries) { json.int(2) }),
  ]
}

fn shared_closing_actions() -> List(channel.Action(channel.Closing)) {
  [
    channel.broadcast("broadcast", json.int(1)),
    channel.presence_untrack("user:1"),
    channel.broadcast_presence("state", fn(_entries) { json.int(2) }),
  ]
}

pub fn shared_actions_are_valid_in_both_phases_test() {
  let expected =
    "broadcast/broadcast/1,presence_untrack/user:1,"
    <> "broadcast_presence/state/2"

  shared_active_actions() |> rendered |> should.equal(expected)
  shared_closing_actions() |> rendered |> should.equal(expected)
}

pub fn actions_cover_the_core_effect_capabilities_test() {
  let reply =
    socket.make_message_ref(
      topic: "room:lobby",
      join_ref: option.Some("1"),
      msg_ref: option.Some("2"),
    )

  let built = [
    channel.push("push", json.int(1)),
    channel.broadcast("broadcast", json.int(2)),
    channel.broadcast_from("broadcast_from", json.int(3)),
    channel.reply_ok(option.Some(reply), json.int(4)),
    channel.reply_error(option.Some(reply), json.int(5)),
    channel.presence_track("user:1", json.int(6)),
    channel.presence_untrack("user:1"),
    channel.push_presence("state", fn(entries) {
      json.int(list.length(entries))
    }),
    channel.broadcast_presence("state", fn(entries) {
      json.int(list.length(entries) + 10)
    }),
  ]

  built
  |> rendered
  |> should.equal(
    "push/push/1,broadcast/broadcast/2,broadcast_from/broadcast_from/3,"
    <> "reply_ok/4,reply_error/5,presence_track/user:1/6,"
    <> "presence_untrack/user:1,push_presence/state/0,"
    <> "broadcast_presence/state/10",
  )
}

pub fn optional_reply_without_a_ref_lowers_to_no_effect_test() {
  channel.effects("room:lobby", [
    channel.reply_ok(option.None, json.int(1)),
    channel.reply_error(option.None, json.int(2)),
  ])
  |> should.equal([])
}

pub fn optional_reply_with_a_ref_lowers_in_order_test() {
  let reply =
    socket.make_message_ref(
      topic: "room:lobby",
      join_ref: option.Some("1"),
      msg_ref: option.Some("2"),
    )

  [
    channel.reply_ok(option.Some(reply), json.int(1)),
    channel.reply_error(option.Some(reply), json.int(2)),
  ]
  |> rendered
  |> should.equal("reply_ok/1,reply_error/2")
}

pub fn repeated_join_action_lists_append_left_to_right_test() {
  let handler =
    channel.handler("room:*", fn(_context) {
      channel.accept(Nil, channel.callbacks())
      |> channel.with_actions([channel.push("first", json.int(1))])
      |> channel.with_actions([channel.push("second", json.int(2))])
    })

  case channel.open(handler, quiet_context("room:lobby")) {
    channel.Accepted(_reply, actions, _live) ->
      actions |> rendered |> should.equal("push/first/1,push/second/2")
    channel.Rejected(_) -> should.fail()
  }
}

pub fn presence_encoders_run_against_supplied_entries_test() {
  let actions = [
    channel.push_presence("state", fn(entries) {
      entries
      |> list.map(fn(entry) { entry.key })
      |> json.array(json.string)
    }),
  ]

  case channel.effects("room:lobby", actions) {
    [socket.PushPresence(encode: encode, ..)] ->
      encode([presence.PresenceEntry("s1", "user:1", json.null())])
      |> json.to_string
      |> should.equal("[\"user:1\"]")
    _ -> should.fail()
  }
}

pub fn an_empty_action_list_is_empty_test() {
  channel.effects("room:lobby", []) |> should.equal([])
}
