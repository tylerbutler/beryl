//// Example-local, ETS-backed session snapshots.
////
//// Mutations and counts use constant-time ETS operations, so app-side
//// dispatch never waits on another actor. A small publisher process enqueues
//// full snapshots through a normal Beryl broadcast after each mutation.

import beryl
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option.{type Option, None, Some}

const start_timeout_ms = 5000

const call_timeout_ms = 1000

pub opaque type Tracker {
  Tracker(subject: Subject(Command), table: Dynamic)
}

type Command {
  Configure(sockets: beryl.Sockets, reply: Subject(Nil))
  Publish(topic: String)
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
  let _pid =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      loop(subject, table, State(sockets: None))
    })
  let assert Ok(subject) = process.receive(ready, start_timeout_ms)
  Tracker(subject, table)
}

pub fn configure(tracker: Tracker, sockets: beryl.Sockets) -> Nil {
  process.call(tracker.subject, call_timeout_ms, fn(reply) {
    Configure(sockets, reply)
  })
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

pub fn untrack(tracker: Tracker, topic: String, session_id: String) -> Nil {
  store_untrack(tracker.table, topic, session_id)
  process.send(tracker.subject, Publish(topic))
}

pub fn count(tracker: Tracker, topic: String) -> Int {
  store_count(tracker.table, topic)
}

fn loop(subject: Subject(Command), table: Dynamic, state: State) -> Nil {
  let next = case process.receive_forever(subject) {
    Configure(sockets, reply) -> {
      process.send(reply, Nil)
      State(sockets: Some(sockets))
    }
    Publish(topic) -> {
      publish(state.sockets, topic, store_snapshot(table, topic))
      state
    }
  }
  loop(subject, table, next)
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
