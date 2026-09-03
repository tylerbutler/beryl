//// Topic groups
////
//// Groups organize topics for broadcasts to several topics at once, such as
//// every channel in a team or a system-wide notification.
////
//// Groups are independent of the beryl runtime and run under your
//// application's supervision tree.
////
//// ## Example
////
//// ```gleam
//// let #(groups, groups_specification) = group.child_spec()
//// let assert Ok(_root) =
////   static_supervisor.new(static_supervisor.OneForOne)
////   |> static_supervisor.add(groups_specification)
////   |> static_supervisor.start()
//// let assert Ok(Nil) = group.create(groups, "team:engineering")
//// let assert Ok(Nil) = group.add(groups, "team:engineering", "room:frontend")
//// let assert Ok(Nil) = group.add(groups, "team:engineering", "room:backend")
//// group.broadcast(groups, channels, "team:engineering", "announce", payload)
//// ```

import beryl
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/set.{type Set}

/// A running groups instance.
///
/// This handle is opaque. Callers cannot forge the actor subject or depend
/// on its runtime representation.
///
/// ## Node affinity
///
/// The stable registered subject is resolved on the caller's node. Keep a
/// `Groups` handle on the node where its child specification runs. Calls from
/// another BEAM node cannot reach the owning actor. All public operations,
/// including `broadcast`, panic if the actor is unavailable or the call times
/// out.
pub opaque type Groups {
  Groups(subject: Subject(Message), call_timeout_ms: Int)
}

/// Configuration for starting a groups actor.
///
/// Build configs with `default_config` and the `with_*` functions.
pub opaque type Config {
  Config(call_timeout_ms: Int)
}

/// Errors from group operations.
pub type GroupError {
  /// The group already exists.
  GroupAlreadyExists(name: String)
  /// The group was not found.
  GroupNotFound(name: String)
}

/// Messages that the groups actor handles.
pub opaque type Message {
  Create(name: String, reply: Subject(Result(Nil, GroupError)))
  Delete(name: String, reply: Subject(Result(Nil, GroupError)))
  Add(
    group_name: String,
    topic: String,
    reply: Subject(Result(Nil, GroupError)),
  )
  Remove(
    group_name: String,
    topic: String,
    reply: Subject(Result(Nil, GroupError)),
  )
  GetTopics(group_name: String, reply: Subject(Result(Set(String), GroupError)))
  ListGroups(reply: Subject(List(String)))
}

/// Internal state
type State {
  State(groups: Dict(String, Set(String)))
}

/// Build a groups configuration with a 5-second actor call timeout.
pub fn default_config() -> Config {
  Config(call_timeout_ms: 5000)
}

/// Set the timeout for synchronous group operations, in milliseconds.
///
/// This applies to `create`, `delete`, `add`, `remove`, `topics`, and
/// `list_groups`. These functions panic if the actor does not reply within
/// this timeout.
pub fn with_call_timeout(_config: Config, timeout_ms: Int) -> Config {
  Config(call_timeout_ms: timeout_ms)
}

/// Build the supervised groups actor with the default configuration.
///
/// Add the returned child specification to your application's supervisor.
/// The returned handle is name-backed, so it reaches the replacement actor
/// after a supervised restart. Group definitions are in-memory state and are
/// reset by a restart.
pub fn child_spec() -> #(
  Groups,
  supervision.ChildSpecification(Subject(Message)),
) {
  child_spec_with_config(default_config())
}

/// Build the supervised groups actor with a custom configuration.
pub fn child_spec_with_config(
  config: Config,
) -> #(Groups, supervision.ChildSpecification(Subject(Message))) {
  let name = process.new_name("beryl_groups")
  #(
    Groups(
      subject: process.named_subject(name),
      call_timeout_ms: config.call_timeout_ms,
    ),
    supervision.worker(fn() { start_named(name) }),
  )
}

@internal
pub fn start() -> Result(Groups, actor.StartError) {
  let name = process.new_name("beryl_groups")
  start_named(name)
  |> result.map(fn(_started) {
    Groups(
      subject: process.named_subject(name),
      call_timeout_ms: default_config().call_timeout_ms,
    )
  })
}

fn start_named(
  name: process.Name(Message),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  build_groups()
  |> actor.named(name)
  |> actor.start
}

@internal
pub fn subject(groups: Groups) -> Subject(Message) {
  groups.subject
}

fn build_groups() -> actor.Builder(State, Message, Subject(Message)) {
  actor.new(State(groups: dict.new()))
  |> actor.on_message(handle_message)
}

/// Create a named group.
///
/// Panics if the groups actor is unavailable or does not reply within the
/// configured call timeout (5 seconds by default).
pub fn create(groups: Groups, name: String) -> Result(Nil, GroupError) {
  process.call(groups.subject, groups.call_timeout_ms, fn(reply) {
    Create(name, reply)
  })
}

/// Delete a group.
///
/// Panics if the groups actor is unavailable or does not reply within the
/// configured call timeout (5 seconds by default).
pub fn delete(groups: Groups, name: String) -> Result(Nil, GroupError) {
  process.call(groups.subject, groups.call_timeout_ms, fn(reply) {
    Delete(name, reply)
  })
}

/// Add a topic to a group.
///
/// Panics if the groups actor is unavailable or does not reply within the
/// configured call timeout (5 seconds by default).
pub fn add(
  groups: Groups,
  group_name: String,
  topic: String,
) -> Result(Nil, GroupError) {
  process.call(groups.subject, groups.call_timeout_ms, fn(reply) {
    Add(group_name, topic, reply)
  })
}

/// Remove a topic from a group.
///
/// Panics if the groups actor is unavailable or does not reply within the
/// configured call timeout (5 seconds by default).
pub fn remove(
  groups: Groups,
  group_name: String,
  topic: String,
) -> Result(Nil, GroupError) {
  process.call(groups.subject, groups.call_timeout_ms, fn(reply) {
    Remove(group_name, topic, reply)
  })
}

/// Return all topics in a group.
///
/// Panics if the groups actor is unavailable or does not reply within the
/// configured call timeout (5 seconds by default).
pub fn topics(
  groups: Groups,
  group_name: String,
) -> Result(Set(String), GroupError) {
  process.call(groups.subject, groups.call_timeout_ms, fn(reply) {
    GetTopics(group_name, reply)
  })
}

/// Return all group names.
///
/// Panics if the groups actor is unavailable or does not reply within the
/// configured call timeout (5 seconds by default).
pub fn list_groups(groups: Groups) -> List(String) {
  process.call(groups.subject, groups.call_timeout_ms, fn(reply) {
    ListGroups(reply)
  })
}

/// Broadcast a message to all topics in a group.
///
/// This function sends the message to each topic through `beryl.broadcast`.
/// The groups actor performs the topic lookup. The caller performs the
/// fan-out. If the group does not exist, this function does nothing.
///
/// Panics if the groups actor is unavailable or does not reply within the
/// configured call timeout.
pub fn broadcast(
  groups: Groups,
  channels: beryl.Sockets,
  group_name: String,
  event: String,
  payload: json.Json,
) -> Nil {
  case topics(groups, group_name) {
    Ok(topics) -> broadcast_to_topics(topics, channels, event, payload)
    Error(GroupAlreadyExists(_)) -> Nil
    Error(GroupNotFound(_)) -> Nil
  }
}

// ── Actor loop ──────────────────────────────────────────────────────────────

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Create(name, reply) -> {
      case dict.has_key(state.groups, name) {
        True -> {
          process.send(reply, Error(GroupAlreadyExists(name)))
          actor.continue(state)
        }
        False -> {
          let new_groups = dict.insert(state.groups, name, set.new())
          process.send(reply, Ok(Nil))
          actor.continue(State(groups: new_groups))
        }
      }
    }

    Delete(name, reply) -> {
      case dict.has_key(state.groups, name) {
        False -> {
          process.send(reply, Error(GroupNotFound(name)))
          actor.continue(state)
        }
        True -> {
          let new_groups = dict.delete(state.groups, name)
          process.send(reply, Ok(Nil))
          actor.continue(State(groups: new_groups))
        }
      }
    }

    Add(group_name, topic, reply) -> {
      case dict.get(state.groups, group_name) {
        Error(Nil) -> {
          process.send(reply, Error(GroupNotFound(group_name)))
          actor.continue(state)
        }
        Ok(topics) -> {
          let new_topics = set.insert(topics, topic)
          let new_groups = dict.insert(state.groups, group_name, new_topics)
          process.send(reply, Ok(Nil))
          actor.continue(State(groups: new_groups))
        }
      }
    }

    Remove(group_name, topic, reply) -> {
      case dict.get(state.groups, group_name) {
        Error(Nil) -> {
          process.send(reply, Error(GroupNotFound(group_name)))
          actor.continue(state)
        }
        Ok(topics) -> {
          let new_topics = set.delete(topics, topic)
          let new_groups = dict.insert(state.groups, group_name, new_topics)
          process.send(reply, Ok(Nil))
          actor.continue(State(groups: new_groups))
        }
      }
    }

    GetTopics(group_name, reply) -> {
      case dict.get(state.groups, group_name) {
        Error(Nil) -> {
          process.send(reply, Error(GroupNotFound(group_name)))
          actor.continue(state)
        }
        Ok(topics) -> {
          process.send(reply, Ok(topics))
          actor.continue(state)
        }
      }
    }

    ListGroups(reply) -> {
      let names = dict.keys(state.groups)
      process.send(reply, names)
      actor.continue(state)
    }
  }
}

fn broadcast_to_topics(
  topics: Set(String),
  channels: beryl.Sockets,
  event: String,
  payload: json.Json,
) -> Nil {
  set.to_list(topics)
  |> list.each(fn(topic) { beryl.broadcast(channels, topic, event, payload) })
}
