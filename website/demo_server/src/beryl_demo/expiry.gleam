//// Absolute scenario expiry actor for the beryl demo service.
////
//// The actor schedules a single deferred `ExpireTopic` message when a topic is
//// first tracked. When the timer fires it invokes the configured expiry
//// callback for every tracked socket, marks the topic as expired for future
//// rejoins, and schedules a `ForgetTopic` sweep to bound the tombstone set.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/set.{type Set}

/// Opaque handle for a running expiry actor.
pub opaque type Expiry {
  Expiry(subject: Subject(Message))
}

/// Messages handled by the expiry actor.
type Message {
  Initialize(callback: fn(String, String) -> Nil)
  Track(topic: String, socket_id: String)
  Untrack(topic: String, socket_id: String)
  IsExpired(topic: String, reply: Subject(Bool))
  ExpireTopic(String)
  ForgetTopic(String)
  Stop(reply: Subject(Nil))
}

/// Internal state for the expiry actor.
type State {
  State(
    ttl_ms: Int,
    self: Option(Subject(Message)),
    expire_channel: Option(fn(String, String) -> Nil),
    sockets: Dict(String, List(String)),
    scheduled: Set(String),
    expired: Set(String),
  )
}

/// Start the expiry actor with an absolute TTL in milliseconds.
pub fn start(ttl_ms: Int) -> Result(Expiry, actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let state =
      State(
        ttl_ms: ttl_ms,
        self: Some(subject),
        expire_channel: None,
        sockets: dict.new(),
        scheduled: set.new(),
        expired: set.new(),
      )
    actor.initialised(state)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> result_map_start
}

fn result_map_start(
  result: Result(actor.Started(Subject(Message)), actor.StartError),
) -> Result(Expiry, actor.StartError) {
  case result {
    Ok(started) -> Ok(Expiry(subject: started.data))
    Error(error) -> Error(error)
  }
}

/// Install the callback invoked when a tracked topic expires.
///
/// The callback receives `(socket_id, topic)` for each socket that was tracked
/// on the expiring topic. Called at most once per socket per topic expiry.
pub fn initialize(expiry: Expiry, callback: fn(String, String) -> Nil) -> Nil {
  process.send(expiry.subject, Initialize(callback))
}

/// Track that `socket_id` joined `topic`.
///
/// On the first `track` for a topic the actor schedules an `ExpireTopic`
/// message after `ttl_ms`. Subsequent tracks add to the socket list without
/// resetting the timer (the TTL is absolute).
pub fn track(expiry: Expiry, topic: String, socket_id: String) -> Nil {
  process.send(expiry.subject, Track(topic: topic, socket_id: socket_id))
}

/// Remove `socket_id` from `topic`'s tracked-sockets list.
pub fn untrack(expiry: Expiry, topic: String, socket_id: String) -> Nil {
  process.send(expiry.subject, Untrack(topic: topic, socket_id: socket_id))
}

/// Check whether `topic` has already fired its absolute expiry.
pub fn is_expired(expiry: Expiry, topic: String) -> Bool {
  process.call(expiry.subject, 5000, fn(reply) {
    IsExpired(topic: topic, reply: reply)
  })
}

/// Stop the expiry actor synchronously.
///
/// Blocks until the actor has processed the stop message, which guarantees no
/// further `ExpireTopic` or `ForgetTopic` timer messages already queued behind
/// the stop can invoke the callback after this function returns.
pub fn stop(expiry: Expiry) -> Nil {
  process.call(expiry.subject, 5000, fn(reply) { Stop(reply: reply) })
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Initialize(callback) ->
      actor.continue(State(..state, expire_channel: Some(callback)))

    Track(topic, socket_id) -> handle_track(state, topic, socket_id)

    Untrack(topic, socket_id) -> handle_untrack(state, topic, socket_id)

    IsExpired(topic, reply) -> {
      process.send(reply, set.contains(state.expired, topic))
      actor.continue(state)
    }

    ExpireTopic(topic) -> handle_expire(state, topic)

    ForgetTopic(topic) -> {
      let scheduled = set.delete(state.scheduled, topic)
      let expired = set.delete(state.expired, topic)
      actor.continue(State(..state, scheduled: scheduled, expired: expired))
    }

    Stop(reply) -> {
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn handle_track(
  state: State,
  topic: String,
  socket_id: String,
) -> actor.Next(State, Message) {
  let existing = case dict.get(state.sockets, topic) {
    Ok(sockets) -> sockets
    Error(Nil) -> []
  }
  let sockets = case list.contains(existing, socket_id) {
    True -> existing
    False -> [socket_id, ..existing]
  }
  let state =
    State(..state, sockets: dict.insert(state.sockets, topic, sockets))
  case set.contains(state.scheduled, topic) {
    True -> actor.continue(state)
    False -> {
      case state.self {
        Some(self) -> {
          let _timer =
            process.send_after(self, state.ttl_ms, ExpireTopic(topic))
          Nil
        }
        None -> Nil
      }
      actor.continue(
        State(..state, scheduled: set.insert(state.scheduled, topic)),
      )
    }
  }
}

fn handle_untrack(
  state: State,
  topic: String,
  socket_id: String,
) -> actor.Next(State, Message) {
  case dict.get(state.sockets, topic) {
    Error(Nil) -> actor.continue(state)
    Ok(sockets) -> {
      let remaining = list.filter(sockets, fn(id) { id != socket_id })
      let sockets = case remaining {
        [] -> dict.delete(state.sockets, topic)
        _ -> dict.insert(state.sockets, topic, remaining)
      }
      actor.continue(State(..state, sockets: sockets))
    }
  }
}

fn handle_expire(state: State, topic: String) -> actor.Next(State, Message) {
  let sockets = case dict.get(state.sockets, topic) {
    Ok(sockets) -> sockets
    Error(Nil) -> []
  }
  case state.expire_channel {
    Some(callback) ->
      list.each(sockets, fn(socket_id) { callback(socket_id, topic) })
    None -> Nil
  }
  case state.self {
    Some(self) -> {
      let _timer = process.send_after(self, state.ttl_ms, ForgetTopic(topic))
      Nil
    }
    None -> Nil
  }
  actor.continue(
    State(
      ..state,
      sockets: dict.delete(state.sockets, topic),
      expired: set.insert(state.expired, topic),
    ),
  )
}
