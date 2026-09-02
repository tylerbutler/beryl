//// Accept-time and termination-time actions: the two points where a
//// channel's effects have to share an update turn with a lifecycle
//// transition.
////
//// | Property | Why it matters |
//// |---|---|
//// | `AcceptJoin` is lowered before the join's actions | a push to a topic the socket has not joined yet is dropped by core |
//// | join actions retain declared order | async presence may yield, but later actions resume only after it completes |
//// | termination actions apply in order, once | leave announcements and post-leave rosters are ordinary features |
//// | termination actions are phase-safe | active-only pushes, replies, and presence tracking cannot be returned |
////
//// Everything runs against a real system through beryl's public transport
//// SPI, so these are assertions about frames on the wire.

import beryl
import beryl/channel
import beryl/presence
import beryl/wire
import channel_dispatch_helper as helper
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should

fn encode_users(entries: List(presence.PresenceEntry)) -> json.Json {
  json.object(list.map(entries, fn(entry) { #(entry.key, entry.meta) }))
}

fn start(handlers: List(channel.Handler)) -> beryl.Sockets {
  helper.start(beryl.config(wire.phoenix_codec()), handlers: handlers)
}

fn start_with_presence(
  handlers: List(channel.Handler),
  handle: presence.Presence,
) -> beryl.Sockets {
  helper.start(
    beryl.config(wire.phoenix_codec()) |> beryl.with_presence_handle(handle),
    handlers: handlers,
  )
}

fn start_presence(replica: String) -> presence.Presence {
  let assert Ok(handle) = presence.start(presence.default_config(replica))
    as "presence starts"
  handle
}

// --- accept-time actions ---------------------------------------------------

/// A channel that pushes to its own topic as part of accepting the join.
/// The push is only deliverable if the accept was lowered first.
fn welcoming_handler() -> channel.Handler {
  channel.handler("room:*", fn(context) {
    channel.accept(Nil)
    |> channel.with_reply(
      json.object([#("joined", json.string(context.topic))]),
    )
    |> channel.with_actions([
      channel.push("welcome", json.string(context.topic)),
      channel.broadcast("announce", json.string(context.topic)),
    ])
  })
}

pub fn the_join_acknowledgment_precedes_the_joins_own_actions_test() -> Nil {
  let channels = start([welcoming_handler()])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")

  // The acknowledgment is first...
  let acknowledgement = helper.recv(frames)
  acknowledgement |> string.contains("phx_reply") |> should.be_true
  acknowledgement |> string.contains("\"status\":\"ok\"") |> should.be_true
  acknowledgement |> string.contains("\"joined\":\"room:a\"") |> should.be_true

  // ...and the join's own actions follow it, in order. A push lowered
  // before the accept would have been dropped: the socket is not
  // subscribed to the topic until the accept applies.
  helper.recv(frames) |> string.contains("\"welcome\"") |> should.be_true
  helper.recv(frames) |> string.contains("\"announce\"") |> should.be_true
  helper.recv_none(frames)
}

/// A room that holds one member, checked against presence in `join` and
/// tracked with an accept-time action. The check and the track have to
/// land in the same turn or the capacity is not a capacity.
fn capacity_handler(handle: presence.Presence) -> channel.Handler {
  channel.handler("room:*", fn(context) {
    let assert Ok(entries) = presence.list(handle, context.topic)
    case list.length(entries) >= 1 {
      True -> channel.reject(json.object([#("reason", json.string("full"))]))
      False ->
        channel.accept(Nil)
        |> channel.with_actions([
          channel.presence_track(
            context.socket_id,
            json.object([#("at", json.string(context.topic))]),
          ),
          channel.push_presence("presence_list", encode_users),
        ])
    }
  })
}

pub fn a_join_time_presence_track_applies_in_the_join_turn_test() -> Nil {
  let handle = start_presence("join-turn")
  let channels = start_with_presence([capacity_handler(handle)], handle)
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _ack = helper.recv(frames)
  let _diff = helper.recv(frames)

  // The snapshot pushed by the same action list already contains the
  // joiner, so the track was applied inside the join turn — not by a
  // later self-notification.
  let snapshot = helper.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  snapshot |> string.contains("s1") |> should.be_true

  let assert Ok([entry]) = presence.list(handle, "room:a")
    as "the presence actor holds the joiner"
  entry.key |> should.equal("s1")
}

pub fn a_capacity_check_observes_a_completed_join_time_track_test() -> Nil {
  let handle = start_presence("capacity")
  let channels = start_with_presence([capacity_handler(handle)], handle)
  let first = helper.connect(channels, "s1")
  let second = helper.connect(channels, "s2")

  // Presence effects are asynchronous in the Lane D runtime. The snapshot
  // fences completion of the first join's track before the second join
  // performs its capacity read.
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  helper.recv(first) |> string.contains("\"status\":\"ok\"") |> should.be_true
  helper.recv(first) |> string.contains("presence_diff") |> should.be_true
  helper.recv(first) |> string.contains("presence_list") |> should.be_true

  helper.join(channels, "s2", "room:a", "jr-1", "r-1")
  let refusal = helper.recv(second)
  refusal |> string.contains("\"status\":\"error\"") |> should.be_true
  refusal |> string.contains("full") |> should.be_true
}

// --- termination actions ---------------------------------------------------

/// A channel that says goodbye on the way out: two broadcasts in a fixed
/// order and a presence untrack followed by an apply-time roster snapshot.
fn departing_handler(trace: process.Subject(String)) -> channel.Handler {
  channel.handler("room:*", fn(context) {
    channel.accept(Nil)
    |> channel.on_terminate(fn(_state, reason) {
      process.send(trace, "terminate:" <> helper.reason_name(reason))
      [
        channel.broadcast("bye_first", json.string(context.socket_id)),
        channel.broadcast("bye_second", json.string(context.socket_id)),
        channel.presence_untrack(context.socket_id),
        channel.broadcast_presence("presence_list", encode_users),
      ]
    })
    |> channel.with_actions([
      channel.presence_track(context.socket_id, json.object([])),
      channel.push_presence("presence_list", encode_users),
    ])
  })
}

pub fn termination_actions_are_applied_in_order_test() -> Nil {
  let handle = start_presence("terminate-order")
  let trace = process.new_subject()
  let channels = start_with_presence([departing_handler(trace)], handle)
  let leaver = helper.connect(channels, "s1")
  let peer = helper.connect(channels, "s2")

  join_pair(channels, leaver, peer)

  helper.leave(channels, "s1", "room:a", "jr-1", "r-2")
  helper.next_trace(trace) |> should.equal("terminate:normal")

  // The peer sees the departure announcements in the order the channel
  // added them, then the roster the leaver is no longer in.
  helper.recv(peer) |> string.contains("bye_first") |> should.be_true
  helper.recv(peer) |> string.contains("bye_second") |> should.be_true
  let diff = helper.recv(peer)
  diff |> string.contains("presence_diff") |> should.be_true
  let roster = helper.recv(peer)
  roster |> string.contains("presence_list") |> should.be_true
  roster |> string.contains("s2") |> should.be_true
  roster |> string.contains("s1") |> should.be_false
}

pub fn termination_actions_run_exactly_once_test() -> Nil {
  let handle = start_presence("terminate-once")
  let trace = process.new_subject()
  let channels = start_with_presence([departing_handler(trace)], handle)
  let leaver = helper.connect(channels, "s1")
  let peer = helper.connect(channels, "s2")

  join_pair(channels, leaver, peer)

  helper.leave(channels, "s1", "room:a", "jr-1", "r-2")
  helper.next_trace(trace) |> should.equal("terminate:normal")
  helper.recv(peer) |> string.contains("bye_first") |> should.be_true
  helper.recv(peer) |> string.contains("bye_second") |> should.be_true
  let _diff = helper.recv(peer)
  let _roster = helper.recv(peer)

  // Disconnecting the socket that already left runs no second
  // termination: the instance was removed before the callback ran.
  helper.disconnect(channels, "s1")
  helper.no_trace(trace)
  helper.recv_none(peer)
}

fn join_pair(
  channels: beryl.Sockets,
  first: helper.Frames,
  second: helper.Frames,
) -> Nil {
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  settle_join(first)
  helper.join(channels, "s2", "room:a", "jr-1", "r-1")
  settle_join(second)
  helper.recv(first) |> string.contains("presence_diff") |> should.be_true
}

fn settle_join(frames: helper.Frames) -> Nil {
  let frame = helper.recv(frames)
  case string.contains(frame, "presence_list") {
    True -> Nil
    False -> settle_join(frames)
  }
}
