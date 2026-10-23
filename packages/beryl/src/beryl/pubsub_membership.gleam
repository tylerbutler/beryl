//// Local PubSub membership recovery
////
//// This internal actor records each local subscriber owner's topics and
//// restores live memberships after the scope's `pg` process restarts.
//// Owner monitors remove normal stale state. Full owner liveness checks run
//// only during recovery, so healthy membership operations stay independent
//// of the total subscriber count.
////
//// Calls use a timeout-safe Erlang boundary. A timed-out caller does not keep
//// a monitor or receive a late reply.

import beryl/internal
import beryl/log
import beryl/pubsub_native
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}

const call_timeout_ms = 5000

const recovery_delay_ms = 10

/// A handle to one scope's local membership actor.
pub opaque type Registry {
  Registry(subject: process.Subject(Message))
}

/// Latest topic intent owned by one runtime router.
pub type Intent

/// Create coalesced intent storage owned by the calling router.
@external(erlang, "beryl_pubsub_ffi", "new_membership_intent")
pub fn new_intent() -> Intent

@external(erlang, "beryl_pubsub_ffi", "set_membership_intent")
fn update_intent(intent: Intent, topic: String, joined: Bool) -> Bool

@external(erlang, "beryl_pubsub_ffi", "take_membership_intent")
fn take_intent(intent: Intent) -> Result(List(String), Nil)

/// A membership operation failure.
pub type RegistryError {
  /// The scope has no stable `pg` generation yet.
  ScopeRecovering
  /// The underlying `pg` operation failed.
  PgUnavailable(reason: pubsub_native.PgError)
  /// The requested owner belongs to another BEAM node.
  OwnerNotLocal
}

/// Messages accepted by the membership actor.
pub opaque type Message {
  Ready(reply: process.Subject(Result(Nil, RegistryError)))
  Join(
    topic: String,
    owner: process.Pid,
    reply: Option(process.Subject(Result(Nil, RegistryError))),
  )
  Leave(
    topic: String,
    owner: process.Pid,
    reply: Option(process.Subject(Result(Nil, RegistryError))),
  )
  ProcessDown(process.Down)
  SyncOwner(owner: process.Pid, intent: Intent)
  Recover
}

type Owner {
  Owner(pid: process.Pid, monitor: process.Monitor, topics: Set(String))
}

type PgGeneration {
  PgGeneration(pid: process.Pid, monitor: process.Monitor)
}

type State {
  State(
    scope: atom.Atom,
    registry: Registry,
    owners: Dict(process.Pid, Owner),
    pending_leaves: Set(#(process.Pid, String)),
    pg: Option(PgGeneration),
    retry: Option(process.Timer),
  )
}

@external(erlang, "beryl_pubsub_ffi", "membership_actor_call")
fn call(
  subject: process.Subject(Message),
  timeout_ms: Int,
  request: fn(process.Subject(reply)) -> Message,
) -> reply

@external(erlang, "beryl_ffi", "connection_limit_send")
fn send(subject: process.Subject(Message), message: Message) -> Bool

// nolint: unused_exports -- OTP supervisor callback invoked from Erlang
/// Start a membership actor for one `pg` scope.
pub fn start(
  scope: atom.Atom,
) -> Result(actor.Started(Registry), actor.StartError) {
  actor.new_with_initialiser(call_timeout_ms, fn(_default_subject) {
    let registry = from_pid(process.self())
    schedule_recovery(State(
      scope: scope,
      registry: registry,
      owners: dict.new(),
      pending_leaves: set.new(),
      pg: None,
      retry: None,
    ))
    |> actor.initialised
    |> actor.selecting(selector(registry))
    |> actor.returning(registry)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

// nolint: unused_exports -- startup adapter invoked from Erlang
/// Build a registry handle for an actor process started by OTP.
pub fn from_pid(pid: process.Pid) -> Registry {
  Registry(subject: pubsub_native.subject_for_pid(
    pid,
    atom.create("pubsub_memberships"),
  ))
}

// nolint: unused_exports -- Erlang recovery tests inspect the actor owner
/// Return the process that owns a registry.
pub fn pid(registry: Registry) -> process.Pid {
  let assert Ok(pid) = process.subject_owner(registry.subject)
  pid
}

// nolint: unused_exports -- query compatibility adapter invoked from Erlang
/// Check whether the registry process is alive.
pub fn is_alive(registry: Registry) -> Bool {
  case process.subject_owner(registry.subject) {
    Ok(owner) -> process.is_alive(owner)
    Error(Nil) -> False
  }
}

// nolint: unused_exports -- startup compatibility adapter invoked from Erlang
/// Wait until the registry has synchronised with a stable `pg` generation.
pub fn ready(registry: Registry) -> Result(Nil, RegistryError) {
  call(registry.subject, call_timeout_ms, Ready)
}

// nolint: unused_exports -- mutation compatibility adapter invoked from Erlang
/// Record and apply one local owner's topic membership.
pub fn join(
  registry: Registry,
  topic: String,
  owner: process.Pid,
) -> Result(Nil, RegistryError) {
  call(registry.subject, call_timeout_ms, fn(reply) {
    Join(topic:, owner:, reply: Some(reply))
  })
}

// nolint: unused_exports -- mutation compatibility adapter invoked from Erlang
/// Remove one local owner's topic membership.
pub fn leave(
  registry: Registry,
  topic: String,
  owner: process.Pid,
) -> Result(Nil, RegistryError) {
  call(registry.subject, call_timeout_ms, fn(reply) {
    Leave(topic:, owner:, reply: Some(reply))
  })
}

/// Record membership intent without waiting for `pg` reconciliation.
pub fn set_membership(
  registry: Registry,
  intent: Intent,
  topic: String,
  joined: Bool,
) -> Result(Nil, Nil) {
  use _ <- result.try(case is_alive(registry) {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  case update_intent(intent, topic, joined) {
    False -> Ok(Nil)
    True ->
      case send(registry.subject, SyncOwner(process.self(), intent)) {
        True -> Ok(Nil)
        False -> Error(Nil)
      }
  }
}

fn selector(registry: Registry) -> process.Selector(Message) {
  process.new_selector()
  |> process.select(registry.subject)
  |> process.select_monitors(ProcessDown)
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Ready(reply) ->
      reply_with(Some(reply), synchronise(state, fn(_) { Ok(Nil) }))
    Join(topic, owner, reply) -> handle_join(state, topic, owner, reply)
    Leave(topic, owner, reply) -> handle_leave(state, topic, owner, reply)
    SyncOwner(owner, intent) -> sync_owner(state, owner, intent)
    Recover -> {
      let state = State(..state, retry: None)
      let #(_, state) = synchronise(state, fn(_) { Ok(Nil) })
      actor.continue(state)
    }
    ProcessDown(process.ProcessDown(monitor, pid, _)) ->
      handle_process_down(state, monitor, pid)
    ProcessDown(process.PortDown(_, _, _)) -> actor.continue(state)
  }
}

fn handle_leave(
  state: State,
  topic: String,
  owner: process.Pid,
  reply: Option(process.Subject(Result(Nil, RegistryError))),
) -> actor.Next(State, Message) {
  case pubsub_native.is_local_pid(owner) {
    False -> reply_with(reply, #(Error(OwnerNotLocal), state))
    True -> reply_with(reply, leave_local(state, topic, owner))
  }
}

fn leave_local(
  state: State,
  topic: String,
  owner: process.Pid,
) -> #(Result(Nil, RegistryError), State) {
  let state = remove_topic(state, topic, owner)
  let pending = set.insert(state.pending_leaves, #(owner, topic))
  let #(outcome, state) =
    synchronise(State(..state, pending_leaves: pending), fn(state) {
      pubsub_native.try_leave(state.scope, topic, owner)
      |> result.map_error(PgUnavailable)
    })
  let state = case result.is_ok(outcome) {
    True ->
      State(
        ..state,
        pending_leaves: set.delete(state.pending_leaves, #(owner, topic)),
      )
    False -> state
  }
  #(outcome, state)
}

fn sync_owner(
  state: State,
  owner: process.Pid,
  intent: Intent,
) -> actor.Next(State, Message) {
  case take_intent(intent) {
    Error(Nil) -> actor.continue(state)
    Ok(topics) -> sync_topics(state, owner, set.from_list(topics))
  }
}

fn sync_topics(
  state: State,
  owner: process.Pid,
  desired: Set(String),
) -> actor.Next(State, Message) {
  let previous = case dict.get(state.owners, owner) {
    Ok(value) -> value.topics
    Error(Nil) -> set.new()
  }
  let removed = set.difference(previous, desired)
  let added = set.difference(desired, previous)
  let state = case dict.get(state.owners, owner) {
    Ok(value) ->
      State(
        ..state,
        owners: dict.insert(
          state.owners,
          owner,
          Owner(..value, topics: desired),
        ),
      )
    Error(Nil) ->
      State(
        ..state,
        owners: dict.insert(
          state.owners,
          owner,
          Owner(owner, process.monitor(owner), desired),
        ),
      )
  }
  let pending =
    set.fold(removed, state.pending_leaves, fn(pending, topic) {
      set.insert(pending, #(owner, topic))
    })
  let pending =
    set.fold(desired, pending, fn(pending, topic) {
      set.delete(pending, #(owner, topic))
    })
  let #(outcome, state) =
    synchronise(State(..state, pending_leaves: pending), fn(state) {
      use _ <- result.try(
        removed
        |> set.to_list
        |> list.try_each(fn(topic) {
          pubsub_native.try_leave(state.scope, topic, owner)
          |> result.map_error(PgUnavailable)
        }),
      )
      added
      |> set.to_list
      |> list.try_each(fn(topic) { join_once(state.scope, topic, owner) })
    })
  let state = case result.is_ok(outcome) {
    True ->
      State(
        ..state,
        pending_leaves: set.fold(
          removed,
          state.pending_leaves,
          fn(pending, topic) { set.delete(pending, #(owner, topic)) },
        ),
      )
    False -> state
  }
  reply_with(None, #(outcome, state))
}

fn handle_join(
  state: State,
  topic: String,
  owner: process.Pid,
  reply: Option(process.Subject(Result(Nil, RegistryError))),
) -> actor.Next(State, Message) {
  case pubsub_native.is_local_pid(owner) {
    False -> {
      reply_with(reply, #(Error(OwnerNotLocal), state))
    }
    True -> {
      let state =
        add_owner(
          State(
            ..state,
            pending_leaves: set.delete(state.pending_leaves, #(owner, topic)),
          ),
          topic,
          owner,
        )
      reply_with(
        reply,
        synchronise(state, fn(state) { join_once(state.scope, topic, owner) }),
      )
    }
  }
}

fn reply_with(
  reply: Option(process.Subject(Result(Nil, RegistryError))),
  outcome: #(Result(Nil, RegistryError), State),
) -> actor.Next(State, Message) {
  let #(result, state) = outcome
  case reply, result {
    Some(reply), _ -> process.send(reply, result)
    None, Ok(Nil) -> Nil
    None, Error(error) ->
      internal.logger("beryl.pubsub")
      |> log.warn("PubSub membership reconciliation deferred", [
        #("reason", describe_error(error)),
      ])
  }
  actor.continue(state)
}

fn describe_error(error: RegistryError) -> String {
  case error {
    ScopeRecovering -> "scope recovering"
    PgUnavailable(_) -> "pg unavailable"
    OwnerNotLocal -> "owner is not local"
  }
}

fn handle_process_down(
  state: State,
  monitor: process.Monitor,
  pid: process.Pid,
) -> actor.Next(State, Message) {
  case state.pg {
    Some(PgGeneration(pid: current_pid, monitor: current_monitor))
      if pid == current_pid && monitor == current_monitor
    ->
      state
      |> forget_pg
      |> schedule_recovery
      |> actor.continue
    Some(_) | None ->
      State(..state, owners: remove_down_owner(state.owners, monitor, pid))
      |> actor.continue
  }
}

fn add_owner(state: State, topic: String, pid: process.Pid) -> State {
  case dict.get(state.owners, pid) {
    Ok(owner) -> {
      let updated = Owner(..owner, topics: set.insert(owner.topics, topic))
      State(..state, owners: dict.insert(state.owners, pid, updated))
    }
    Error(Nil) -> {
      let owner =
        Owner(
          pid: pid,
          monitor: process.monitor(pid),
          topics: set.from_list([topic]),
        )
      State(..state, owners: dict.insert(state.owners, pid, owner))
    }
  }
}

fn remove_topic(state: State, topic: String, pid: process.Pid) -> State {
  case dict.get(state.owners, pid) {
    Error(Nil) -> state
    Ok(owner) -> {
      let topics = set.delete(owner.topics, topic)
      case set.is_empty(topics) {
        False ->
          State(
            ..state,
            owners: dict.insert(
              state.owners,
              pid,
              Owner(..owner, topics: topics),
            ),
          )
        True -> {
          process.demonitor_process(owner.monitor)
          State(..state, owners: dict.delete(state.owners, pid))
        }
      }
    }
  }
}

fn remove_down_owner(
  owners: Dict(process.Pid, Owner),
  monitor: process.Monitor,
  pid: process.Pid,
) -> Dict(process.Pid, Owner) {
  case dict.get(owners, pid) {
    Ok(Owner(monitor: current, ..)) if current == monitor ->
      dict.delete(owners, pid)
    Ok(_) | Error(Nil) -> owners
  }
}

fn synchronise(
  state: State,
  operation: fn(State) -> Result(Nil, RegistryError),
) -> #(Result(Nil, RegistryError), State) {
  case pubsub_native.registered_scope(state.scope) {
    Error(Nil) ->
      // No live generation can retain a membership that needs removal.
      unavailable(State(..state, pending_leaves: set.new()), ScopeRecovering)
    Ok(pg_pid) -> synchronise_registered(state, pg_pid, operation)
  }
}

fn synchronise_registered(
  state: State,
  pg_pid: process.Pid,
  operation: fn(State) -> Result(Nil, RegistryError),
) -> #(Result(Nil, RegistryError), State) {
  case recover_generation(state, pg_pid) {
    Error(error) -> unavailable(state, error)
    Ok(state) -> run_synchronised(state, pg_pid, operation)
  }
}

fn recover_generation(
  state: State,
  pg_pid: process.Pid,
) -> Result(State, RegistryError) {
  case state.pg {
    Some(PgGeneration(pid: current_pid, ..)) if current_pid == pg_pid ->
      Ok(state)
    Some(_) | None -> state |> prune_dead_owners |> replay(pg_pid)
  }
}

fn run_synchronised(
  state: State,
  pg_pid: process.Pid,
  operation: fn(State) -> Result(Nil, RegistryError),
) -> #(Result(Nil, RegistryError), State) {
  case stable_scope(state.scope, pg_pid) {
    False -> unavailable(state, ScopeRecovering)
    True -> {
      let state = watch_pg(state, pg_pid)
      finish_operation(state, pg_pid, operation(state))
    }
  }
}

fn finish_operation(
  state: State,
  pg_pid: process.Pid,
  result: Result(Nil, RegistryError),
) -> #(Result(Nil, RegistryError), State) {
  case result {
    Error(error) -> unavailable(state, error)
    Ok(Nil) ->
      case stable_scope(state.scope, pg_pid) {
        True -> #(Ok(Nil), state)
        False -> unavailable(state, ScopeRecovering)
      }
  }
}

fn replay(state: State, pg_pid: process.Pid) -> Result(State, RegistryError) {
  use _ <- result.try(
    state.pending_leaves
    |> set.to_list
    |> list.try_each(fn(entry) {
      pubsub_native.try_leave(state.scope, entry.1, entry.0)
      |> result.map_error(PgUnavailable)
    }),
  )
  use _ <- result.try(replay_owners(state.scope, state.owners))
  case stable_scope(state.scope, pg_pid) {
    True -> Ok(State(..state, pending_leaves: set.new()))
    False -> Error(ScopeRecovering)
  }
}

fn replay_owners(
  scope: atom.Atom,
  owners: Dict(process.Pid, Owner),
) -> Result(Nil, RegistryError) {
  dict.fold(owners, Ok(Nil), fn(result, _, owner) {
    use _ <- result.try(result)
    list.fold(set.to_list(owner.topics), Ok(Nil), fn(result, topic) {
      use _ <- result.try(result)
      join_once(scope, topic, owner.pid)
    })
  })
}

fn join_once(
  scope: atom.Atom,
  topic: String,
  owner: process.Pid,
) -> Result(Nil, RegistryError) {
  use members <- result.try(
    pubsub_native.try_local_members(scope, topic)
    |> result.map_error(PgUnavailable),
  )
  case list.contains(members, owner) {
    True -> Ok(Nil)
    False ->
      pubsub_native.try_join(scope, topic, owner)
      |> result.map_error(PgUnavailable)
  }
}

fn stable_scope(scope: atom.Atom, expected: process.Pid) -> Bool {
  case pubsub_native.registered_scope(scope) {
    Ok(current) -> current == expected && process.is_alive(current)
    Error(Nil) -> False
  }
}

fn prune_dead_owners(state: State) -> State {
  let owners =
    dict.fold(state.owners, dict.new(), fn(owners, pid, owner) {
      case process.is_alive(owner.pid) {
        True -> dict.insert(owners, pid, owner)
        False -> {
          process.demonitor_process(owner.monitor)
          owners
        }
      }
    })
  State(
    ..state,
    owners: owners,
    pending_leaves: state.pending_leaves
      |> set.to_list
      |> list.filter(fn(entry) { process.is_alive(entry.0) })
      |> set.from_list,
  )
}

fn watch_pg(state: State, pid: process.Pid) -> State {
  case state.pg {
    Some(PgGeneration(pid: current, ..)) if current == pid -> state
    Some(_) | None -> {
      let state = forget_pg(state)
      State(
        ..state,
        pg: Some(PgGeneration(pid: pid, monitor: process.monitor(pid))),
      )
    }
  }
}

fn unavailable(
  state: State,
  error: RegistryError,
) -> #(Result(Nil, RegistryError), State) {
  #(Error(error), state |> forget_pg |> schedule_recovery)
}

fn forget_pg(state: State) -> State {
  case state.pg {
    None -> state
    Some(PgGeneration(monitor: monitor, ..)) -> {
      process.demonitor_process(monitor)
      State(..state, pg: None)
    }
  }
}

fn schedule_recovery(state: State) -> State {
  case state.retry {
    Some(_) -> state
    None -> {
      let Registry(subject) = state.registry
      let timer = process.send_after(subject, recovery_delay_ms, Recover)
      State(..state, retry: Some(timer))
    }
  }
}
