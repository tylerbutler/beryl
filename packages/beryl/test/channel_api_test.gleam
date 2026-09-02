//// Tests for the public channel API: handler sealing, join accept/reject,
//// typed callback dispatch, ordered actions, close results,
//// and typed server-side sends through the layer-owned `Sender`.

import beryl/channel
import beryl/presence
import beryl/socket
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

pub fn main() -> Nil {
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
  deliver deliver: fn(socket.Mail) -> Nil,
) -> socket.WorkerContext {
  socket.WorkerContext(
    socket_id: "socket-1",
    seed: socket.empty_seed(),
    topic: topic,
    payload: payload,
    deliver: deliver,
  )
}

fn quiet_context(topic: String) -> socket.WorkerContext {
  context(topic: topic, payload: dynamic.nil(), deliver: fn(_mail) { Nil })
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

fn rendered(effects: List(socket.Effect)) -> String {
  effects
  |> list.map(describe)
  |> string.join(",")
}

fn lowered(actions: List(channel.Action(phase))) -> String {
  channel.effects("room:lobby", actions) |> rendered
}

fn accepted_channel(outcome: socket.WorkerOutcome) -> socket.Worker {
  let assert socket.WorkerAccepted(_reply, _effects, worker) = outcome
    as "expected the join to be accepted"
  worker
}

/// A minimal counting channel: every `"bump"` message adds one and pushes
/// the running total; `"quit"` closes the channel.
fn counter_handler(pattern: String) -> channel.Handler {
  channel.handler(pattern, fn(context) {
    channel.accept(0)
    |> channel.on_message(fn(count, message) {
      case message.event {
        "bump" ->
          channel.next(count + 1, [
            channel.push("total", json.int(count + 1)),
            channel.broadcast("bumped", json.string(context.topic)),
          ])
        "quit" -> channel.close([channel.push("bye", json.int(count))])
        _ -> channel.stay(count)
      }
    })
    |> channel.on_info(fn(count, note) {
      case note {
        Note(text) ->
          channel.next(count, [
            channel.push("note", json.string(context.socket_id <> ":" <> text)),
          ])
        Bye -> channel.close([])
      }
    })
  })
}

// --- join results ----------------------------------------------------------

pub fn join_accepts_without_a_reply_test() -> Nil {
  case
    channel.open(counter_handler("room:*"), quiet_context("room:lobby"), [])
  {
    socket.WorkerAccepted(reply, _actions, _live) -> reply |> should.be_none
    socket.WorkerRejected(_) -> should.fail()
  }
}

pub fn join_accepts_with_a_reply_payload_test() -> Nil {
  let handler =
    channel.handler("room:*", fn(_context) {
      channel.accept(Nil)
      |> channel.with_reply(json.object([#("ok", json.bool(True))]))
    })

  case channel.open(handler, quiet_context("room:lobby"), []) {
    socket.WorkerAccepted(reply, _actions, _live) ->
      reply
      |> should.be_some
      |> json.to_string
      |> should.equal("{\"ok\":true}")
    socket.WorkerRejected(_) -> should.fail()
  }
}

pub fn join_can_be_rejected_test() -> Nil {
  let handler =
    channel.handler("secret:*", fn(_context) {
      channel.reject(json.object([#("reason", json.string("forbidden"))]))
    })

  case channel.open(handler, quiet_context("secret:vault"), []) {
    socket.WorkerAccepted(_, _, _) -> should.fail()
    socket.WorkerRejected(reason) ->
      reason
      |> json.to_string
      |> should.equal("{\"reason\":\"forbidden\"}")
  }
}

pub fn join_receives_the_topic_and_payload_test() -> Nil {
  let handler =
    channel.handler("room:*", fn(context) {
      let decoded =
        decode.run(context.payload, decode.string)
        |> result.unwrap("<undecodable>")
      channel.accept(Nil)
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
      [],
    )

  case outcome {
    socket.WorkerAccepted(reply, _actions, _live) ->
      reply
      |> should.be_some
      |> json.to_string
      |> should.equal(
        "{\"socket\":\"socket-1\",\"topic\":\"room:lobby\",\"payload\":\"hello\"}",
      )
    socket.WorkerRejected(_) -> should.fail()
  }
}

// --- callback dispatch and state threading ---------------------------------

pub fn message_actions_keep_their_order_test() -> Nil {
  let live =
    channel.open(counter_handler("room:*"), quiet_context("room:lobby"), [])
    |> accepted_channel

  case live.on_message("bump", dynamic.nil(), option.None) {
    socket.WorkerContinue(_next, actions) ->
      actions
      |> rendered
      |> should.equal("push/total/1,broadcast/bumped/\"room:lobby\"")
    socket.WorkerClose(..) -> should.fail()
  }
}

pub fn channel_state_is_threaded_across_messages_test() -> Nil {
  let live =
    channel.open(counter_handler("room:*"), quiet_context("room:lobby"), [])
    |> accepted_channel

  let assert socket.WorkerContinue(after_first, _) =
    live.on_message("bump", dynamic.nil(), option.None)
  let assert socket.WorkerContinue(after_second, _) =
    after_first.on_message("bump", dynamic.nil(), option.None)

  case after_second.on_message("bump", dynamic.nil(), option.None) {
    socket.WorkerContinue(_next, actions) ->
      actions
      |> rendered
      |> should.equal("push/total/3,broadcast/bumped/\"room:lobby\"")
    socket.WorkerClose(..) -> should.fail()
  }
}

pub fn unhandled_events_continue_without_actions_test() -> Nil {
  let handler = channel.handler("room:*", fn(_context) { channel.accept(Nil) })

  let live =
    channel.open(handler, quiet_context("room:lobby"), []) |> accepted_channel

  case live.on_message("anything", dynamic.nil(), option.None) {
    socket.WorkerContinue(_next, actions) -> actions |> should.equal([])
    socket.WorkerClose(..) -> should.fail()
  }
}

// --- close -----------------------------------------------------------------

pub fn close_carries_its_final_actions_test() -> Nil {
  let live =
    channel.open(counter_handler("room:*"), quiet_context("room:lobby"), [])
    |> accepted_channel

  case live.on_message("quit", dynamic.nil(), option.None) {
    socket.WorkerClose(actions) ->
      actions |> rendered |> should.equal("push/bye/0")
    socket.WorkerContinue(..) -> should.fail()
  }
}

pub fn terminate_runs_the_terminate_callback_test() -> Nil {
  let observed = process.new_subject()
  let handler =
    channel.handler("room:*", fn(_context) {
      channel.accept(Nil)
      |> channel.on_terminate(fn(_state, reason) {
        process.send(observed, reason)
        []
      })
    })

  let live =
    channel.open(handler, quiet_context("room:lobby"), []) |> accepted_channel
  let _actions = live.on_terminate(socket.Shutdown)

  process.receive(observed, 100) |> should.equal(Ok(socket.Shutdown))
}

// --- typed server-side sends -----------------------------------------------

pub fn sender_seals_typed_info_into_one_mail_per_send_test() -> Nil {
  let outbox = process.new_subject()
  let senders = process.new_subject()

  let handler =
    channel.handler("room:*", fn(context) {
      process.send(senders, context.self)
      channel.accept(Nil)
      |> channel.on_info(fn(_state, note) {
        case note {
          Note(text) ->
            channel.next(Nil, [channel.push("note", json.string(text))])
          Bye -> channel.close([])
        }
      })
    })

  let live =
    channel.open(
      handler,
      context(topic: "room:lobby", payload: dynamic.nil(), deliver: fn(mail) {
        process.send(outbox, mail)
      }),
      [],
    )
    |> accepted_channel

  let assert Ok(sender) = process.receive(senders, 100)
  channel.notify(sender, Note("hi"))
  channel.notify(sender, Note("again"))

  // One send, one mail: no coalescing.
  let assert Ok(first) = process.receive(outbox, 100)
  let assert Ok(second) = process.receive(outbox, 100)
  process.receive(outbox, 0) |> should.equal(Error(Nil))

  let assert socket.WorkerContinue(next, first_actions) = live.on_info(first)
  first_actions |> rendered |> should.equal("push/note/\"hi\"")

  case next.on_info(second) {
    socket.WorkerContinue(_next, actions) ->
      actions |> rendered |> should.equal("push/note/\"again\"")
    socket.WorkerClose(..) -> should.fail()
  }
}

pub fn an_unrun_mail_delivers_nothing_test() -> Nil {
  let outbox = process.new_subject()
  let senders = process.new_subject()

  let handler =
    channel.handler("room:*", fn(context) {
      process.send(senders, context.self)
      channel.accept(0)
      |> channel.on_info(fn(count, note) {
        let assert Note(text) = note as "only Note values are sent here"
        channel.next(count + 1, [
          channel.push("note", json.string(text)),
        ])
      })
    })

  let live =
    channel.open(
      handler,
      context(topic: "room:lobby", payload: dynamic.nil(), deliver: fn(mail) {
        process.send(outbox, mail)
      }),
      [],
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

  case live.on_info(kept) {
    socket.WorkerContinue(_next, actions) ->
      actions |> rendered |> should.equal("push/note/\"kept\"")
    socket.WorkerClose(..) -> should.fail()
  }
}

pub fn a_mail_addressed_to_another_join_delivers_nothing_test() -> Nil {
  let outbox = process.new_subject()
  let senders = process.new_subject()

  let handler =
    channel.handler("room:*", fn(context) {
      process.send(senders, context.self)
      channel.accept(Nil)
      |> channel.on_info(fn(_state, note) {
        case note {
          Note(text) ->
            channel.next(Nil, [channel.push("note", json.string(text))])
          Bye -> channel.close([])
        }
      })
    })

  let join_context =
    context(topic: "room:lobby", payload: dynamic.nil(), deliver: fn(mail) {
      process.send(outbox, mail)
    })
  let first = channel.open(handler, join_context, []) |> accepted_channel
  let second = channel.open(handler, join_context, []) |> accepted_channel

  let assert Ok(sender_of_first) = process.receive(senders, 100)
  let assert Ok(_sender_of_second) = process.receive(senders, 100)
  channel.notify(sender_of_first, Note("mine"))
  let assert Ok(mail) = process.receive(outbox, 100)

  // Handing one join's mail to another join delivers nothing and leaves
  // the mail sealed: the value is only ever readable by its own join.
  case second.on_info(mail) {
    socket.WorkerContinue(_next, actions) -> actions |> should.equal([])
    socket.WorkerClose(..) -> should.fail()
  }

  // ...so it is still intact and still the first join's message when the
  // join that sealed it runs it.
  case first.on_info(mail) {
    socket.WorkerContinue(_next, actions) ->
      actions |> rendered |> should.equal("push/note/\"mine\"")
    socket.WorkerClose(..) -> should.fail()
  }
}

pub fn info_can_close_the_channel_test() -> Nil {
  let outbox = process.new_subject()
  let senders = process.new_subject()
  let handler =
    channel.handler("room:*", fn(context) {
      process.send(senders, context.self)
      channel.accept(Nil)
      |> channel.on_info(fn(_state, note) {
        case note {
          Bye -> channel.close([])
          Note(_) -> channel.stay(Nil)
        }
      })
    })

  let live =
    channel.open(
      handler,
      context(topic: "room:lobby", payload: dynamic.nil(), deliver: fn(mail) {
        process.send(outbox, mail)
      }),
      [],
    )
    |> accepted_channel
  let assert Ok(sender) = process.receive(senders, 100)
  channel.notify(sender, Bye)
  let assert Ok(mail) = process.receive(outbox, 100)

  case live.on_info(mail) {
    socket.WorkerClose(actions) -> actions |> should.equal([])
    socket.WorkerContinue(..) -> should.fail()
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

pub fn shared_actions_are_valid_in_both_phases_test() -> Nil {
  let expected =
    "broadcast/broadcast/1,presence_untrack/user:1,"
    <> "broadcast_presence/state/2"

  shared_active_actions() |> lowered |> should.equal(expected)
  shared_closing_actions() |> lowered |> should.equal(expected)
}

pub fn actions_cover_the_core_effect_capabilities_test() -> Nil {
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
  |> lowered
  |> should.equal(
    "push/push/1,broadcast/broadcast/2,broadcast_from/broadcast_from/3,"
    <> "reply_ok/4,reply_error/5,presence_track/user:1/6,"
    <> "presence_untrack/user:1,push_presence/state/0,"
    <> "broadcast_presence/state/10",
  )
}

pub fn optional_reply_without_a_ref_lowers_to_no_effect_test() -> Nil {
  channel.effects("room:lobby", [
    channel.reply_ok(option.None, json.int(1)),
    channel.reply_error(option.None, json.int(2)),
  ])
  |> should.equal([])
}

pub fn optional_reply_with_a_ref_lowers_in_order_test() -> Nil {
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
  |> lowered
  |> should.equal("reply_ok/1,reply_error/2")
}

pub fn repeated_join_action_lists_append_left_to_right_test() -> Nil {
  let handler =
    channel.handler("room:*", fn(_context) {
      channel.accept(Nil)
      |> channel.with_actions([channel.push("first", json.int(1))])
      |> channel.with_actions([channel.push("second", json.int(2))])
    })

  case channel.open(handler, quiet_context("room:lobby"), []) {
    socket.WorkerAccepted(_reply, actions, _live) ->
      actions |> rendered |> should.equal("push/first/1,push/second/2")
    socket.WorkerRejected(_) -> should.fail()
  }
}

pub fn presence_encoders_run_against_supplied_entries_test() -> Nil {
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

pub fn an_empty_action_list_is_empty_test() -> Nil {
  channel.effects("room:lobby", []) |> should.equal([])
}
