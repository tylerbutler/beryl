//// Asynchronous presence effects: the runtime never blocks its actor on a
//// presence mutation. The socket that issued one is parked (its later
//// messages queued, its remaining effects held) until presence
//// acknowledges; every other socket, broadcast, and heartbeat keeps being
//// served.
////
//// Delays are produced with a gate actor that the presence `on_diff`
//// callback calls into, so every "while the mutation is in flight" step is
//// a deterministic handshake rather than a sleep.

import app_test_helper
import beryl
import beryl/presence
import beryl/socket.{
  type Effect, type Next, AcceptJoin, BroadcastPresence, Closed, Join, Message,
  Next, PresenceTrack, PresenceUntrack,
}
import beryl/transport
import beryl/wire
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import gleeunit
import gleeunit/should
import test_helper

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Gate ────────────────────────────────────────────────────────────────────

/// A one-shot barrier the presence actor blocks on from inside `on_diff`.
///
/// `Arm` primes it for exactly one diff. The next diff after that reports
/// on `entered` and blocks the presence actor until `Release`; every other
/// diff passes straight through. Nothing here sleeps: the test knows the
/// mutation is genuinely in flight because `entered` fired.
type GateMessage {
  Arm
  Enter(reply: Subject(Nil))
  Release
}

type GateState {
  GateState(armed: Bool, waiting: Option(Subject(Nil)), entered: Subject(Nil))
}

fn start_gate(entered: Subject(Nil)) -> Subject(GateMessage) {
  let assert Ok(started) =
    actor.new(GateState(armed: False, waiting: None, entered: entered))
    |> actor.on_message(fn(state, message) {
      case message {
        Arm -> actor.continue(GateState(..state, armed: True))
        Enter(reply) ->
          case state.armed {
            False -> {
              process.send(reply, Nil)
              actor.continue(state)
            }
            True -> {
              process.send(state.entered, Nil)
              actor.continue(
                GateState(..state, armed: False, waiting: Some(reply)),
              )
            }
          }
        Release -> {
          case state.waiting {
            Some(reply) -> process.send(reply, Nil)
            None -> Nil
          }
          actor.continue(GateState(..state, waiting: None))
        }
      }
    })
    |> actor.start
  started.data
}

/// Prime the gate to hold the next presence diff.
fn arm(gate: Subject(GateMessage)) -> Nil {
  process.send(gate, Arm)
}

fn await_entered(entered: Subject(Nil)) -> Nil {
  let assert Ok(Nil) = process.receive(entered, 2000)
  Nil
}

fn release(gate: Subject(GateMessage)) -> Nil {
  process.send(gate, Release)
}

fn start_gated_presence(gate: Subject(GateMessage)) -> presence.Presence {
  let assert Ok(presence_handle) =
    presence.start(
      presence.default_config("node1")
      |> presence.with_on_diff(fn(_diff) { process.call(gate, 5000, Enter) }),
    )
  presence_handle
}

/// A gated presence that also reports every `on_diff` it is handed, as the
/// `phx_ref`s of its `room:a` joins and leaves. Reported *before* the gate
/// blocks, so a test can read the diff of a mutation that is still in
/// flight, and one message per callback — so a transition that should be
/// one aggregate diff cannot masquerade as two.
fn start_recording_gated_presence(
  gate: Subject(GateMessage),
  diffs: Subject(#(List(String), List(String))),
) -> presence.Presence {
  let assert Ok(presence_handle) =
    presence.start(
      presence.default_config("node1")
      |> presence.with_on_diff(fn(diff) {
        process.send(diffs, #(
          entry_refs(presence.diff_joins(diff, "room:a")),
          entry_refs(presence.diff_leaves(diff, "room:a")),
        ))
        process.call(gate, 5000, Enter)
      }),
    )
  presence_handle
}

fn entry_refs(entries: List(presence.PresenceEntry)) -> List(String) {
  list.map(entries, fn(entry) { meta_phx_ref(entry.meta) })
}

fn meta_phx_ref(meta: json.Json) -> String {
  let assert Ok(ref) =
    json.parse(json.to_string(meta), decode.at(["phx_ref"], decode.string))
  ref
}

fn next_diff(
  diffs: Subject(#(List(String), List(String))),
) -> #(List(String), List(String)) {
  let assert Ok(recorded) = process.receive(diffs, 2000)
  recorded
}

// ── System under test ───────────────────────────────────────────────────────

fn meta(status: String) -> json.Json {
  json.object([#("status", json.string(status))])
}

fn encode_users(entries: List(presence.PresenceEntry)) -> json.Json {
  json.object(list.map(entries, fn(entry) { #(entry.session_id, entry.meta) }))
}

/// Joins on `room:*` track one key and broadcast a snapshot; joins on
/// other topics touch presence at all, so they stay responsive while a
/// `room:*` mutation is in flight.
fn app_update(
  model: String,
  event: socket.Input(Nil),
  events: Subject(String),
) -> Next(String) {
  case event {
    Join(topic, _payload, ref) ->
      case
        string.starts_with(topic, "room:"),
        string.starts_with(topic, "flip:")
      {
        True, True | True, False ->
          Next(model, [
            AcceptJoin(ref, None),
            PresenceTrack(topic, "user:" <> model, meta("online")),
            BroadcastPresence(topic, "presence_list", encode_users),
          ])
        // Two mutations in one list: the socket parks twice, and nothing
        // queued behind it may slip in between them.
        False, True ->
          Next(model, [
            AcceptJoin(ref, None),
            PresenceTrack(topic, "user:" <> model, meta("online")),
            PresenceUntrack(topic, "user:" <> model),
            BroadcastPresence(topic, "presence_list", encode_users),
          ])
        False, False ->
          case string.starts_with(topic, "reclose:") {
            // Tracks a key on join so a `Closed` on this topic has a
            // previous ref to (attempt to) replace.
            True ->
              Next(model, [
                AcceptJoin(ref, None),
                PresenceTrack(topic, "user:" <> model, meta("online")),
              ])
            False -> Next(model, [AcceptJoin(ref, None)])
          }
      }
    Message(topic, "promote", _payload, _ref) ->
      Next(model, [
        PresenceTrack(topic, "user:" <> model, meta("away")),
        BroadcastPresence(topic, "presence_list", encode_users),
      ])
    Message(topic, "untrack", _payload, _ref) ->
      Next(model, [
        PresenceUntrack(topic, "user:" <> model),
        BroadcastPresence(topic, "presence_list", encode_users),
      ])
    Message(topic, "echo", _payload, _ref) ->
      Next(model, [socket.Push(topic, "echoed", json.object([]))])
    Message(_topic, event_name, _payload, _ref) -> {
      process.send(events, event_name)
      Next(model, [])
    }
    Closed(topic, _reason) -> {
      process.send(events, "closed:" <> topic)
      // Simulates an app that re-tracks the same key from `Closed` (e.g.
      // to record a "left at" status) — including a socket that never
      // tracked it at all on `reclose-fresh:*`, where the replacement has
      // no previous ref to speak of.
      case
        string.starts_with(topic, "reclose:")
        || string.starts_with(topic, "reclose-fresh:")
      {
        True ->
          Next(model, [PresenceTrack(topic, "user:" <> model, meta("closing"))])
        False -> Next(model, [])
      }
    }
    socket.Binary(..) | socket.Info(..) -> Next(model, [])
  }
}

fn start_system(
  handle: presence.Presence,
  events: Subject(String),
  configure: fn(beryl.Config) -> beryl.Config,
) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_presence_handle(handle)
        |> configure,
      init: fn(info: socket.ConnectInfo(Nil)) { #(info.socket_id, []) },
      update: fn(model, event) { app_update(model, event, events) },
    )
  channels
}

fn identity_config(config: beryl.Config) -> beryl.Config {
  config
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// One socket parked on a presence mutation must not delay any other
/// socket's join, message, or heartbeat handling.
pub fn pending_track_does_not_block_other_sockets_test() -> Nil {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let handle = start_gated_presence(gate)
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let slow_frames = app_test_helper.connect(channels, "slow")
  arm(gate)
  app_test_helper.join(channels, "slow", "room:a", "jr-1", "r-1")
  // The join reply is written before the track effect, so it lands even
  // though the socket is about to park.
  app_test_helper.recv(slow_frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  await_entered(entered)

  // With `slow` parked, another socket still joins, gets replies, and gets
  // heartbeat answers.
  let other_frames = app_test_helper.connect(channels, "other")
  app_test_helper.join(channels, "other", "plain:a", "jr-2", "r-2")
  app_test_helper.recv(other_frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  app_test_helper.push(channels, "other", "plain:a", "ping", "r-3")
  process.receive(events, 500) |> should.equal(Ok("ping"))
  app_test_helper.route(
    channels,
    "other",
    "[null,\"hb-1\",\"phoenix\",\"heartbeat\",{}]",
  )
  app_test_helper.recv(other_frames)
  |> string.contains("hb-1")
  |> should.be_true

  release(gate)

  // The parked socket then finishes its own effect list, in order.
  app_test_helper.recv(slow_frames)
  |> string.contains("presence_diff")
  |> should.be_true
  app_test_helper.recv(slow_frames)
  |> string.contains("presence_list")
  |> should.be_true
}

/// A parked socket's later inbound events are queued, not dropped or
/// reordered, and are delivered once the mutation is acknowledged.
pub fn queued_messages_are_delivered_in_arrival_order_test() -> Nil {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let handle = start_gated_presence(gate)
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let frames = app_test_helper.connect(channels, "s1")
  arm(gate)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  await_entered(entered)

  app_test_helper.push(channels, "s1", "room:a", "one", "r-2")
  app_test_helper.push(channels, "s1", "room:a", "two", "r-3")
  app_test_helper.push(channels, "s1", "room:a", "three", "r-4")

  // Queued, not dispatched: the app has not seen them yet.
  process.receive(events, 200) |> should.be_error

  release(gate)

  process.receive(events, 1000) |> should.equal(Ok("one"))
  process.receive(events, 1000) |> should.equal(Ok("two"))
  process.receive(events, 1000) |> should.equal(Ok("three"))
}

/// `[PresenceTrack, BroadcastPresence]` — the snapshot reflects the track
/// and the diff is written first.
pub fn track_then_snapshot_keeps_wire_order_test() -> Nil {
  let assert Ok(handle) = presence.start(presence.default_config("node1"))
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  app_test_helper.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true

  let diff = app_test_helper.recv(frames)
  diff |> string.contains("presence_diff") |> should.be_true
  diff |> string.contains("\"joins\"") |> should.be_true

  let snapshot = app_test_helper.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  snapshot |> string.contains("\"s1\"") |> should.be_true
  snapshot |> string.contains("online") |> should.be_true
}

/// `[PresenceUntrack, BroadcastPresence]` — the snapshot reflects the
/// untrack, and the leave diff still comes first.
pub fn untrack_then_snapshot_keeps_wire_order_test() -> Nil {
  let assert Ok(handle) = presence.start(presence.default_config("node1"))
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  let _join_diff = app_test_helper.recv(frames)
  let _join_snapshot = app_test_helper.recv(frames)

  app_test_helper.push(channels, "s1", "room:a", "untrack", "r-2")

  let diff = app_test_helper.recv(frames)
  diff |> string.contains("presence_diff") |> should.be_true
  diff |> string.contains("\"leaves\"") |> should.be_true
  diff |> string.contains("user:s1") |> should.be_true

  let snapshot = app_test_helper.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  snapshot |> string.contains("\"s1\"") |> should.be_false
  presence_count(handle, "room:a") |> should.equal(0)
}

/// Re-tracking a key is one atomic replacement: one diff frame carrying
/// both the leave and the join, no empty snapshot in between, and the
/// leave's `phx_ref` is exactly the ref the previous join published.
pub fn replacement_is_atomic_and_shares_phx_refs_test() -> Nil {
  let assert Ok(handle) = presence.start(presence.default_config("node1"))
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  let join_diff = app_test_helper.recv(frames)
  let _join_snapshot = app_test_helper.recv(frames)
  let first_ref = phx_ref_of(join_diff, "joins")
  // The published ref is the one actually stored.
  first_ref |> should.equal(stored_phx_ref(handle, "room:a"))

  app_test_helper.push(channels, "s1", "room:a", "promote", "r-2")

  // Exactly one diff frame, carrying the whole leave+join transition.
  let replace_diff = app_test_helper.recv(frames)
  replace_diff |> string.contains("presence_diff") |> should.be_true
  replace_diff |> string.contains("online") |> should.be_true
  replace_diff |> string.contains("away") |> should.be_true
  // The leave names the entry the first join published; the new join names
  // the entry that is now stored.
  phx_ref_of(replace_diff, "leaves") |> should.equal(first_ref)
  let second_ref = phx_ref_of(replace_diff, "joins")
  second_ref |> should.not_equal(first_ref)
  second_ref |> should.equal(stored_phx_ref(handle, "room:a"))

  // The replacement never left the key absent: one entry throughout.
  presence_count(handle, "room:a") |> should.equal(1)
  let snapshot = app_test_helper.recv(frames)
  snapshot |> string.contains("away") |> should.be_true
  snapshot |> string.contains("online") |> should.be_false
  // No second diff: the replacement was not a separate untrack + track.
  app_test_helper.recv_none(frames)
}

/// Closing a topic untracks every key the socket still held as one batch:
/// one aggregate leave diff, no duplicates.
pub fn topic_close_emits_one_aggregate_leave_diff_test() -> Nil {
  let assert Ok(handle) = presence.start(presence.default_config("node1"))
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_presence_handle(handle),
      init: fn(info: socket.ConnectInfo(Nil)) { #(info.socket_id, []) },
      update: fn(model: String, event: socket.Input(Nil)) {
        case event {
          Join(topic, _payload, ref) ->
            Next(model, [
              AcceptJoin(ref, None),
              ..multi_track_effects(topic, model)
            ])
          socket.Message(..)
          | socket.Binary(..)
          | socket.Closed(..)
          | socket.Info(..) -> Next(model, [])
        }
      },
    )

  let watcher = app_test_helper.connect(channels, "watcher")
  app_test_helper.join(channels, "watcher", "room:a", "jr-w", "r-w")
  let _watcher_reply = app_test_helper.recv(watcher)
  // The watcher's own three join diffs.
  let _own_one = app_test_helper.recv(watcher)
  let _own_two = app_test_helper.recv(watcher)
  let _own_three = app_test_helper.recv(watcher)

  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  // s1 tracks three keys: three separate join diffs, one per effect.
  let _one = app_test_helper.recv(watcher)
  let _two = app_test_helper.recv(watcher)
  let _three = app_test_helper.recv(watcher)
  presence_count(handle, "room:a") |> should.equal(6)

  app_test_helper.route(
    channels,
    "s1",
    "[\"jr-1\",\"r-2\",\"room:a\",\"phx_leave\",{}]",
  )

  // One diff for the whole topic, naming each of s1's keys exactly once.
  let leave_diff = app_test_helper.recv(watcher)
  leave_diff |> string.contains("presence_diff") |> should.be_true
  leave_diff |> string.contains("\"joins\":{}") |> should.be_true
  count_occurrences(leave_diff, "s1:a") |> should.equal(1)
  count_occurrences(leave_diff, "s1:b") |> should.equal(1)
  count_occurrences(leave_diff, "s1:c") |> should.equal(1)
  app_test_helper.recv_none(watcher)

  test_helper.wait_until(
    fn() { presence_count(handle, "room:a") == 3 },
    2000,
    20,
  )
}

fn multi_track_effects(topic: String, model: String) -> List(Effect) {
  ["a", "b", "c"]
  |> list.map(fn(suffix) {
    PresenceTrack(topic, model <> ":" <> suffix, meta("online"))
  })
}

/// A mutation that is never acknowledged must not park the socket forever:
/// the runtime gives up after the configured timeout, resumes the rest of
/// the effect list without claiming the track succeeded, and safely
/// discards the acknowledgement when it finally shows up.
pub fn unacknowledged_mutation_times_out_and_late_ack_is_ignored_test() -> Nil {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let handle = start_gated_presence(gate)
  let events = process.new_subject()
  let channels =
    start_system(handle, events, beryl.with_presence_op_timeout(_, 150))

  let frames = app_test_helper.connect(channels, "s1")
  arm(gate)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  app_test_helper.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  await_entered(entered)

  // After the timeout the socket resumes: no join diff was broadcast (the
  // track was never confirmed), but the snapshot effect after it still
  // runs.
  let snapshot = app_test_helper.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  snapshot |> string.contains("presence_diff") |> should.be_false

  // The socket is live again straight away, not waiting on anything.
  app_test_helper.push(channels, "s1", "room:a", "ping", "r-2")
  process.receive(events, 1000) |> should.equal(Ok("ping"))

  // The acknowledgement finally arrives, for an operation nobody is
  // waiting on any more: dropped, with no extra frame and no crash.
  release(gate)
  app_test_helper.recv_none(frames)
  app_test_helper.push(channels, "s1", "room:a", "pong", "r-3")
  process.receive(events, 1000) |> should.equal(Ok("pong"))
}

/// The presence actor can still apply a track and acknowledge it after the
/// runtime has already given up on it (timed out) and resumed the socket.
/// Nobody is waiting on that acknowledgement any more, but the entry it
/// just created is real: left alone it would sit in presence forever,
/// with nothing ever holding the ref needed to remove it. The runtime must
/// untrack exactly that ref instead.
pub fn late_tracked_ack_after_timeout_is_compensated_test() -> Nil {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let handle = start_gated_presence(gate)
  let events = process.new_subject()
  let channels =
    start_system(handle, events, beryl.with_presence_op_timeout(_, 150))

  let frames = app_test_helper.connect(channels, "s1")
  arm(gate)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  app_test_helper.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  await_entered(entered)

  // The runtime gives up before the actor replies: no ref was recorded,
  // so presence itself is still empty from this side's point of view.
  let snapshot = app_test_helper.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  presence_count(handle, "room:a") |> should.equal(0)

  // The actor finally applies the track and acknowledges it. The runtime
  // drops the acknowledgement (nobody is parked on it any more) but must
  // still compensate: presence settles back to empty rather than keeping
  // a ghost entry nothing can ever remove.
  release(gate)
  app_test_helper.recv_none(frames)
  test_helper.wait_until(
    fn() { presence_count(handle, "room:a") == 0 },
    2000,
    20,
  )
  presence_entries(handle, "room:a") |> should.equal([])
}

/// After a track times out, the app may reasonably retry it. The first
/// attempt's stale acknowledgement is still going to show up; it must not
/// leave its ref coexisting with the retry's, or presence would show the
/// same session twice under the same key.
pub fn retrack_after_timeout_does_not_double_count_test() -> Nil {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let handle = start_gated_presence(gate)
  let events = process.new_subject()
  let channels =
    start_system(handle, events, beryl.with_presence_op_timeout(_, 150))

  let frames = app_test_helper.connect(channels, "s1")
  arm(gate)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  app_test_helper.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  await_entered(entered)

  let snapshot = app_test_helper.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true

  // Let the stale first attempt land and be compensated before retrying,
  // so the retry starts from a genuinely empty topic.
  release(gate)
  app_test_helper.recv_none(frames)
  test_helper.wait_until(
    fn() { presence_count(handle, "room:a") == 0 },
    2000,
    20,
  )

  // The app retries the same track.
  app_test_helper.push(channels, "s1", "room:a", "promote", "r-2")
  app_test_helper.recv(frames)
  |> string.contains("presence_diff")
  |> should.be_true
  app_test_helper.recv(frames)
  |> string.contains("presence_list")
  |> should.be_true

  // Exactly one entry, and it is the retry's — not a leftover from the
  // timed-out first attempt plus the retry.
  presence_count(handle, "room:a") |> should.equal(1)
  let assert [entry] = presence_entries(handle, "room:a")
  json.to_string(entry.meta) |> string.contains("away") |> should.be_true
}

/// A stale acknowledgement can arrive for an operation the runtime has
/// already replaced with a newer one for the same socket: a track on one
/// topic times out, and a track on a *different* topic for the same
/// socket is still pending when the first attempt's stale acknowledgement
/// shows up. The stale entry must be cleaned up without disturbing the
/// still-pending newer operation in any way.
///
/// (The harder case — both operations on the *same* topic and key, where
/// the CRDT's `(session, topic, key)` removal primitive would let the
/// compensating untrack take the newer entry with it — is covered by
/// `same_key_retrack_while_stale_track_is_in_flight_keeps_one_entry_test`
/// below.)
pub fn stale_ack_during_newer_pending_op_does_not_corrupt_it_test() -> Nil {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let handle = start_gated_presence(gate)
  let events = process.new_subject()
  let channels =
    start_system(handle, events, beryl.with_presence_op_timeout(_, 150))

  let frames = app_test_helper.connect(channels, "s1")
  arm(gate)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  app_test_helper.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  await_entered(entered)

  // Queued behind the parked socket: it cannot start until the timeout
  // resumes it below.
  app_test_helper.join(channels, "s1", "room:b", "jr-2", "r-2")

  // The runtime gives up on the first track (room:a). Its own remaining
  // effect (the join's snapshot) runs, and only then does the queued join
  // on room:b start its own track — while the first attempt's
  // acknowledgement is still outstanding at the (still gate-blocked)
  // presence actor.
  let snapshot_a = app_test_helper.recv(frames)
  snapshot_a |> string.contains("presence_list") |> should.be_true
  snapshot_a |> string.contains("room:a") |> should.be_true
  snapshot_a |> string.contains("presence_diff") |> should.be_false

  let reply_b = app_test_helper.recv(frames)
  reply_b |> string.contains("\"status\":\"ok\"") |> should.be_true

  // Let both the stale room:a track and the pending room:b track resolve
  // at the actor.
  release(gate)

  // room:b's own join diff and snapshot land, in order: it completed on
  // its own terms, untouched by the stale room:a acknowledgement arriving
  // around the same time.
  let diff_b = app_test_helper.recv(frames)
  diff_b |> string.contains("presence_diff") |> should.be_true
  diff_b |> string.contains("room:b") |> should.be_true
  diff_b |> string.contains("user:s1") |> should.be_true
  let snapshot_b = app_test_helper.recv(frames)
  snapshot_b |> string.contains("presence_list") |> should.be_true
  snapshot_b |> string.contains("room:b") |> should.be_true

  // room:b's track is intact — not corrupted by the stale room:a
  // acknowledgement — and room:a's stale entry is cleaned up rather than
  // left stranded.
  test_helper.wait_until(
    fn() { presence_count(handle, "room:b") == 1 },
    2000,
    20,
  )
  presence_count(handle, "room:b") |> should.equal(1)
  test_helper.wait_until(
    fn() { presence_count(handle, "room:a") == 0 },
    2000,
    20,
  )
}

/// The same-key version of the race above, which the `(session, topic,
/// key)` shape of the CRDT's removal primitive makes the dangerous one.
///
/// A track on `room:a`/`user:s1` times out while the presence actor is
/// blocked, so the runtime never learns its ref. The very same socket then
/// tracks the very same key again, and that retrack is still pending when
/// the timed-out attempt's acknowledgement (and the untrack compensating
/// it) finally lands. Because presence removes by tuple and not by ref,
/// the compensation would remove the retrack's entry too if both refs
/// could coexist — so the retrack must supersede the stale ref in the same
/// actor turn that adds its own, leaving the compensation a no-op.
pub fn same_key_retrack_while_stale_track_is_in_flight_keeps_one_entry_test() -> Nil {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let diffs = process.new_subject()
  let handle = start_recording_gated_presence(gate, diffs)
  let events = process.new_subject()
  let channels =
    start_system(handle, events, beryl.with_presence_op_timeout(_, 150))

  let frames = app_test_helper.connect(channels, "s1")
  // The join's track blocks inside the presence actor's `on_diff`, so its
  // acknowledgement cannot reach the runtime before the timeout.
  arm(gate)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  app_test_helper.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  await_entered(entered)
  // The first attempt's entry exists inside the actor's turn but has not
  // been published yet, and the runtime never learned its ref.
  let #(first_joins, first_leaves) = next_diff(diffs)
  first_leaves |> should.equal([])
  let assert [first_ref] = first_joins
  presence_count(handle, "room:a") |> should.equal(0)

  // Queued behind the parked socket: a retrack of the *same* key, on the
  // same topic, from the same socket.
  app_test_helper.push(channels, "s1", "room:a", "promote", "r-2")

  // The runtime gives up on the first track and resumes the socket: its
  // snapshot effect runs (with no join diff — the track was never
  // confirmed) and the queued retrack is dispatched behind it.
  let stale_snapshot = app_test_helper.recv(frames)
  stale_snapshot |> string.contains("presence_list") |> should.be_true
  stale_snapshot |> string.contains("presence_diff") |> should.be_false

  // Hold the retrack inside the actor too, so the test knows for certain
  // that it is in flight when the stale attempt resolves.
  arm(gate)
  release(gate)
  await_entered(entered)

  // One aggregate transition for the retrack: the stale ref leaves and the
  // new one joins in the same callback — never a moment with two live
  // refs for the key.
  let #(retrack_joins, retrack_leaves) = next_diff(diffs)
  retrack_leaves |> should.equal([first_ref])
  let assert [second_ref] = retrack_joins
  second_ref |> should.not_equal(first_ref)

  // Let the retrack finish. The stale acknowledgement and its compensating
  // untrack interleave with it: the compensation reaches the actor after
  // the retrack's turn, and must be a no-op there.
  app_test_helper.push(channels, "s1", "room:a", "echo", "r-3")
  release(gate)

  let retrack_diff = app_test_helper.recv(frames)
  retrack_diff |> string.contains("presence_diff") |> should.be_true
  retrack_diff |> string.contains("away") |> should.be_true
  // The timed-out attempt was never broadcast, so there is nothing to
  // leave — and the join names the ref presence actually stored.
  retrack_diff |> string.contains("\"leaves\":{}") |> should.be_true
  phx_ref_of(retrack_diff, "joins") |> should.equal(second_ref)
  let snapshot = app_test_helper.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  snapshot |> string.contains("away") |> should.be_true
  snapshot |> string.contains("online") |> should.be_false
  // Only then the message queued while the socket was parked on the
  // retrack.
  app_test_helper.recv(frames) |> string.contains("echoed") |> should.be_true

  // Barrier: the compensating untrack was sent to the presence actor
  // before the acknowledgement that produced the frames above, so it is
  // already in the actor's mailbox and is handled strictly before this
  // synchronous call returns.
  presence.untrack(handle, "no-such-ref")

  // Exactly one entry survives, and it is the retrack's.
  presence_count(handle, "room:a") |> should.equal(1)
  stored_phx_ref(handle, "room:a") |> should.equal(second_ref)
  let assert [entry] = presence_entries(handle, "room:a")
  entry.key |> should.equal("user:s1")
  json.to_string(entry.meta) |> string.contains("away") |> should.be_true
  // The compensation changed nothing: no leave diff for the live entry.
  process.receive(diffs, 200) |> should.be_error

  // And the runtime's own bookkeeping still names that entry, so an
  // ordinary untrack removes it.
  app_test_helper.push(channels, "s1", "room:a", "untrack", "r-4")
  let leave_diff = app_test_helper.recv(frames)
  leave_diff |> string.contains("presence_diff") |> should.be_true
  phx_ref_of(leave_diff, "leaves") |> should.equal(second_ref)
  app_test_helper.recv(frames)
  |> string.contains("presence_list")
  |> should.be_true
  presence_count(handle, "room:a") |> should.equal(0)

  // Closing the topic afterwards has nothing left to clean up.
  app_test_helper.route(
    channels,
    "s1",
    "[\"jr-1\",\"r-5\",\"room:a\",\"phx_leave\",{}]",
  )
  process.receive(events, 500) |> should.equal(Ok("closed:room:a"))
  presence_count(handle, "room:a") |> should.equal(0)
}

/// A timed-out runtime track may acknowledge after a newer synchronous public
/// `presence.track` has claimed the exact same session/topic/key. The stale
/// compensation must remove only the runtime-owned CRDT tag, survive normal
/// topic cleanup, and leave neither ref capable of deleting a later entry.
pub fn stale_runtime_ack_preserves_newer_public_same_key_track_test() -> Nil {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let diffs = process.new_subject()
  let handle = start_recording_gated_presence(gate, diffs)
  let events = process.new_subject()
  let channels =
    start_system(handle, events, beryl.with_presence_op_timeout(_, 150))

  let frames = app_test_helper.connect(channels, "s1")
  arm(gate)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  app_test_helper.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  await_entered(entered)
  let #(runtime_joins, runtime_leaves) = next_diff(diffs)
  runtime_leaves |> should.equal([])
  let assert [runtime_ref] = runtime_joins

  // The runtime times out while the actor is still inside the first track.
  app_test_helper.recv(frames)
  |> string.contains("presence_list")
  |> should.be_true

  // Queue the public track behind that in-flight runtime mutation before
  // releasing it. Mailbox observation makes the ordering deterministic.
  let public_done = process.new_subject()
  let assert Ok(presence_pid) = process.subject_owner(presence.subject(handle))
  let _public_tracker =
    process.spawn_unlinked(fn() {
      let ref =
        presence.track(handle, "room:a", "user:s1", "s1", meta("public"))
      process.send(public_done, ref)
    })
  test_helper.wait_until(
    fn() { test_helper.mailbox_length(presence_pid) >= 1 },
    1000,
    5,
  )
  release(gate)

  let assert Ok(public_ref) = process.receive(public_done, 2000)
  let #(public_joins, public_leaves) = next_diff(diffs)
  public_joins |> should.equal([public_ref])
  public_leaves |> should.equal([])

  // The stale acknowledgement is compensated after the already-queued public
  // track. Only the runtime ref leaves.
  let #(compensation_joins, compensation_leaves) = next_diff(diffs)
  compensation_joins |> should.equal([])
  compensation_leaves |> should.equal([runtime_ref])
  presence.untrack(handle, "no-such-ref")

  let assert [public_entry] = presence_entries(handle, "room:a")
  meta_phx_ref(public_entry.meta) |> should.equal(public_ref)
  json.to_string(public_entry.meta)
  |> string.contains("public")
  |> should.be_true

  // Runtime topic cleanup owns no public ref and must leave it intact.
  app_test_helper.route(
    channels,
    "s1",
    "[\"jr-1\",\"r-2\",\"room:a\",\"phx_leave\",{}]",
  )
  process.receive(events, 500) |> should.equal(Ok("closed:room:a"))
  presence.untrack(handle, "no-such-ref")
  presence_count(handle, "room:a") |> should.equal(1)

  // Replaying the compensated ref is a no-op, proving it is no longer
  // dangling in the actor's ref index.
  presence.untrack(handle, runtime_ref)
  presence_count(handle, "room:a") |> should.equal(1)
  process.receive(diffs, 100) |> should.be_error

  presence.untrack(handle, public_ref)
  let #(cleanup_joins, cleanup_leaves) = next_diff(diffs)
  cleanup_joins |> should.equal([])
  cleanup_leaves |> should.equal([public_ref])
  presence_count(handle, "room:a") |> should.equal(0)

  // A later entry cannot be reached through either old ref.
  let later_ref =
    presence.track(handle, "room:a", "user:s1", "s1", meta("later"))
  let #(later_joins, later_leaves) = next_diff(diffs)
  later_joins |> should.equal([later_ref])
  later_leaves |> should.equal([])
  presence.untrack(handle, runtime_ref)
  presence.untrack(handle, public_ref)
  presence_count(handle, "room:a") |> should.equal(1)
  process.receive(diffs, 100) |> should.be_error

  presence.untrack(handle, later_ref)
  let #(final_joins, final_leaves) = next_diff(diffs)
  final_joins |> should.equal([])
  final_leaves |> should.equal([later_ref])
  presence_entries(handle, "room:a") |> should.equal([])
}

/// Shutdown cannot wait for a timed-out track's ref, so it queues a
/// runtime-owned session sweep behind the in-flight mutation. A public track
/// already queued for the same tuple must survive that cleanup.
pub fn shutdown_stale_track_cleanup_preserves_newer_public_track_test() -> Nil {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let diffs = process.new_subject()
  let handle = start_recording_gated_presence(gate, diffs)
  let events = process.new_subject()
  let channels =
    start_system(handle, events, beryl.with_presence_op_timeout(_, 150))

  let frames = app_test_helper.connect(channels, "s1")
  arm(gate)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  app_test_helper.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  await_entered(entered)
  let #(runtime_joins, runtime_leaves) = next_diff(diffs)
  runtime_leaves |> should.equal([])
  let assert [runtime_ref] = runtime_joins
  app_test_helper.recv(frames)
  |> string.contains("presence_list")
  |> should.be_true

  let public_done = process.new_subject()
  let assert Ok(presence_pid) = process.subject_owner(presence.subject(handle))
  let _public_tracker =
    process.spawn_unlinked(fn() {
      let ref =
        presence.track(handle, "room:a", "user:s1", "s1", meta("public"))
      process.send(public_done, ref)
    })
  test_helper.wait_until(
    fn() { test_helper.mailbox_length(presence_pid) >= 1 },
    1000,
    5,
  )

  let assert Ok(Nil) = beryl.stop(channels)
  process.receive(events, 500) |> should.equal(Ok("closed:room:a"))
  release(gate)

  let assert Ok(public_ref) = process.receive(public_done, 2000)
  let #(public_joins, public_leaves) = next_diff(diffs)
  public_joins |> should.equal([public_ref])
  public_leaves |> should.equal([])
  let #(sweep_joins, sweep_leaves) = next_diff(diffs)
  sweep_joins |> should.equal([])
  sweep_leaves |> should.equal([runtime_ref])
  presence.untrack(handle, "no-such-ref")

  let assert [public_entry] = presence_entries(handle, "room:a")
  meta_phx_ref(public_entry.meta) |> should.equal(public_ref)
  presence.untrack(handle, runtime_ref)
  presence_count(handle, "room:a") |> should.equal(1)
  process.receive(diffs, 100) |> should.be_error

  presence.untrack(handle, public_ref)
  let #(cleanup_joins, cleanup_leaves) = next_diff(diffs)
  cleanup_joins |> should.equal([])
  cleanup_leaves |> should.equal([public_ref])
  presence_entries(handle, "room:a") |> should.equal([])
}

/// A track the runtime already gave up on can still be applied by the
/// presence actor afterwards — and once the runtime has stopped there is
/// nothing left to receive its acknowledgement, so nothing left to
/// compensate it either. Shutdown therefore sweeps every session still
/// owed such an acknowledgement, ordered behind the in-flight track itself.
pub fn shutdown_sweeps_sessions_owed_a_stale_track_test() -> Nil {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let diffs = process.new_subject()
  let handle = start_recording_gated_presence(gate, diffs)
  let events = process.new_subject()
  let channels =
    start_system(handle, events, beryl.with_presence_op_timeout(_, 150))

  let frames = app_test_helper.connect(channels, "s1")
  arm(gate)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  app_test_helper.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  await_entered(entered)

  // The runtime gives up on the track and resumes the socket without it.
  app_test_helper.recv(frames)
  |> string.contains("presence_list")
  |> should.be_true

  // Stopping dispatches the sweep for the acknowledgement still owed; the
  // presence actor only applies the track after that.
  let _ = beryl.stop(channels)
  release(gate)
  let #(joins, _leaves) = next_diff(diffs)
  let assert [_ref] = joins

  // Barrier: the sweep was in the actor's mailbox before this synchronous
  // call, so it has been handled by the time it returns.
  presence.untrack(handle, "no-such-ref")
  presence_count(handle, "room:a") |> should.equal(0)
  presence_entries(handle, "room:a") |> should.equal([])
}

/// A `Closed` handler running during `beryl.stop` may return a
/// `PresenceTrack` that replaces the key the socket already holds. The
/// runtime is stopping, so the track itself can never be completed (there
/// is no runtime left to receive an acknowledgement) and stays dropped —
/// but the previous ref must not be orphaned in the presence actor. This
/// topic's automatic close cleanup runs immediately after `Closed`, in the
/// same actor turn, still finds the previous ref in the socket's
/// bookkeeping (untouched by the dropped track), and is what actually
/// untracks it from presence and broadcasts its leave. The presence actor
/// itself is never stopped by `beryl.stop` and must still be responsive
/// afterwards, holding no stray entry for this socket.
pub fn closed_presence_track_replacement_during_stop_does_not_orphan_entry_test() -> Nil {
  let assert Ok(handle) = presence.start(presence.default_config("node1"))
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "reclose:room", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  let _join_diff = app_test_helper.recv(frames)
  presence_count(handle, "reclose:room") |> should.equal(1)

  let assert Ok(Nil) = beryl.stop(channels)
  process.receive(events, 500) |> should.equal(Ok("closed:reclose:room"))

  // Barrier: any fire-and-forget presence message the runtime sent while
  // tearing down is already in the actor's mailbox by the time this
  // synchronous call returns.
  presence.untrack(handle, "no-such-ref")
  presence_count(handle, "reclose:room") |> should.equal(0)
  presence_entries(handle, "reclose:room") |> should.equal([])
}

/// The same scenario, but the socket never held the key `Closed` tries to
/// (re-)track: with no previous ref, the dropped track must stay dropped
/// and create no entry at all.
pub fn closed_presence_track_with_no_previous_ref_during_stop_creates_no_entry_test() -> Nil {
  let assert Ok(handle) = presence.start(presence.default_config("node1"))
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "reclose-fresh:room", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  presence_count(handle, "reclose-fresh:room") |> should.equal(0)

  let assert Ok(Nil) = beryl.stop(channels)
  process.receive(events, 500)
  |> should.equal(Ok("closed:reclose-fresh:room"))

  presence.untrack(handle, "no-such-ref")
  presence_count(handle, "reclose-fresh:room") |> should.equal(0)
  presence_entries(handle, "reclose-fresh:room") |> should.equal([])
}

/// Shutdown cannot simply discard a pending replacement after removing the
/// previous ref from socket bookkeeping. It must publish that previous entry's
/// leave, then let the presence actor finish and sweep the replacement ref so
/// local subscribers and remote presence replicas both converge to empty.
pub fn shutdown_while_replacement_pending_emits_leave_and_cleans_refs_test() -> Nil {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let diffs = process.new_subject()
  let handle = start_recording_gated_presence(gate, diffs)
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let watcher = app_test_helper.connect(channels, "watcher")
  app_test_helper.join(channels, "watcher", "room:a", "jr-w", "r-w")
  let _watcher_reply = app_test_helper.recv(watcher)
  let watcher_join = app_test_helper.recv(watcher)
  let watcher_ref = phx_ref_of(watcher_join, "joins")
  let _watcher_snapshot = app_test_helper.recv(watcher)
  let _watcher_actor_join = next_diff(diffs)

  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  let initial_join = app_test_helper.recv(frames)
  let previous_ref = phx_ref_of(initial_join, "joins")
  let _snapshot = app_test_helper.recv(frames)
  let _watcher_saw_join = app_test_helper.recv(watcher)
  let _watcher_saw_snapshot = app_test_helper.recv(watcher)
  let _initial_actor_join = next_diff(diffs)

  arm(gate)
  app_test_helper.push(channels, "s1", "room:a", "promote", "r-2")
  await_entered(entered)
  let #(replacement_joins, replacement_leaves) = next_diff(diffs)
  replacement_leaves |> should.equal([previous_ref])
  let assert [replacement_ref] = replacement_joins

  let assert Ok(Nil) = beryl.stop(channels)

  // The runtime finalizes the pending replacement through PresenceStopping
  // before tearing sockets down, so the still-subscribed watcher sees the
  // previous entry leave even though the replacement acknowledgement is held.
  let local_leave = app_test_helper.recv(watcher)
  local_leave |> string.contains("presence_diff") |> should.be_true
  phx_ref_of(local_leave, "leaves") |> should.equal(previous_ref)

  release(gate)
  let #(sweep_joins, sweep_leaves) = next_diff(diffs)
  sweep_joins |> should.equal([])
  sweep_leaves |> should.equal([replacement_ref])
  let #(watcher_joins, watcher_leaves) = next_diff(diffs)
  watcher_joins |> should.equal([])
  watcher_leaves |> should.equal([watcher_ref])

  // Barrier: the replacement and both shutdown cleanups are now applied.
  presence.untrack(handle, "no-such-ref")
  presence_entries(handle, "room:a") |> should.equal([])

  // Neither superseded nor swept refs remain capable of touching later state.
  presence.untrack(handle, previous_ref)
  presence.untrack(handle, replacement_ref)
  presence.untrack(handle, watcher_ref)
  process.receive(diffs, 100) |> should.be_error
}

/// A pending explicit untrack has already dropped its ref from socket
/// bookkeeping. Shutdown must still publish its leave instead of relying on
/// topic cleanup that can no longer see it, while the actor completes the
/// exact-ref removal for remote convergence.
pub fn shutdown_while_untrack_pending_emits_leave_and_cleans_ref_test() -> Nil {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let diffs = process.new_subject()
  let handle = start_recording_gated_presence(gate, diffs)
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let watcher = app_test_helper.connect(channels, "watcher")
  app_test_helper.join(channels, "watcher", "room:a", "jr-w", "r-w")
  let _watcher_reply = app_test_helper.recv(watcher)
  let watcher_join = app_test_helper.recv(watcher)
  let watcher_ref = phx_ref_of(watcher_join, "joins")
  let _watcher_snapshot = app_test_helper.recv(watcher)
  let _watcher_actor_join = next_diff(diffs)

  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  let initial_join = app_test_helper.recv(frames)
  let tracked_ref = phx_ref_of(initial_join, "joins")
  let _snapshot = app_test_helper.recv(frames)
  let _watcher_saw_join = app_test_helper.recv(watcher)
  let _watcher_saw_snapshot = app_test_helper.recv(watcher)
  let _initial_actor_join = next_diff(diffs)

  arm(gate)
  app_test_helper.push(channels, "s1", "room:a", "untrack", "r-2")
  await_entered(entered)
  let #(actor_joins, actor_leaves) = next_diff(diffs)
  actor_joins |> should.equal([])
  actor_leaves |> should.equal([tracked_ref])

  let assert Ok(Nil) = beryl.stop(channels)

  let local_leave = app_test_helper.recv(watcher)
  local_leave |> string.contains("presence_diff") |> should.be_true
  phx_ref_of(local_leave, "leaves") |> should.equal(tracked_ref)

  release(gate)
  let #(watcher_joins, watcher_leaves) = next_diff(diffs)
  watcher_joins |> should.equal([])
  watcher_leaves |> should.equal([watcher_ref])

  presence.untrack(handle, "no-such-ref")
  presence_entries(handle, "room:a") |> should.equal([])

  presence.untrack(handle, tracked_ref)
  presence.untrack(handle, watcher_ref)
  process.receive(diffs, 100) |> should.be_error
}

/// Graceful shutdown deliberately dispatches its batch presence cleanup
/// fire-and-forget, without waiting for an acknowledgement — there is no
/// runtime left to receive one. That is not a failure and must not be
/// logged as one.
pub fn graceful_shutdown_cleanup_is_not_logged_as_a_failure_test() -> Nil {
  let assert Ok(handle) = presence.start(presence.default_config("node1"))
  let events = process.new_subject()
  let channels =
    start_system(handle, events, fn(config) {
      config
      |> beryl.with_logging(beryl.logging_config(
        level: beryl.DebugLevel,
        include_payloads: False,
      ))
    })

  let selector = test_helper.begin_capture()

  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  let _diff = app_test_helper.recv(frames)
  let _snapshot = app_test_helper.recv(frames)

  let _ = beryl.stop(channels)

  let logs = drain_captured_logs(selector)
  logs
  |> list.any(fn(l) {
    l.message == "Presence cleanup dispatched: runtime stopping"
  })
  |> should.be_true
  logs
  |> list.any(fn(l) { l.message == "Presence cleanup failed: not acknowledged" })
  |> should.be_false

  test_helper.stop_capture()
}

/// A disconnect that arrives while a track is in flight is queued behind
/// it, so the socket first completes the track and then tears down —
/// leaving no tracked entry behind and emitting no duplicate diffs.
pub fn disconnect_while_track_is_pending_leaves_no_presence_test() -> Nil {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let handle = start_gated_presence(gate)
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let watcher = app_test_helper.connect(channels, "watcher")
  app_test_helper.join(channels, "watcher", "room:a", "jr-w", "r-w")
  let _watcher_reply = app_test_helper.recv(watcher)
  let _watcher_diff = app_test_helper.recv(watcher)
  let _watcher_snapshot = app_test_helper.recv(watcher)
  presence_count(handle, "room:a") |> should.equal(1)

  let frames = app_test_helper.connect(channels, "s1")
  arm(gate)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  await_entered(entered)

  transport.socket_disconnected(channels, "s1")
  release(gate)

  // The watcher sees s1 join and then leave, in that order, once each.
  let join_diff = app_test_helper.recv(watcher)
  join_diff |> string.contains("\"joins\"") |> should.be_true
  join_diff |> string.contains("user:s1") |> should.be_true
  let _join_snapshot = app_test_helper.recv(watcher)
  let leave_diff = app_test_helper.recv(watcher)
  leave_diff |> string.contains("user:s1") |> should.be_true
  count_occurrences(leave_diff, "user:s1") |> should.equal(1)
  process.receive(events, 500) |> should.equal(Ok("closed:room:a"))

  // Nothing of s1's survives, and nothing resurrects it.
  test_helper.wait_until(
    fn() { presence_count(handle, "room:a") == 1 },
    2000,
    20,
  )
  let assert [entry] = presence_entries(handle, "room:a")
  entry.key |> should.equal("user:watcher")
  app_test_helper.recv_none(watcher)
}

/// Two mutations in one effect list park the socket twice. Work queued
/// behind the first must not slip in between them: the whole list still
/// reaches the wire before anything that arrived while it was parked.
pub fn second_mutation_keeps_queued_work_waiting_test() -> Nil {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let handle = start_gated_presence(gate)
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let frames = app_test_helper.connect(channels, "s1")
  arm(gate)
  app_test_helper.join(channels, "s1", "flip:a", "jr-1", "r-1")
  app_test_helper.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  await_entered(entered)

  app_test_helper.push(channels, "s1", "flip:a", "echo", "r-2")
  release(gate)

  // Both diffs and the snapshot land first, in list order.
  let join_diff = app_test_helper.recv(frames)
  join_diff |> string.contains("presence_diff") |> should.be_true
  join_diff |> string.contains("\"leaves\":{}") |> should.be_true
  let leave_diff = app_test_helper.recv(frames)
  leave_diff |> string.contains("presence_diff") |> should.be_true
  leave_diff |> string.contains("\"joins\":{}") |> should.be_true
  let snapshot = app_test_helper.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  // Only then the message that was queued while the socket was parked.
  app_test_helper.recv(frames) |> string.contains("echoed") |> should.be_true
  presence_count(handle, "flip:a") |> should.equal(0)
}

/// The public synchronous API is unchanged: a track is visible to the very
/// next read, and so is an untrack.
pub fn public_presence_api_keeps_read_after_write_test() -> Nil {
  let assert Ok(handle) = presence.start(presence.default_config("node1"))
  let ref = presence.track(handle, "room:a", "user:1", "s1", meta("online"))
  presence_count(handle, "room:a") |> should.equal(1)
  let assert [entry] = presence_entries(handle, "room:a")
  entry.session_id |> should.equal("s1")
  presence_metas(handle, "room:a", "user:1")
  |> list.length
  |> should.equal(1)

  presence.untrack(handle, ref)
  presence_count(handle, "room:a") |> should.equal(0)
  presence_entries(handle, "room:a") |> should.equal([])

  let _second = presence.track(handle, "room:b", "user:1", "s1", meta("online"))
  presence.untrack_all(handle, "s1")
  presence_count(handle, "room:b") |> should.equal(0)
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Drain every log captured so far into a list, so a test can assert on
/// presence/absence across the whole stream without risking a message
/// being consumed (and discarded) by an earlier, unrelated check.
fn drain_captured_logs(
  selector: process.Selector(test_helper.CapturedLog),
) -> List(test_helper.CapturedLog) {
  case process.selector_receive(selector, 300) {
    Ok(captured) -> [captured, ..drain_captured_logs(selector)]
    Error(Nil) -> []
  }
}

/// The single `phx_ref` under `joins`/`leaves` of a `presence_diff` frame.
fn phx_ref_of(frame: String, side: String) -> String {
  let assert Ok(refs) =
    json.parse(
      frame,
      decode.at(
        [4],
        decode.at(
          [side],
          decode.dict(
            decode.string,
            decode.at(
              ["metas"],
              decode.list(decode.at(["phx_ref"], decode.string)),
            ),
          ),
        ),
      ),
    )
  let assert [#(_key, [ref])] = dict.to_list(refs)
  ref
}

/// The `phx_ref` presence has actually stored for a topic's single entry.
fn stored_phx_ref(handle: presence.Presence, topic: String) -> String {
  let assert [entry] = presence_entries(handle, topic)
  let assert Ok(ref) =
    json.parse(
      json.to_string(entry.meta),
      decode.at(["phx_ref"], decode.string),
    )
  ref
}

fn count_occurrences(haystack: String, needle: String) -> Int {
  string.split(haystack, needle)
  |> list.length
  |> fn(count) { count - 1 }
}

fn presence_entries(
  tracker: presence.Presence,
  topic: String,
) -> List(presence.PresenceEntry) {
  let assert Ok(entries) = presence.list(tracker, topic)
  entries
}

fn presence_count(tracker: presence.Presence, topic: String) -> Int {
  let assert Ok(count) = presence.count(tracker, topic)
  count
}

fn presence_metas(
  tracker: presence.Presence,
  topic: String,
  key: String,
) -> List(#(String, json.Json)) {
  let assert Ok(metas) = presence.get_by_key(tracker, topic, key)
  metas
}
