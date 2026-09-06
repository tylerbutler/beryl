//// Absolute scenario expiry actor for the beryl demo service.
////
//// The actor schedules a single deferred `ExpireTopic` message when a topic is
//// first tracked. When the timer fires it runs the expiry callback that every
//// tracked socket registered, marks the topic as expired for future rejoins,
//// and schedules a `ForgetTopic` sweep to bound the tombstone set.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}

/// Opaque handle for a running expiry actor.
pub opaque type Expiry {
  Expiry(subject: Subject(Message))
}

/// Messages handled by the expiry actor.
type Message {
  Track(topic: String, socket_id: String, on_expire: fn() -> Nil)
  Untrack(topic: String, socket_id: String)
  IsExpired(topic: String, reply: Subject(Bool))
  ExpireTopic(String)
  ForgetTopic(String)
  Stop(reply: Subject(Nil))
}

/// Internal state for the expiry actor.
///
/// `sockets` maps a topic to the expiry callback of every socket tracked on
/// it, keyed by socket id.
type State {
  State(
    ttl_ms: Int,
    self: Subject(Message),
    sockets: Dict(String, Dict(String, fn() -> Nil)),
    scheduled: Set(String),
    expired: Set(String),
  )
}

/// Start the expiry actor with an absolute TTL in milliseconds.
pub fn start(ttl_ms: Int) -> Result(Expiry, actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    State(
      ttl_ms: ttl_ms,
      self: subject,
      sockets: dict.new(),
      scheduled: set.new(),
      expired: set.new(),
    )
    |> actor.initialised
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { Expiry(subject: started.data) })
}

/// Track that `socket_id` joined `topic`, registering the callback to run
/// when the topic expires.
///
/// On the first `track` for a topic the actor schedules an `ExpireTopic`
/// message after `ttl_ms`. Subsequent tracks add to the socket list without
/// resetting the timer (the TTL is absolute). Each callback runs at most once
/// per socket per topic expiry.
pub fn track(
  expiry: Expiry,
  topic: String,
  socket_id: String,
  on_expire: fn() -> Nil,
) -> Nil {
  process.send(expiry.subject, Track(topic:, socket_id:, on_expire:))
}

/// Remove `socket_id` from `topic`'s tracked-sockets list.
pub fn untrack(expiry: Expiry, topic: String, socket_id: String) -> Nil {
  process.send(expiry.subject, Untrack(topic:, socket_id:))
}

/// Check whether `topic` has already fired its absolute expiry.
pub fn is_expired(expiry: Expiry, topic: String) -> Bool {
  process.call(expiry.subject, 5000, fn(reply) { IsExpired(topic:, reply:) })
}

/// Stop the expiry actor synchronously.
///
/// Blocks until the actor has processed the stop message, which guarantees no
/// further `ExpireTopic` or `ForgetTopic` timer messages already queued behind
/// the stop can run a callback after this function returns.
pub fn stop(expiry: Expiry) -> Nil {
  process.call(expiry.subject, 5000, fn(reply) { Stop(reply:) })
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Track(topic, socket_id, on_expire) ->
      handle_track(state, topic, socket_id, on_expire)

    Untrack(topic, socket_id) -> handle_untrack(state, topic, socket_id)

    IsExpired(topic, reply) -> {
      process.send(reply, set.contains(state.expired, topic))
      actor.continue(state)
    }

    ExpireTopic(topic) -> handle_expire(state, topic)

    ForgetTopic(topic) ->
      actor.continue(
        State(
          ..state,
          scheduled: set.delete(state.scheduled, topic),
          expired: set.delete(state.expired, topic),
        ),
      )

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
  on_expire: fn() -> Nil,
) -> actor.Next(State, Message) {
  let tracked =
    dict.get(state.sockets, topic)
    |> result.unwrap(dict.new())
    |> dict.insert(socket_id, on_expire)
  let state =
    State(..state, sockets: dict.insert(state.sockets, topic, tracked))
  case set.contains(state.scheduled, topic) {
    True -> actor.continue(state)
    False -> {
      let _timer =
        process.send_after(state.self, state.ttl_ms, ExpireTopic(topic))
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
    Ok(tracked) -> {
      let remaining = dict.delete(tracked, socket_id)
      let sockets = case dict.is_empty(remaining) {
        True -> dict.delete(state.sockets, topic)
        False -> dict.insert(state.sockets, topic, remaining)
      }
      actor.continue(State(..state, sockets: sockets))
    }
  }
}

fn handle_expire(state: State, topic: String) -> actor.Next(State, Message) {
  dict.get(state.sockets, topic)
  |> result.unwrap(dict.new())
  |> dict.each(fn(_socket_id, on_expire) { on_expire() })
  let _timer = process.send_after(state.self, state.ttl_ms, ForgetTopic(topic))
  actor.continue(
    State(
      ..state,
      sockets: dict.delete(state.sockets, topic),
      expired: set.insert(state.expired, topic),
    ),
  )
}
