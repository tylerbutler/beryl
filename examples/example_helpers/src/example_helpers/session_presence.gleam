//// Example-local, actor-owned session snapshots.
////
//// App-side dispatch sends mutations to this actor without blocking the
//// shared Beryl runtime. The actor publishes full snapshots by enqueueing a
//// normal Beryl broadcast, which runs after the runtime turn that scheduled
//// the mutation.

import beryl
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result

const start_timeout_ms = 5000

const call_timeout_ms = 1000

pub opaque type Tracker {
  Tracker(subject: Subject(Command))
}

type Command {
  Configure(sockets: beryl.Sockets, reply: Subject(Nil))
  Track(topic: String, session_id: String, meta: json.Json)
  Untrack(topic: String, session_id: String)
  Count(topic: String, reply: Subject(Int))
}

type State {
  State(
    sockets: Option(beryl.Sockets),
    topics: Dict(String, Dict(String, json.Json)),
  )
}

pub fn start() -> Tracker {
  let ready = process.new_subject()
  let _pid =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      loop(subject, State(sockets: None, topics: dict.new()))
    })
  let assert Ok(subject) = process.receive(ready, start_timeout_ms)
  Tracker(subject)
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
  process.send(tracker.subject, Track(topic, session_id, meta))
}

pub fn untrack(tracker: Tracker, topic: String, session_id: String) -> Nil {
  process.send(tracker.subject, Untrack(topic, session_id))
}

pub fn count(tracker: Tracker, topic: String) -> Int {
  process.call(tracker.subject, call_timeout_ms, fn(reply) {
    Count(topic, reply)
  })
}

fn loop(subject: Subject(Command), state: State) -> Nil {
  let next = case process.receive_forever(subject) {
    Configure(sockets, reply) -> {
      process.send(reply, Nil)
      State(..state, sockets: Some(sockets))
    }
    Track(topic, session_id, meta) -> {
      let sessions =
        dict.get(state.topics, topic)
        |> result.unwrap(dict.new())
        |> dict.insert(session_id, meta)
      publish(state.sockets, topic, sessions)
      State(..state, topics: dict.insert(state.topics, topic, sessions))
    }
    Untrack(topic, session_id) -> {
      let sessions =
        dict.get(state.topics, topic)
        |> result.unwrap(dict.new())
        |> dict.delete(session_id)
      publish(state.sockets, topic, sessions)
      let topics = case dict.is_empty(sessions) {
        True -> dict.delete(state.topics, topic)
        False -> dict.insert(state.topics, topic, sessions)
      }
      State(..state, topics: topics)
    }
    Count(topic, reply) -> {
      let count =
        dict.get(state.topics, topic)
        |> result.map(dict.size)
        |> result.unwrap(0)
      process.send(reply, count)
      state
    }
  }
  loop(subject, next)
}

fn publish(
  sockets: Option(beryl.Sockets),
  topic: String,
  sessions: Dict(String, json.Json),
) -> Nil {
  case sockets {
    Some(sockets) ->
      beryl.broadcast(
        sockets,
        topic,
        "presence_list",
        json.object(dict.to_list(sessions)),
      )
    None -> Nil
  }
}
