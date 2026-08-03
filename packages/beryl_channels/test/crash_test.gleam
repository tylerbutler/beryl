//// The crash boundaries a channel system inherits from beryl's core.
////
//// App code that panics must never take the runtime down. The core's
//// policy is attributed by *where* the panic happened, and this layer
//// must not blunt it:
////
//// | Panic in | Effect |
//// |---|---|
//// | `join` | that join is rejected; the socket survives |
//// | `on_message` / `on_binary` | that topic closes; other topics survive |
//// | `on_info` | the whole socket is torn down |
//// | `on_terminate` | teardown still completes; sibling channels still run their termination actions |
////
//// A panic in `on_terminate` is the one place where the layer's
//// "a closed channel is gone" rule has an exception: core preserves the
//// pre-`Closed` model, so the router keeps that instance in its layer map
//// and a sender for it can still be delivered. That is pinned below so it
//// cannot drift silently.
////
//// Every assertion runs against a real system through beryl's public
//// transport SPI.

import beryl
import beryl/wire
import beryl_channels/channel
import dispatch_helpers as helper
import gleam/erlang/process
import gleam/json
import gleam/string
import gleeunit/should

/// The crashing channels' server-side message type.
pub type Poke {
  Poke
}

// --- test channels ---------------------------------------------------------

/// A channel that works: it answers `"ping"` and traces its termination.
fn ok_handler(trace: process.Subject(String)) -> channel.Handler {
  channel.handler("room:*", fn(_info, topic, _payload) {
    let callbacks =
      channel.callbacks()
      |> channel.on_message(fn(state, _message) {
        channel.continue_with(
          state,
          channel.actions() |> channel.push("pong", json.int(1)),
        )
      })
      |> channel.on_binary(fn(state, _data) {
        channel.continue_with(
          state,
          channel.actions() |> channel.push("pong", json.int(2)),
        )
      })
      |> channel.on_terminate(fn(_state, reason) {
        process.send(
          trace,
          "terminate:" <> topic <> ":" <> helper.reason_name(reason),
        )
        // Termination actions of a channel that does *not* panic must
        // survive a sibling channel's panic in the same teardown.
        channel.actions()
        |> channel.broadcast("farewell", json.string(topic))
      })
    channel.accept_with(
      channel.joined(Nil, callbacks),
      json.object([#("handler", json.string("room"))]),
    )
  })
}

/// A channel whose `join` callback panics before it can accept or reject.
fn join_panics() -> channel.Handler {
  channel.handler("crash_join:*", fn(_info, _topic, _payload) {
    panic as "join exploded"
  })
}

/// A channel whose `on_message` and `on_binary` callbacks panic.
fn callback_panics(trace: process.Subject(String)) -> channel.Handler {
  channel.handler("crash_msg:*", fn(_info, topic, _payload) {
    let callbacks =
      channel.callbacks()
      |> channel.on_message(fn(_state, _message) { panic as "message exploded" })
      |> channel.on_binary(fn(_state, _data) { panic as "binary exploded" })
      |> channel.on_terminate(fn(_state, reason) {
        process.send(
          trace,
          "terminate:" <> topic <> ":" <> helper.reason_name(reason),
        )
        channel.actions()
      })
    channel.accept(channel.joined(Nil, callbacks))
  })
}

/// A channel whose `on_info` callback panics.
fn info_panics(
  trace: process.Subject(String),
  senders: process.Subject(channel.Sender(Poke)),
) -> channel.Handler {
  channel.handler("crash_info:*", fn(info, topic, _payload) {
    process.send(senders, info.self)
    let callbacks =
      channel.callbacks()
      |> channel.on_info(fn(_state, _note) { panic as "info exploded" })
      |> channel.on_terminate(fn(_state, reason) {
        process.send(
          trace,
          "terminate:" <> topic <> ":" <> helper.reason_name(reason),
        )
        channel.actions()
      })
    channel.accept(channel.joined(Nil, callbacks))
  })
}

/// A channel that closes itself and then panics while terminating.
fn terminate_panics(trace: process.Subject(String)) -> channel.Handler {
  channel.handler("crash_term:*", fn(_info, topic, _payload) {
    let callbacks =
      channel.callbacks()
      |> channel.on_message(fn(_state, _message) {
        channel.close_with(
          channel.actions() |> channel.push("bye", json.int(0)),
        )
      })
      |> channel.on_terminate(fn(_state, _reason) {
        process.send(trace, "terminating:" <> topic)
        panic as "terminate exploded"
      })
    channel.accept(channel.joined(Nil, callbacks))
  })
}

/// A channel that closes itself and then panics while terminating, and
/// that reports its typed sender and every `on_info` it receives.
///
/// The `on_info` handler broadcasts rather than pushes: after the topic
/// has closed the socket is no longer subscribed, so a push would be
/// dropped by core and prove nothing.
fn terminate_panics_with_sender(
  trace: process.Subject(String),
  senders: process.Subject(channel.Sender(Poke)),
) -> channel.Handler {
  channel.handler("crash_term:*", fn(info, topic, _payload) {
    process.send(senders, info.self)
    let callbacks =
      channel.callbacks()
      |> channel.on_message(fn(_state, _message) { channel.close() })
      |> channel.on_info(fn(state, _note) {
        process.send(trace, "info:" <> topic)
        channel.continue_with(
          state,
          channel.actions() |> channel.broadcast("late", json.string(topic)),
        )
      })
      |> channel.on_terminate(fn(_state, _reason) {
        process.send(trace, "terminating:" <> topic)
        panic as "terminate exploded"
      })
    channel.accept(channel.joined(Nil, callbacks))
  })
}

// --- systems ---------------------------------------------------------------

fn start(handlers: List(channel.Handler)) -> beryl.Sockets {
  helper.start(beryl.config(wire.phoenix_codec()), handlers: handlers)
}

fn start_text_only(handlers: List(channel.Handler)) -> beryl.Sockets {
  helper.start(beryl.config(helper.text_only_codec()), handlers: handlers)
}

// --- join --------------------------------------------------------------

pub fn a_panic_in_join_rejects_that_join_test() {
  let trace = process.new_subject()
  let channels = start([join_panics(), ok_handler(trace)])
  let frames = helper.connect(channels, "s1")

  // A live channel on the same socket, so the trace has a writer that a
  // wrongly-registered or wrongly-torn-down channel would show up in.
  helper.join(channels, "s1", "room:b", "jr-1", "r-1")
  let _join_b = helper.recv(frames)

  helper.join(channels, "s1", "crash_join:a", "jr-2", "r-2")

  let reply = helper.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply
  |> string.contains("{\"reason\":\"join crashed\"}")
  |> should.be_true

  // The crashed join never became an instance: nothing is joined on its
  // topic, so a message there is answered as an unjoined topic...
  helper.push(channels, "s1", "crash_join:a", "ping", "r-3")
  helper.recv(frames)
  |> string.contains("{\"reason\":\"unmatched topic\"}")
  |> should.be_true

  // ...and neither channel terminated because of the crash.
  helper.no_trace(trace)
}

pub fn a_panic_in_join_leaves_the_socket_usable_test() {
  let trace = process.new_subject()
  let channels = start([join_panics(), ok_handler(trace)])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "crash_join:a", "jr-1", "r-1")
  let _rejection = helper.recv(frames)

  // Same socket, a different topic: the crash rejected one join, it did
  // not tear the connection down.
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  helper.recv(frames)
  |> string.contains("\"handler\":\"room\"")
  |> should.be_true

  helper.push(channels, "s1", "room:b", "ping", "r-3")
  helper.recv(frames) |> string.contains("\"pong\"") |> should.be_true
}

// --- message and binary --------------------------------------------------

pub fn a_panic_handling_a_message_closes_only_that_topic_test() {
  let trace = process.new_subject()
  let channels = start([callback_panics(trace), ok_handler(trace)])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "crash_msg:a", "jr-1", "r-1")
  let _join_a = helper.recv(frames)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _join_b = helper.recv(frames)

  helper.push(channels, "s1", "crash_msg:a", "boom", "r-3")

  // The crashing topic is closed with the crash as its reason, and its
  // termination callback still runs exactly once.
  let line = helper.next_trace(trace)
  line
  |> string.starts_with("terminate:crash_msg:a:errored:")
  |> should.be_true
  helper.no_trace(trace)

  // An errored close is announced as `phx_error`, not `phx_close`.
  let close = helper.recv(frames)
  close |> string.contains("phx_error") |> should.be_true
  close |> string.contains("crash_msg:a") |> should.be_true

  // The other topic on the same socket is untouched.
  helper.push(channels, "s1", "room:b", "ping", "r-4")
  helper.recv(frames) |> string.contains("\"pong\"") |> should.be_true

  // ...and the closed topic is gone, so a later message reaches no
  // channel: the core answers it with Phoenix's unmatched-topic error and
  // the crashed channel is never re-entered.
  helper.push(channels, "s1", "crash_msg:a", "boom", "r-5")
  helper.recv(frames)
  |> string.contains("{\"reason\":\"unmatched topic\"}")
  |> should.be_true
  helper.no_trace(trace)
}

pub fn a_panic_handling_a_binary_frame_closes_only_that_topic_test() {
  let trace = process.new_subject()
  let channels = start_text_only([callback_panics(trace), ok_handler(trace)])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "crash_msg:a", "jr-1", "r-1")
  let _join_a = helper.recv(frames)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _join_b = helper.recv(frames)

  // A binary frame fans out to every joined topic in sorted order, so the
  // panicking topic is delivered to first.
  helper.route_binary(channels, "s1", <<1, 2, 3>>)

  let line = helper.next_trace(trace)
  line
  |> string.starts_with("terminate:crash_msg:a:errored:")
  |> should.be_true
  helper.no_trace(trace)

  let close = helper.recv(frames)
  close |> string.contains("phx_error") |> should.be_true
  close |> string.contains("crash_msg:a") |> should.be_true

  // The surviving topic received the very same frame and handled it.
  helper.recv(frames) |> string.contains("\"pong\",2") |> should.be_true

  // ...and still works afterwards.
  helper.push(channels, "s1", "room:b", "ping", "r-3")
  helper.recv(frames) |> string.contains("\"pong\",1") |> should.be_true
}

// --- info ------------------------------------------------------------------

pub fn a_panic_handling_info_closes_the_whole_socket_test() {
  let trace = process.new_subject()
  let senders = process.new_subject()
  let channels = start([info_panics(trace, senders), ok_handler(trace)])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "crash_info:a", "jr-1", "r-1")
  let _join_a = helper.recv(frames)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _join_b = helper.recv(frames)
  let assert Ok(sender) = process.receive(senders, 500)
    as "the join reported its sender"

  channel.notify(sender, Poke)

  // An `Info` has no topic to attribute the crash to, so the socket goes
  // away — and *every* channel on it terminates, exactly once each.
  let first = helper.next_trace(trace)
  first
  |> string.starts_with("terminate:crash_info:a:errored:")
  |> should.be_true
  let second = helper.next_trace(trace)
  second |> string.starts_with("terminate:room:b:errored:") |> should.be_true
  helper.no_trace(trace)

  // The socket is gone: later frames reach nothing at all.
  let _close_a = helper.recv(frames)
  let _close_b = helper.recv(frames)
  helper.push(channels, "s1", "room:b", "ping", "r-3")
  helper.recv_none(frames)
}

// --- terminate -------------------------------------------------------------

pub fn a_panic_while_terminating_does_not_prevent_teardown_test() {
  let trace = process.new_subject()
  let channels = start([terminate_panics(trace), ok_handler(trace)])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "crash_term:a", "jr-1", "r-1")
  let _join_a = helper.recv(frames)

  helper.push(channels, "s1", "crash_term:a", "leave", "r-2")

  helper.recv(frames) |> string.contains("\"bye\"") |> should.be_true
  helper.next_trace(trace) |> should.equal("terminating:crash_term:a")

  // The terminal frame is still sent even though the callback panicked.
  helper.recv(frames) |> string.contains("phx_close") |> should.be_true

  // The socket survived, so the topic can be joined again.
  helper.join(channels, "s1", "crash_term:a", "jr-2", "r-3")
  helper.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
}

pub fn a_terminate_panic_does_not_swallow_a_siblings_farewell_test() {
  let trace = process.new_subject()
  let channels = start([terminate_panics(trace), ok_handler(trace)])
  let leaving = helper.connect(channels, "s1")
  let peer = helper.connect(channels, "s2")
  helper.join(channels, "s1", "crash_term:a", "jr-1", "r-1")
  let _join_a = helper.recv(leaving)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _join_b = helper.recv(leaving)
  helper.join(channels, "s2", "room:b", "jr-1", "r-1")
  let _peer_join = helper.recv(peer)

  helper.disconnect(channels, "s1")

  helper.next_trace(trace) |> should.equal("terminating:crash_term:a")
  helper.next_trace(trace) |> should.equal("terminate:room:b:normal")

  // Each `Closed` is its own update turn, so the panic in the first one
  // cannot discard the second channel's termination actions.
  helper.recv(peer) |> string.contains("farewell") |> should.be_true
}

pub fn a_panic_while_terminating_does_not_stop_other_channels_closing_test() {
  let trace = process.new_subject()
  let channels = start([terminate_panics(trace), ok_handler(trace)])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "crash_term:a", "jr-1", "r-1")
  let _join_a = helper.recv(frames)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _join_b = helper.recv(frames)

  helper.disconnect(channels, "s1")

  // Topics close in sorted order; the first one panics while terminating
  // and the second still terminates.
  helper.next_trace(trace) |> should.equal("terminating:crash_term:a")
  helper.next_trace(trace) |> should.equal("terminate:room:b:normal")
  helper.no_trace(trace)
}

// --- the terminate-panic exception -----------------------------------------
//
// A panic in `on_terminate` is the one case where a channel instance
// outlives its own termination. Core's `Closed` crash policy is to log
// and keep the *last good model*, which is the model from before the
// `Closed` turn — the one that still lists this instance at this
// generation. Nothing in the layer can remove it from that model: the
// removal is exactly what the panic discarded.
//
// These two tests pin what that actually means, so the documented
// guarantee cannot drift: the retained instance is reachable by its own
// sender, and the ordinary invalidation points still close the window.

pub fn a_terminate_panic_leaves_the_instance_reachable_by_its_sender_test() {
  let trace = process.new_subject()
  let senders = process.new_subject()
  let channels = start([terminate_panics_with_sender(trace, senders)])
  let leaver = helper.connect(channels, "s1")
  let peer = helper.connect(channels, "s2")
  helper.join(channels, "s1", "crash_term:a", "jr-1", "r-1")
  let _join_a = helper.recv(leaver)
  helper.join(channels, "s2", "crash_term:a", "jr-1", "r-1")
  let _join_peer = helper.recv(peer)
  let assert Ok(sender) = process.receive(senders, 500)
    as "the join reported its sender"

  helper.push(channels, "s1", "crash_term:a", "leave", "r-2")

  helper.next_trace(trace) |> should.equal("terminating:crash_term:a")
  // The topic really did close: core sent the terminal frame and dropped
  // the subscription.
  helper.recv(leaver) |> string.contains("phx_close") |> should.be_true

  // ...but the panic discarded the router model that removed the
  // instance, so this sender still resolves to the terminated join.
  channel.notify(sender, Poke)
  helper.next_trace(trace) |> should.equal("info:crash_term:a")
  helper.recv(peer) |> string.contains("\"late\"") |> should.be_true

  // The socket itself is unaffected and still unsubscribed, so its own
  // broadcast does not come back to it.
  helper.recv_none(leaver)
}

pub fn a_rejoin_after_a_terminate_panic_invalidates_the_retained_sender_test() {
  let trace = process.new_subject()
  let senders = process.new_subject()
  let channels = start([terminate_panics_with_sender(trace, senders)])
  let leaver = helper.connect(channels, "s1")
  let peer = helper.connect(channels, "s2")
  helper.join(channels, "s1", "crash_term:a", "jr-1", "r-1")
  let _join_a = helper.recv(leaver)
  helper.join(channels, "s2", "crash_term:a", "jr-1", "r-1")
  let _join_peer = helper.recv(peer)
  let assert Ok(stale) = process.receive(senders, 500)
    as "the first join reported its sender"

  helper.push(channels, "s1", "crash_term:a", "leave", "r-2")
  helper.next_trace(trace) |> should.equal("terminating:crash_term:a")
  helper.recv(leaver) |> string.contains("phx_close") |> should.be_true

  // Rejoining the topic overwrites the retained entry with a new
  // generation, which is the ordinary invalidation rule again.
  helper.join(channels, "s1", "crash_term:a", "jr-2", "r-3")
  helper.recv(leaver) |> string.contains("\"status\":\"ok\"") |> should.be_true
  let assert Ok(_fresh) = process.receive(senders, 500)
    as "the rejoin reported its own sender"

  channel.notify(stale, Poke)
  helper.no_trace(trace)
  helper.recv_none(peer)
}
