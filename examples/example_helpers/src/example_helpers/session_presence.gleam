//// Example-local, ETS-backed session snapshots.
////
//// Mutations and counts use constant-time ETS operations, so app-side
//// dispatch never waits on another actor. A small publisher process enqueues
//// full snapshots through a normal Beryl broadcast after each mutation.

import beryl
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Selector, type Subject}
import gleam/json
import gleam/option.{type Option, None, Some}

const start_timeout_ms = 5000

const call_timeout_ms = 1000

pub opaque type Tracker {
  Tracker(pid: Pid, subject: Subject(Command), table: Dynamic)
}

type Command {
  Configure(sockets: beryl.Sockets, reply: Subject(Nil))
  TrackSnapshotIfBelow(
    topic: String,
    session_id: String,
    meta: json.Json,
    maximum: Int,
    reply: Subject(Option(json.Json)),
  )
  Publish(topic: String)
  Stop(reply: Subject(Nil))
}

type Event {
  Message(Command)
  OwnerDown
}

type State {
  State(sockets: Option(beryl.Sockets))
}

@external(erlang, "example_session_presence_ffi", "new_store")
fn new_store() -> Dynamic

@external(erlang, "example_session_presence_ffi", "track")
fn store_track(
  table: Dynamic,
  topic: String,
  session_id: String,
  meta: json.Json,
) -> Nil

@external(erlang, "example_session_presence_ffi", "untrack")
fn store_untrack(table: Dynamic, topic: String, session_id: String) -> Nil

@external(erlang, "example_session_presence_ffi", "count")
fn store_count(table: Dynamic, topic: String) -> Int

@external(erlang, "example_session_presence_ffi", "snapshot")
fn store_snapshot(table: Dynamic, topic: String) -> List(#(String, json.Json))

pub fn start() -> Tracker {
  let table = new_store()
  let ready = process.new_subject()
  let owner = process.self()
  let pid =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      let owner_monitor = process.monitor(owner)
      let selector =
        process.new_selector()
        |> process.select_map(subject, Message)
        |> process.select_specific_monitor(owner_monitor, fn(_) { OwnerDown })
      process.send(ready, subject)
      loop(selector, table, State(sockets: None))
    })
  let assert Ok(subject) = process.receive(ready, start_timeout_ms)
  Tracker(pid, subject, table)
}

pub fn configure(tracker: Tracker, sockets: beryl.Sockets) -> Nil {
  process.call(tracker.subject, call_timeout_ms, fn(reply) {
    Configure(sockets, reply)
  })
}

/// Stop the snapshot publisher and wait for it to terminate.
///
/// The publisher also monitors the process that called [`start`](#start), so
/// it cannot outlive an owner that exits without an explicit stop.
pub fn stop(tracker: Tracker) -> Nil {
  let monitor = process.monitor(tracker.pid)
  process.call(tracker.subject, call_timeout_ms, fn(reply) { Stop(reply) })
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
  let assert Ok(Nil) = process.selector_receive(selector, call_timeout_ms)
  Nil
}

/// Whether the snapshot publisher is still running.
pub fn is_running(tracker: Tracker) -> Bool {
  process.is_alive(tracker.pid)
}

pub fn track(
  tracker: Tracker,
  topic: String,
  session_id: String,
  meta: json.Json,
) -> Nil {
  store_track(tracker.table, topic, session_id, meta)
  process.send(tracker.subject, Publish(topic))
}

/// Track a session and return the current roster without publishing it.
///
/// Join handlers can broadcast this snapshot in their ordered accept-time
/// actions, after the runtime has indexed the joining socket.
pub fn track_snapshot(
  tracker: Tracker,
  topic: String,
  session_id: String,
  meta: json.Json,
) -> json.Json {
  store_track(tracker.table, topic, session_id, meta)
  json.object(store_snapshot(tracker.table, topic))
}

/// Atomically track a session when the topic is below `maximum`.
///
/// The tracker actor serializes the count and insert so concurrent socket
/// joins cannot oversubscribe a bounded room.
pub fn track_snapshot_if_below(
  tracker: Tracker,
  topic: String,
  session_id: String,
  meta: json.Json,
  maximum: Int,
) -> Option(json.Json) {
  process.call(tracker.subject, call_timeout_ms, fn(reply) {
    TrackSnapshotIfBelow(topic, session_id, meta, maximum, reply)
  })
}

pub fn untrack(tracker: Tracker, topic: String, session_id: String) -> Nil {
  store_untrack(tracker.table, topic, session_id)
  process.send(tracker.subject, Publish(topic))
}

pub fn count(tracker: Tracker, topic: String) -> Int {
  store_count(tracker.table, topic)
}

fn loop(selector: Selector(Event), table: Dynamic, state: State) -> Nil {
  case process.selector_receive_forever(selector) {
    Message(Configure(sockets, reply)) -> {
      process.send(reply, Nil)
      loop(selector, table, State(sockets: Some(sockets)))
    }
    Message(TrackSnapshotIfBelow(topic, session_id, meta, maximum, reply)) -> {
      let result = case store_count(table, topic) < maximum {
        True -> {
          store_track(table, topic, session_id, meta)
          Some(json.object(store_snapshot(table, topic)))
        }
        False -> None
      }
      process.send(reply, result)
      loop(selector, table, state)
    }
    Message(Publish(topic)) -> {
      publish(state.sockets, topic, store_snapshot(table, topic))
      loop(selector, table, state)
    }
    Message(Stop(reply)) -> {
      process.send(reply, Nil)
    }
    OwnerDown -> {
      Nil
    }
  }
}

fn publish(
  sockets: Option(beryl.Sockets),
  topic: String,
  sessions: List(#(String, json.Json)),
) -> Nil {
  case sockets {
    Some(sockets) ->
      beryl.broadcast(sockets, topic, "presence_list", json.object(sessions))
    None -> Nil
  }
}
