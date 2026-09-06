//// The crash boundaries a channel system inherits from beryl's core.
////
//// App code that panics must never take the runtime down. Each accepted
//// topic runs in its own worker process, and the core's policy is
//// attributed by *where* the panic happened:
////
//// | Panic in | Effect |
//// |---|---|
//// | `join` | that join is rejected; the socket survives |
//// | `on_message` | that topic closes; other topics survive |
//// | `on_info` | that topic closes; other topics survive |
//// | `on_terminate` | teardown still completes; sibling channels still run their termination actions |
////
//// A panic in `on_terminate` ends the channel like any other close: its
//// worker stops, so a sender for that join delivers nothing afterwards.
//// That is pinned below so it cannot drift silently.
////
//// Every assertion runs against a real system through beryl's public
//// transport SPI.

import beryl
import beryl/channel
import beryl/wire
import channel_dispatch_helper as helper
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
  channel.handler("room:*", fn(context) {
    channel.accept(Nil)
    |> channel.on_message(fn(state, _message) {
      channel.next(state, [channel.push("pong", json.int(1))])
    })
    |> channel.on_terminate(fn(_state, reason) {
      process.send(
        trace,
        "terminate:" <> context.topic <> ":" <> helper.reason_name(reason),
      )
      // Termination actions of a channel that does *not* panic must
      // survive a sibling channel's panic in the same teardown.
      [channel.broadcast("farewell", json.string(context.topic))]
    })
    |> channel.with_reply(json.object([#("handler", json.string("room"))]))
  })
}

/// A channel whose `join` callback panics before it can accept or reject.
fn join_panics() -> channel.Handler {
  channel.handler("crash_join:*", fn(_context) { panic as "join exploded" })
}

/// A channel whose `on_message` callback panics.
fn callback_panics(trace: process.Subject(String)) -> channel.Handler {
  channel.handler("crash_msg:*", fn(context) {
    channel.accept(Nil)
    |> channel.on_message(fn(_state, _message) { panic as "message exploded" })
    |> channel.on_terminate(fn(_state, reason) {
      process.send(
        trace,
        "terminate:" <> context.topic <> ":" <> helper.reason_name(reason),
      )
      []
    })
  })
}

/// A channel whose `on_info` callback panics.
fn info_panics(
  trace: process.Subject(String),
  senders: process.Subject(channel.Sender(Poke)),
) -> channel.Handler {
  channel.handler("crash_info:*", fn(context) {
    process.send(senders, context.self)
    channel.accept(Nil)
    |> channel.on_info(fn(_state, _note) { panic as "info exploded" })
    |> channel.on_terminate(fn(_state, reason) {
      process.send(
        trace,
        "terminate:" <> context.topic <> ":" <> helper.reason_name(reason),
      )
      []
    })
  })
}

/// A channel that closes itself and then panics while terminating.
fn terminate_panics(trace: process.Subject(String)) -> channel.Handler {
  channel.handler("crash_term:*", fn(context) {
    channel.accept(Nil)
    |> channel.on_message(fn(_state, _message) {
      channel.close([channel.push("bye", json.int(0))])
    })
    |> channel.on_terminate(fn(_state, _reason) {
      process.send(trace, "terminating:" <> context.topic)
      panic as "terminate exploded"
    })
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
  channel.handler("crash_term:*", fn(context) {
    process.send(senders, context.self)
    channel.accept(Nil)
    |> channel.on_message(fn(_state, _message) { channel.close([]) })
    |> channel.on_info(fn(state, _note) {
      process.send(trace, "info:" <> context.topic)
      channel.next(state, [
        channel.broadcast("late", json.string(context.topic)),
      ])
    })
    |> channel.on_terminate(fn(_state, _reason) {
      process.send(trace, "terminating:" <> context.topic)
      panic as "terminate exploded"
    })
  })
}

// --- systems ---------------------------------------------------------------

fn start(handlers: List(channel.Handler)) -> beryl.Sockets {
  helper.start(beryl.config(wire.phoenix_codec()), handlers: handlers)
}

// --- join --------------------------------------------------------------

pub fn a_panic_in_join_rejects_that_join_test() -> Nil {
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

pub fn a_panic_in_join_leaves_the_socket_usable_test() -> Nil {
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

// --- message ---------------------------------------------------------------

pub fn a_panic_handling_a_message_closes_only_that_topic_test() -> Nil {
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

// --- info ------------------------------------------------------------------

pub fn a_panic_handling_info_closes_only_that_topic_test() -> Nil {
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

  // The mail reached the topic's own worker, so the crash is attributed
  // to that topic alone: it closes with the crash as its reason and its
  // termination callback still runs, exactly once.
  let line = helper.next_trace(trace)
  line
  |> string.starts_with("terminate:crash_info:a:errored:")
  |> should.be_true
  helper.no_trace(trace)

  let close = helper.recv(frames)
  close |> string.contains("phx_error") |> should.be_true
  close |> string.contains("crash_info:a") |> should.be_true

  // The other topic on the same socket is untouched.
  helper.push(channels, "s1", "room:b", "ping", "r-3")
  helper.recv(frames) |> string.contains("\"pong\"") |> should.be_true
}

// --- terminate -------------------------------------------------------------

pub fn a_panic_while_terminating_does_not_prevent_teardown_test() -> Nil {
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

pub fn a_terminate_panic_does_not_swallow_a_siblings_farewell_test() -> Nil {
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

pub fn a_panic_while_terminating_does_not_stop_other_channels_closing_test() -> Nil {
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

// --- a terminate panic ends the channel ------------------------------------
//
// The channel's state lives in its worker, and the worker stops after
// `on_terminate` whether or not the callback panicked. Its sender then
// addresses a process that no longer exists, so a terminated join can
// never be re-entered, and a rejoin gets a fresh worker and sender.

pub fn a_terminate_panic_ends_the_channel_for_its_sender_test() -> Nil {
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
    as "the join reported its sender"

  helper.push(channels, "s1", "crash_term:a", "leave", "r-2")

  helper.next_trace(trace) |> should.equal("terminating:crash_term:a")
  // The topic really did close: core sent the terminal frame and dropped
  // the subscription.
  helper.recv(leaver) |> string.contains("phx_close") |> should.be_true

  // The terminated join's sender reaches nothing.
  channel.notify(stale, Poke)
  helper.no_trace(trace)
  helper.recv_none(peer)

  // Rejoining gives the topic a fresh worker and a fresh sender, and the
  // stale one still reaches nothing.
  helper.join(channels, "s1", "crash_term:a", "jr-2", "r-3")
  helper.recv(leaver) |> string.contains("\"status\":\"ok\"") |> should.be_true
  let assert Ok(fresh) = process.receive(senders, 500)
    as "the rejoin reported its own sender"
  channel.notify(stale, Poke)
  helper.no_trace(trace)
  channel.notify(fresh, Poke)
  helper.next_trace(trace) |> should.equal("info:crash_term:a")
  helper.recv(peer) |> string.contains("\"late\"") |> should.be_true
}
