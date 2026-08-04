//// Asynchronous presence effects: the runtime never blocks its actor on a
//// presence mutation. The socket that issued one is parked (its later
//// messages queued, its remaining effects held) until presence
//// acknowledges; every other socket, broadcast, and heartbeat keeps being
//// served.
////
//// Delays are produced with a gate actor that the presence `on_diff`
//// callback calls into, so every "while the mutation is in flight" step is
//// a deterministic handshake rather than a sleep.

import app_test_helpers as h
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
import test_helpers

pub fn main() {
  gleeunit.main()
}

// ── Gate ────────────────────────────────────────────────────────────────────

/// A one-shot barrier the presence actor blocks on from inside `on_diff`.
///
/// `Arm` primes it for exactly one diff. The next diff after that reports
/// on `entered` and blocks the presence actor until `Release`; every other
/// diff passes straight through. Nothing here sleeps: the test knows the
/// mutation is genuinely in flight because `entered` fired.
type GateMsg {
  Arm
  Enter(reply: Subject(Nil))
  Release
}

type GateState {
  GateState(armed: Bool, waiting: Option(Subject(Nil)), entered: Subject(Nil))
}

fn start_gate(entered: Subject(Nil)) -> Subject(GateMsg) {
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
fn arm(gate: Subject(GateMsg)) -> Nil {
  process.send(gate, Arm)
}

fn await_entered(entered: Subject(Nil)) -> Nil {
  let assert Ok(Nil) = process.receive(entered, 2000)
  Nil
}

fn release(gate: Subject(GateMsg)) -> Nil {
  process.send(gate, Release)
}

fn start_gated_presence(gate: Subject(GateMsg)) -> presence.Presence {
  let assert Ok(p) =
    presence.start(
      presence.default_config("node1")
      |> presence.with_on_diff(fn(_diff) { process.call(gate, 5000, Enter) }),
    )
  p
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
) -> Next(String, Nil) {
  case event {
    Join(topic, _payload, ref) ->
      case
        string.starts_with(topic, "room:"),
        string.starts_with(topic, "flip:")
      {
        True, _ ->
          Next(model, [
            AcceptJoin(ref, None),
            PresenceTrack(topic, "user:" <> model, meta("online")),
            BroadcastPresence(topic, "presence_list", encode_users),
          ])
        // Two mutations in one list: the socket parks twice, and nothing
        // queued behind it may slip in between them.
        _, True ->
          Next(model, [
            AcceptJoin(ref, None),
            PresenceTrack(topic, "user:" <> model, meta("online")),
            PresenceUntrack(topic, "user:" <> model),
            BroadcastPresence(topic, "presence_list", encode_users),
          ])
        False, False -> Next(model, [AcceptJoin(ref, None)])
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
      Next(model, [])
    }
    _ -> Next(model, [])
  }
}

fn start_system(
  handle: presence.Presence,
  events: Subject(String),
  configure: fn(beryl.Config) -> beryl.Config,
) -> beryl.Sockets {
  let assert Ok(channels) =
    h.start_app(
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
pub fn pending_track_does_not_block_other_sockets_test() {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let handle = start_gated_presence(gate)
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let slow_frames = h.connect(channels, "slow")
  arm(gate)
  h.join(channels, "slow", "room:a", "jr-1", "r-1")
  // The join reply is written before the track effect, so it lands even
  // though the socket is about to park.
  h.recv(slow_frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
  await_entered(entered)

  // With `slow` parked, another socket still joins, gets replies, and gets
  // heartbeat answers.
  let other_frames = h.connect(channels, "other")
  h.join(channels, "other", "plain:a", "jr-2", "r-2")
  h.recv(other_frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
  h.push(channels, "other", "plain:a", "ping", "r-3")
  process.receive(events, 500) |> should.equal(Ok("ping"))
  h.route(channels, "other", "[null,\"hb-1\",\"phoenix\",\"heartbeat\",{}]")
  h.recv(other_frames) |> string.contains("hb-1") |> should.be_true

  release(gate)

  // The parked socket then finishes its own effect list, in order.
  h.recv(slow_frames) |> string.contains("presence_diff") |> should.be_true
  h.recv(slow_frames) |> string.contains("presence_list") |> should.be_true
}

/// A parked socket's later inbound events are queued, not dropped or
/// reordered, and are delivered once the mutation is acknowledged.
pub fn queued_messages_are_delivered_in_arrival_order_test() {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let handle = start_gated_presence(gate)
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let frames = h.connect(channels, "s1")
  arm(gate)
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = h.recv(frames)
  await_entered(entered)

  h.push(channels, "s1", "room:a", "one", "r-2")
  h.push(channels, "s1", "room:a", "two", "r-3")
  h.push(channels, "s1", "room:a", "three", "r-4")

  // Queued, not dispatched: the app has not seen them yet.
  process.receive(events, 200) |> should.be_error

  release(gate)

  process.receive(events, 1000) |> should.equal(Ok("one"))
  process.receive(events, 1000) |> should.equal(Ok("two"))
  process.receive(events, 1000) |> should.equal(Ok("three"))
}

/// `[PresenceTrack, BroadcastPresence]` — the snapshot reflects the track
/// and the diff is written first.
pub fn track_then_snapshot_keeps_wire_order_test() {
  let assert Ok(handle) = presence.start(presence.default_config("node1"))
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  h.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true

  let diff = h.recv(frames)
  diff |> string.contains("presence_diff") |> should.be_true
  diff |> string.contains("\"joins\"") |> should.be_true

  let snapshot = h.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  snapshot |> string.contains("\"s1\"") |> should.be_true
  snapshot |> string.contains("online") |> should.be_true
}

/// `[PresenceUntrack, BroadcastPresence]` — the snapshot reflects the
/// untrack, and the leave diff still comes first.
pub fn untrack_then_snapshot_keeps_wire_order_test() {
  let assert Ok(handle) = presence.start(presence.default_config("node1"))
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = h.recv(frames)
  let _join_diff = h.recv(frames)
  let _join_snapshot = h.recv(frames)

  h.push(channels, "s1", "room:a", "untrack", "r-2")

  let diff = h.recv(frames)
  diff |> string.contains("presence_diff") |> should.be_true
  diff |> string.contains("\"leaves\"") |> should.be_true
  diff |> string.contains("user:s1") |> should.be_true

  let snapshot = h.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  snapshot |> string.contains("\"s1\"") |> should.be_false
  presence.count(handle, "room:a") |> should.equal(0)
}

/// Re-tracking a key is one atomic replacement: one diff frame carrying
/// both the leave and the join, no empty snapshot in between, and the
/// leave's `phx_ref` is exactly the ref the previous join published.
pub fn replacement_is_atomic_and_shares_phx_refs_test() {
  let assert Ok(handle) = presence.start(presence.default_config("node1"))
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = h.recv(frames)
  let join_diff = h.recv(frames)
  let _join_snapshot = h.recv(frames)
  let first_ref = phx_ref_of(join_diff, "joins")
  // The published ref is the one actually stored.
  first_ref |> should.equal(stored_phx_ref(handle, "room:a"))

  h.push(channels, "s1", "room:a", "promote", "r-2")

  // Exactly one diff frame, carrying the whole leave+join transition.
  let replace_diff = h.recv(frames)
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
  presence.count(handle, "room:a") |> should.equal(1)
  let snapshot = h.recv(frames)
  snapshot |> string.contains("away") |> should.be_true
  snapshot |> string.contains("online") |> should.be_false
  // No second diff: the replacement was not a separate untrack + track.
  h.recv_none(frames)
}

/// Closing a topic untracks every key the socket still held as one batch:
/// one aggregate leave diff, no duplicates.
pub fn topic_close_emits_one_aggregate_leave_diff_test() {
  let assert Ok(handle) = presence.start(presence.default_config("node1"))
  let assert Ok(channels) =
    h.start_app(
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
          _ -> Next(model, [])
        }
      },
    )

  let watcher = h.connect(channels, "watcher")
  h.join(channels, "watcher", "room:a", "jr-w", "r-w")
  let _watcher_reply = h.recv(watcher)
  // The watcher's own three join diffs.
  let _own_one = h.recv(watcher)
  let _own_two = h.recv(watcher)
  let _own_three = h.recv(watcher)

  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = h.recv(frames)
  // s1 tracks three keys: three separate join diffs, one per effect.
  let _one = h.recv(watcher)
  let _two = h.recv(watcher)
  let _three = h.recv(watcher)
  presence.count(handle, "room:a") |> should.equal(6)

  h.route(channels, "s1", "[\"jr-1\",\"r-2\",\"room:a\",\"phx_leave\",{}]")

  // One diff for the whole topic, naming each of s1's keys exactly once.
  let leave_diff = h.recv(watcher)
  leave_diff |> string.contains("presence_diff") |> should.be_true
  leave_diff |> string.contains("\"joins\":{}") |> should.be_true
  count_occurrences(leave_diff, "s1:a") |> should.equal(1)
  count_occurrences(leave_diff, "s1:b") |> should.equal(1)
  count_occurrences(leave_diff, "s1:c") |> should.equal(1)
  h.recv_none(watcher)

  test_helpers.wait_until(
    fn() { presence.count(handle, "room:a") == 3 },
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
pub fn unacknowledged_mutation_times_out_and_late_ack_is_ignored_test() {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let handle = start_gated_presence(gate)
  let events = process.new_subject()
  let channels =
    start_system(handle, events, beryl.with_presence_op_timeout(_, 150))

  let frames = h.connect(channels, "s1")
  arm(gate)
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  h.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
  await_entered(entered)

  // After the timeout the socket resumes: no join diff was broadcast (the
  // track was never confirmed), but the snapshot effect after it still
  // runs.
  let snapshot = h.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  snapshot |> string.contains("presence_diff") |> should.be_false

  // The socket is live again straight away, not waiting on anything.
  h.push(channels, "s1", "room:a", "ping", "r-2")
  process.receive(events, 1000) |> should.equal(Ok("ping"))

  // The acknowledgement finally arrives, for an operation nobody is
  // waiting on any more: dropped, with no extra frame and no crash.
  release(gate)
  h.recv_none(frames)
  h.push(channels, "s1", "room:a", "pong", "r-3")
  process.receive(events, 1000) |> should.equal(Ok("pong"))
}

/// A disconnect that arrives while a track is in flight is queued behind
/// it, so the socket first completes the track and then tears down —
/// leaving no tracked entry behind and emitting no duplicate diffs.
pub fn disconnect_while_track_is_pending_leaves_no_presence_test() {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let handle = start_gated_presence(gate)
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let watcher = h.connect(channels, "watcher")
  h.join(channels, "watcher", "room:a", "jr-w", "r-w")
  let _watcher_reply = h.recv(watcher)
  let _watcher_diff = h.recv(watcher)
  let _watcher_snapshot = h.recv(watcher)
  presence.count(handle, "room:a") |> should.equal(1)

  let frames = h.connect(channels, "s1")
  arm(gate)
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = h.recv(frames)
  await_entered(entered)

  transport.socket_disconnected(channels, "s1")
  release(gate)

  // The watcher sees s1 join and then leave, in that order, once each.
  let join_diff = h.recv(watcher)
  join_diff |> string.contains("\"joins\"") |> should.be_true
  join_diff |> string.contains("user:s1") |> should.be_true
  let _join_snapshot = h.recv(watcher)
  let leave_diff = h.recv(watcher)
  leave_diff |> string.contains("user:s1") |> should.be_true
  count_occurrences(leave_diff, "user:s1") |> should.equal(1)
  process.receive(events, 500) |> should.equal(Ok("closed:room:a"))

  // Nothing of s1's survives, and nothing resurrects it.
  test_helpers.wait_until(
    fn() { presence.count(handle, "room:a") == 1 },
    2000,
    20,
  )
  let assert [entry] = presence.list(handle, "room:a")
  entry.key |> should.equal("user:watcher")
  h.recv_none(watcher)
}

/// Two mutations in one effect list park the socket twice. Work queued
/// behind the first must not slip in between them: the whole list still
/// reaches the wire before anything that arrived while it was parked.
pub fn second_mutation_keeps_queued_work_waiting_test() {
  let entered = process.new_subject()
  let gate = start_gate(entered)
  let handle = start_gated_presence(gate)
  let events = process.new_subject()
  let channels = start_system(handle, events, identity_config)

  let frames = h.connect(channels, "s1")
  arm(gate)
  h.join(channels, "s1", "flip:a", "jr-1", "r-1")
  h.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
  await_entered(entered)

  h.push(channels, "s1", "flip:a", "echo", "r-2")
  release(gate)

  // Both diffs and the snapshot land first, in list order.
  let join_diff = h.recv(frames)
  join_diff |> string.contains("presence_diff") |> should.be_true
  join_diff |> string.contains("\"leaves\":{}") |> should.be_true
  let leave_diff = h.recv(frames)
  leave_diff |> string.contains("presence_diff") |> should.be_true
  leave_diff |> string.contains("\"joins\":{}") |> should.be_true
  let snapshot = h.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  // Only then the message that was queued while the socket was parked.
  h.recv(frames) |> string.contains("echoed") |> should.be_true
  presence.count(handle, "flip:a") |> should.equal(0)
}

/// The public synchronous API is unchanged: a track is visible to the very
/// next read, and so is an untrack.
pub fn public_presence_api_keeps_read_after_write_test() {
  let assert Ok(handle) = presence.start(presence.default_config("node1"))
  let ref = presence.track(handle, "room:a", "user:1", "s1", meta("online"))
  presence.count(handle, "room:a") |> should.equal(1)
  let assert [entry] = presence.list(handle, "room:a")
  entry.session_id |> should.equal("s1")
  presence.get_by_key(handle, "room:a", "user:1")
  |> list.length
  |> should.equal(1)

  presence.untrack(handle, ref)
  presence.count(handle, "room:a") |> should.equal(0)
  presence.list(handle, "room:a") |> should.equal([])

  let _second = presence.track(handle, "room:b", "user:1", "s1", meta("online"))
  presence.untrack_all(handle, "s1")
  presence.count(handle, "room:b") |> should.equal(0)
}

// ── Helpers ─────────────────────────────────────────────────────────────────

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
  let assert [entry] = presence.list(handle, topic)
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
