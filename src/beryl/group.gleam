//// Channel Groups - Named collections of topics for multi-topic broadcasting
////
//// Groups let you organize topics and broadcast to all of them at once.
//// Useful for scenarios like broadcasting to all channels in a "team" or
//// sending a system-wide notification.
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
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}

/// A running Groups instance
pub type Groups {
  Groups(subject: Subject(Message))
}

/// Errors from group operations
pub type GroupError {
  /// The group already exists
  AlreadyExists
  /// The group was not found
  NotFound
  /// The actor failed to start
  StartFailed
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
  BroadcastToGroup(
    group_name: String,
    channels: beryl.Channels,
    event: String,
    payload: json.Json,
  )
}

/// Internal state
type State {
  State(groups: Dict(String, Set(String)))
}

/// Start the groups actor
pub fn start() -> Result(Groups, GroupError) {
  build_groups()
  |> actor.start
  |> result.map(fn(started) { Groups(subject: started.data) })
  |> result.map_error(fn(_) { StartFailed })
}

/// Start the groups actor with a registered name (for supervision)
pub fn start_named(
  name: process.Name(Message),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  build_groups()
  |> actor.named(name)
  |> actor.start
}

fn build_groups() -> actor.Builder(State, Message, Subject(Message)) {
  actor.new(State(groups: dict.new()))
  |> actor.on_message(handle_message)
}

/// Create a new named group
pub fn create(groups: Groups, name: String) -> Result(Nil, GroupError) {
  process.call(groups.subject, 5000, fn(reply) { Create(name, reply) })
}

/// Delete a group
pub fn delete(groups: Groups, name: String) -> Result(Nil, GroupError) {
  process.call(groups.subject, 5000, fn(reply) { Delete(name, reply) })
}

/// Add a topic to a group
pub fn add(
  groups: Groups,
  group_name: String,
  topic: String,
) -> Result(Nil, GroupError) {
  process.call(groups.subject, 5000, fn(reply) { Add(group_name, topic, reply) })
}

/// Remove a topic from a group
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
pub fn topics(
  groups: Groups,
  group_name: String,
) -> Result(Set(String), GroupError) {
  process.call(groups.subject, 5000, fn(reply) { GetTopics(group_name, reply) })
}

/// List all group names
pub fn list_groups(groups: Groups) -> List(String) {
  process.call(groups.subject, 5000, fn(reply) { ListGroups(reply) })
}

/// Broadcast a message to all topics in a group
///
/// Sends the message to every topic in the named group via beryl.broadcast().
/// If the group doesn't exist, this is a silent no-op (fire and forget).
pub fn broadcast(
  groups: Groups,
  channels: beryl.Channels,
  group_name: String,
  event: String,
  payload: json.Json,
) -> Nil {
  process.send(
    groups.subject,
    BroadcastToGroup(group_name, channels, event, payload),
  )
}

// ── Actor loop ──────────────────────────────────────────────────────────────

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Create(name, reply) -> {
      case dict.has_key(state.groups, name) {
        True -> {
          process.send(reply, Error(AlreadyExists))
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
          process.send(reply, Error(NotFound))
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
        Error(_) -> {
          process.send(reply, Error(NotFound))
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
        Error(_) -> {
          process.send(reply, Error(NotFound))
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
        Error(_) -> {
          process.send(reply, Error(NotFound))
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

    BroadcastToGroup(group_name, channels, event, payload) -> {
      case dict.get(state.groups, group_name) {
        Error(_) -> actor.continue(state)
        Ok(topics) -> {
          set.to_list(topics)
          |> list.each(fn(topic) {
            beryl.broadcast(channels, topic, event, payload)
          })
          actor.continue(state)
        }
      }
    }
  }
}
