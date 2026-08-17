//// Channel Groups - Named collections of topics for multi-topic broadcasting
////
//// Groups let you organize topics and broadcast to all of them at once.
//// Useful for scenarios like broadcasting to all channels in a "team" or
//// sending a system-wide notification.
////
//// Groups are independent of the Beryl runtime. Start the actor from a
//// long-lived application process and include it in the application's
//// supervision arrangement as appropriate.
////
//// ## Example
////
//// ```gleam
//// let assert Ok(groups) = group.start()
//// let assert Ok(Nil) = group.create(groups, "team:engineering")
//// let assert Ok(Nil) = group.add(groups, "team:engineering", "room:frontend")
//// let assert Ok(Nil) = group.add(groups, "team:engineering", "room:backend")
//// group.broadcast(groups, channels, "team:engineering", "announce", payload)
//// ```

import beryl
import beryl/error as beryl_error
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}

/// A running Groups instance.
///
/// This handle is intentionally opaque so callers cannot forge the backing
/// actor subject or depend on its runtime representation.
pub opaque type Groups {
  Groups(subject: Subject(Message))
}

/// Errors from group operations
pub type GroupError {
  /// The group already exists
  GroupAlreadyExists
  /// The group was not found
  GroupNotFound
}

/// Errors when starting the groups actor.
pub type GroupStartError {
  /// The actor failed to start
  GroupActorStartFailed(beryl_error.StartFailure)
}

/// Messages the groups actor handles
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

/// Start the groups actor
pub fn start() -> Result(Groups, GroupStartError) {
  build_groups()
  |> actor.start
  |> result.map(fn(started) { Groups(subject: started.data) })
  |> result.map_error(fn(error) {
    GroupActorStartFailed(beryl_error.from_actor_start_error(error))
  })
}

fn build_groups() -> actor.Builder(State, Message, Subject(Message)) {
  actor.new(State(groups: dict.new()))
  |> actor.on_message(handle_message)
}

/// Create a new named group
///
/// Panics if the groups actor is unavailable or does not reply within 5 seconds.
pub fn create(groups: Groups, name: String) -> Result(Nil, GroupError) {
  process.call(groups.subject, 5000, fn(reply) { Create(name, reply) })
}

/// Delete a group
///
/// Panics if the groups actor is unavailable or does not reply within 5 seconds.
pub fn delete(groups: Groups, name: String) -> Result(Nil, GroupError) {
  process.call(groups.subject, 5000, fn(reply) { Delete(name, reply) })
}

/// Add a topic to a group
///
/// Panics if the groups actor is unavailable or does not reply within 5 seconds.
pub fn add(
  groups: Groups,
  group_name: String,
  topic: String,
) -> Result(Nil, GroupError) {
  process.call(groups.subject, 5000, fn(reply) { Add(group_name, topic, reply) })
}

/// Remove a topic from a group
///
/// Panics if the groups actor is unavailable or does not reply within 5 seconds.
pub fn remove(
  groups: Groups,
  group_name: String,
  topic: String,
) -> Result(Nil, GroupError) {
  process.call(groups.subject, 5000, fn(reply) {
    Remove(group_name, topic, reply)
  })
}

/// Get all topics in a group
///
/// Panics if the groups actor is unavailable or does not reply within 5 seconds.
pub fn topics(
  groups: Groups,
  group_name: String,
) -> Result(Set(String), GroupError) {
  process.call(groups.subject, 5000, fn(reply) { GetTopics(group_name, reply) })
}

/// List all group names
///
/// Panics if the groups actor is unavailable or does not reply within 5 seconds.
pub fn list_groups(groups: Groups) -> List(String) {
  process.call(groups.subject, 5000, fn(reply) { ListGroups(reply) })
}

/// Broadcast a message to all topics in a group
///
/// Sends the message to every topic in the named group via beryl.broadcast().
/// The topic lookup runs through the groups actor, then fan-out runs in the
/// caller. If the group doesn't exist, this is a silent no-op.
///
/// Panics if the groups actor is unavailable or does not reply within 5 seconds.
pub fn broadcast(
  groups: Groups,
  channels: beryl.Sockets,
  group_name: String,
  event: String,
  payload: json.Json,
) -> Nil {
  case topics(groups, group_name) {
    Ok(topics) -> broadcast_to_topics(topics, channels, event, payload)
    Error(GroupAlreadyExists) -> Nil
    Error(GroupNotFound) -> Nil
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
          process.send(reply, Error(GroupAlreadyExists))
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
          process.send(reply, Error(GroupNotFound))
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
          process.send(reply, Error(GroupNotFound))
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
          process.send(reply, Error(GroupNotFound))
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
          process.send(reply, Error(GroupNotFound))
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
