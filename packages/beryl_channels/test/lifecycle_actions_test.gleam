//// Accept-time and termination-time actions: the two points where a
//// channel's effects have to share an update turn with a lifecycle
//// transition.
////
//// | Property | Why it matters |
//// |---|---|
//// | `AcceptJoin` is lowered before the join's actions | a push to a topic the socket has not joined yet is dropped by core |
//// | a join's `presence_track` runs in the join turn | a capacity check and the track that satisfies it cannot be split |
//// | termination actions apply in order, once | leave announcements and post-leave rosters are ordinary features |
//// | pushes to the closing topic are dropped | documented consequence of the topic being unsubscribed first |
////
//// Everything runs against a real system through beryl's public transport
//// SPI, so these are assertions about frames on the wire.

import beryl
import beryl/presence
import beryl/wire
import beryl_channels
import beryl_channels/channel
import dispatch_helpers as helper
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should

fn encode_users(entries: List(presence.PresenceEntry)) -> json.Json {
  json.object(list.map(entries, fn(entry) { #(entry.key, entry.meta) }))
}

fn start(handlers: List(channel.Handler)) -> beryl.Sockets {
  let assert Ok(channels) =
    beryl_channels.start(beryl.config(wire.phoenix_codec()), handlers: handlers)
    as "the handler table is valid"
  channels
}

fn start_with_presence(
  handlers: List(channel.Handler),
  handle: presence.Presence,
) -> beryl.Sockets {
  let assert Ok(channels) =
    beryl_channels.start(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_presence_handle(handle),
      handlers: handlers,
    )
    as "the handler table is valid"
  channels
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
  channel.handler("room:*", fn(_info, topic, _payload) {
    channel.accept_with(
      channel.joined(Nil, channel.callbacks()),
      json.object([#("joined", json.string(topic))]),
    )
    |> channel.with_actions(
      channel.actions()
      |> channel.push("welcome", json.string(topic))
      |> channel.broadcast("announce", json.string(topic)),
    )
  })
}

pub fn the_join_acknowledgment_precedes_the_joins_own_actions_test() {
  let channels = start([welcoming_handler()])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")

  // The acknowledgment is first...
  let ack = helper.recv(frames)
  ack |> string.contains("phx_reply") |> should.be_true
  ack |> string.contains("\"status\":\"ok\"") |> should.be_true
  ack |> string.contains("\"joined\":\"room:a\"") |> should.be_true

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
  channel.handler("room:*", fn(info, topic, _payload) {
    case list.length(presence.list(handle, topic)) >= 1 {
      True -> channel.reject(json.object([#("reason", json.string("full"))]))
      False ->
        channel.accept(channel.joined(Nil, channel.callbacks()))
        |> channel.with_actions(
          channel.actions()
          |> channel.presence_track(
            info.socket_id,
            json.object([#("at", json.string(topic))]),
          )
          |> channel.push_presence("presence_list", encode_users),
        )
    }
  })
}

pub fn a_join_time_presence_track_applies_in_the_join_turn_test() {
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

  let assert [entry] = presence.list(handle, "room:a")
    as "the presence actor holds the joiner"
  entry.key |> should.equal("s1")
}

pub fn a_capacity_check_and_its_track_are_not_split_by_another_join_test() {
  let handle = start_presence("capacity")
  let channels = start_with_presence([capacity_handler(handle)], handle)
  let first = helper.connect(channels, "s1")
  let second = helper.connect(channels, "s2")

  // Both joins are enqueued back to back, with nothing read in between:
  // the second join's turn runs immediately after the first one's. If the
  // track had been scheduled for a later turn (a self-notification), the
  // second join would still see an empty room and the cap would not hold.
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  helper.join(channels, "s2", "room:a", "jr-1", "r-1")

  helper.recv(first) |> string.contains("\"status\":\"ok\"") |> should.be_true

  let refusal = helper.recv(second)
  refusal |> string.contains("\"status\":\"error\"") |> should.be_true
  refusal |> string.contains("full") |> should.be_true
}

// --- termination actions ---------------------------------------------------

/// A channel that says goodbye on the way out: two broadcasts in a fixed
/// order, a push that core is expected to drop, and a presence untrack
/// followed by an apply-time roster snapshot.
fn departing_handler(trace: process.Subject(String)) -> channel.Handler {
  channel.handler("room:*", fn(info, _topic, _payload) {
    let callbacks =
      channel.callbacks()
      |> channel.on_terminate(fn(_state, reason) {
        process.send(trace, "terminate:" <> helper.reason_name(reason))
        channel.actions()
        |> channel.broadcast("bye_first", json.string(info.socket_id))
        |> channel.broadcast("bye_second", json.string(info.socket_id))
        |> channel.push("ghost", json.string(info.socket_id))
        |> channel.presence_untrack(info.socket_id)
        |> channel.broadcast_presence("presence_list", encode_users)
      })

    channel.accept(channel.joined(Nil, callbacks))
    |> channel.with_actions(
      channel.actions()
      |> channel.presence_track(info.socket_id, json.object([])),
    )
  })
}

pub fn termination_actions_are_applied_in_order_test() {
  let handle = start_presence("terminate-order")
  let trace = process.new_subject()
  let channels = start_with_presence([departing_handler(trace)], handle)
  let leaver = helper.connect(channels, "s1")
  let peer = helper.connect(channels, "s2")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  helper.join(channels, "s2", "room:a", "jr-1", "r-1")
  // Settle both sockets on the roster that includes the peer.
  let _ = helper.recv(leaver)
  let _ = helper.recv(leaver)
  let _ = helper.recv(peer)
  let _ = helper.recv(peer)

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

pub fn a_push_from_termination_is_dropped_by_core_test() {
  let handle = start_presence("terminate-push")
  let trace = process.new_subject()
  let channels = start_with_presence([departing_handler(trace)], handle)
  let leaver = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _ack = helper.recv(leaver)
  let _diff = helper.recv(leaver)

  helper.leave(channels, "s1", "room:a", "jr-1", "r-2")
  helper.next_trace(trace) |> should.equal("terminate:normal")

  // The leave reply, then the terminal frame — and nothing addressed to
  // the closing topic in between: the subscription is already gone, so
  // core drops the push (and, being unsubscribed, the leaver does not
  // receive its own broadcasts either).
  let seen = drain(leaver, [])
  list.any(seen, string.contains(_, "ghost")) |> should.be_false
  list.any(seen, string.contains(_, "bye_first")) |> should.be_false
  list.any(seen, string.contains(_, "phx_close")) |> should.be_true
}

pub fn termination_actions_run_exactly_once_test() {
  let handle = start_presence("terminate-once")
  let trace = process.new_subject()
  let channels = start_with_presence([departing_handler(trace)], handle)
  let leaver = helper.connect(channels, "s1")
  let peer = helper.connect(channels, "s2")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  helper.join(channels, "s2", "room:a", "jr-1", "r-1")
  let _ = helper.recv(leaver)
  let _ = helper.recv(leaver)
  let _ = helper.recv(peer)
  let _ = helper.recv(peer)

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

/// Drain a socket's frames until its terminal frame arrives.
fn drain(frames: helper.Frames, seen: List(String)) -> List(String) {
  case process.receive(frames, 500) {
    Error(Nil) -> seen
    Ok(frame) -> {
      let seen = list.append(seen, [frame])
      case string.contains(frame, "phx_close") {
        True -> seen
        False -> drain(frames, seen)
      }
    }
  }
}
