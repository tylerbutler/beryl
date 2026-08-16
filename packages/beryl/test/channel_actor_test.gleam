//// Regression coverage for the server-side send seam *inside a real
//// `gleam/otp/actor`*, which is the only context that matters: beryl's
//// runtime is such an actor, and its message loop installs a catch-all
//// `select_other` handler that swallows and logs any message arriving in
//// the process mailbox that its own selector does not match.
////
//// The router below is a faithful miniature of the real adapter in
//// `beryl/channel/internal/router`: its actor message type is the
//// socket-level envelope, it owns the live channel and its generation,
//// and every server-side send has to make the round trip out through
//// `channel.notify` and back in as an envelope before `on_info` can run.
//// It pins the seam in isolation; `dispatch_test` pins the same
//// behaviour through a real running system.

import beryl/channel
import beryl/socket
import gleam/dynamic
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/otp/actor
import gleeunit/should

/// The channel's own server-side message type. It is never named by the
/// envelope, the router state, or the seam.
pub type Note {
  Note(text: String)
  Bye
}

/// The socket-level envelope: exactly one enqueued channel mail, tagged
/// with the topic and join generation the sender was bound to.
pub type Envelope {
  ChannelMail(topic: String, generation: Int, mail: channel.Mail)
  /// End the current generation and join the same topic again.
  Rejoin(reply: process.Subject(channel.Sender(Note)))
  /// Report every action applied so far, oldest first.
  Applied(reply: process.Subject(List(String)))
}

type Router {
  Router(
    build: fn(process.Subject(channel.Sender(Note))) -> channel.Handler,
    topic: String,
    generation: Int,
    live: channel.LiveChannel,
    applied: List(String),
    self: process.Subject(Envelope),
  )
}

// --- the channel under test ------------------------------------------------

fn note_handler(
  replies: process.Subject(channel.Sender(Note)),
) -> channel.Handler {
  channel.handler("room:*", fn(context) {
    let callbacks =
      channel.callbacks()
      |> channel.on_info(fn(count, note) {
        case note {
          Note(text) ->
            channel.next(count + 1, [
              channel.push(
                "note",
                json.string(text <> "#" <> int.to_string(count + 1)),
              ),
            ])
          Bye -> channel.close([channel.push("bye", json.int(count))])
        }
      })
    process.send(replies, context.self)
    channel.accept(0, callbacks)
  })
}

/// A channel that sends itself a message from inside `join`, which is the
/// documented way to schedule work for just after the join acknowledgment.
fn greeting_handler(
  replies: process.Subject(channel.Sender(Note)),
) -> channel.Handler {
  channel.handler("room:*", fn(context) {
    let callbacks =
      channel.callbacks()
      |> channel.on_info(fn(count, note) {
        case note {
          Note(text) ->
            channel.next(count + 1, [
              channel.push("greeting", json.string(text)),
            ])
          Bye -> channel.close([])
        }
      })
    process.send(replies, context.self)
    channel.notify(context.self, Note("welcome to " <> context.topic))
    channel.accept(0, callbacks)
  })
}

// --- the miniature router actor --------------------------------------------

fn open_generation(
  build: fn(process.Subject(channel.Sender(Note))) -> channel.Handler,
  topic: String,
  generation: Int,
  self: process.Subject(Envelope),
  replies: process.Subject(channel.Sender(Note)),
) -> channel.LiveChannel {
  let context =
    channel.RoutedJoinContext(
      socket_id: "socket-1",
      seed: socket.empty_seed(),
      topic: topic,
      params: ["lobby"],
      payload: dynamic.nil(),
      deliver: fn(mail) {
        process.send(self, ChannelMail(topic, generation, mail))
      },
    )

  let assert channel.Accepted(_reply, _actions, live) =
    channel.open(build(replies), context)
    as "the test handler always accepts"
  live
}

fn start_router(
  topic: String,
) -> #(process.Subject(Envelope), process.Subject(channel.Sender(Note))) {
  start_router_for(topic, note_handler)
}

fn start_router_for(
  topic: String,
  build: fn(process.Subject(channel.Sender(Note))) -> channel.Handler,
) -> #(process.Subject(Envelope), process.Subject(channel.Sender(Note))) {
  let replies = process.new_subject()

  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(self) {
      // The generation is bound into `deliver` before the join runs, so a
      // `notify` from inside the join callback is addressed to the join
      // that is still being opened.
      let live = open_generation(build, topic, 1, self, replies)
      actor.initialised(Router(
        build: build,
        topic: topic,
        generation: 1,
        live: live,
        applied: [],
        self: self,
      ))
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle_envelope)
    |> actor.start
    as "the router actor starts"

  #(started.data, replies)
}

fn handle_envelope(
  state: Router,
  envelope: Envelope,
) -> actor.Next(Router, Envelope) {
  case envelope {
    Applied(reply) -> {
      process.send(reply, state.applied)
      actor.continue(state)
    }

    Rejoin(reply) -> {
      let _terminate_actions = state.live.on_terminate(socket.Shutdown)
      let generation = state.generation + 1
      let live =
        open_generation(state.build, state.topic, generation, state.self, reply)
      actor.continue(Router(..state, generation: generation, live: live))
    }

    // Liveness is decided *before* the thunk runs, so a stale envelope
    // never delivers its payload anywhere.
    ChannelMail(topic, generation, _mail)
      if topic != state.topic || generation != state.generation
    -> actor.continue(state)

    ChannelMail(_topic, _generation, mail) ->
      case state.live.on_mail(mail) {
        channel.StepContinue(next, actions) ->
          actor.continue(
            Router(..state, live: next, applied: record(state, actions)),
          )
        channel.StepClose(actions) ->
          actor.continue(Router(..state, applied: record(state, actions)))
        channel.StepStop(_reason) -> actor.stop()
      }
  }
}

fn record(
  state: Router,
  actions: List(channel.Action(channel.Active)),
) -> List(String) {
  list.append(
    state.applied,
    channel.effects(state.topic, actions) |> list.map(describe),
  )
}

fn describe(effect: socket.Effect) -> String {
  case effect {
    socket.Push(event: event, payload: payload, ..) ->
      event <> "/" <> json.to_string(payload)
    _ -> "other"
  }
}

fn applied(router: process.Subject(Envelope)) -> List(String) {
  process.call(router, waiting: 1000, sending: Applied)
}

// --- tests -----------------------------------------------------------------

pub fn typed_info_reaches_on_info_inside_a_real_actor_test() {
  let #(router, replies) = start_router("room:lobby")
  let assert Ok(sender) = process.receive(replies, 1000)

  channel.notify(sender, Note("hello"))

  applied(router) |> should.equal(["note/\"hello#1\""])
}

pub fn every_send_delivers_exactly_one_payload_in_order_test() {
  let #(router, replies) = start_router("room:lobby")
  let assert Ok(sender) = process.receive(replies, 1000)

  channel.notify(sender, Note("a"))
  channel.notify(sender, Note("b"))
  channel.notify(sender, Note("c"))

  applied(router)
  |> should.equal(["note/\"a#1\"", "note/\"b#2\"", "note/\"c#3\""])
}

pub fn sends_from_another_process_are_delivered_test() {
  let #(router, replies) = start_router("room:lobby")
  let assert Ok(sender) = process.receive(replies, 1000)
  let done = process.new_subject()

  process.spawn_unlinked(fn() {
    channel.notify(sender, Note("remote"))
    process.send(done, Nil)
  })

  let assert Ok(Nil) = process.receive(done, 1000)
  applied(router) |> should.equal(["note/\"remote#1\""])
}

pub fn info_results_can_close_the_channel_test() {
  let #(router, replies) = start_router("room:lobby")
  let assert Ok(sender) = process.receive(replies, 1000)

  channel.notify(sender, Note("first"))
  channel.notify(sender, Bye)

  applied(router) |> should.equal(["note/\"first#1\"", "bye/1"])
}

pub fn a_stale_senders_payload_is_never_delivered_test() {
  let #(router, replies) = start_router("room:lobby")
  let assert Ok(stale) = process.receive(replies, 1000)

  let fresh = process.call(router, waiting: 1000, sending: Rejoin)

  // The stale sender belongs to the closed generation: its envelope is
  // dropped before the thunk runs, so the payload reaches neither the old
  // channel nor the new one.
  channel.notify(stale, Note("stale"))
  applied(router) |> should.equal([])

  // ...and the new generation is unpolluted: its own state starts at zero
  // and it sees only its own message.
  channel.notify(fresh, Note("fresh"))
  applied(router) |> should.equal(["note/\"fresh#1\""])
}

pub fn a_send_from_inside_join_is_delivered_after_the_join_test() {
  let #(router, _replies) = start_router_for("room:lobby", greeting_handler)

  applied(router) |> should.equal(["greeting/\"welcome to room:lobby\""])
}
