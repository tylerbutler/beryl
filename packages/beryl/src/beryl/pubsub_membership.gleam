import beryl/pubsub_native
import gleam/bool
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}

const call_timeout_ms = 5000

const recovery_delay_ms = 10

pub opaque type Registry {
  Registry(subject: process.Subject(Message))
}

pub type RegistryError {
  ScopeRecovering
  PgUnavailable(reason: pubsub_native.PgError)
  OwnerNotLocal
}

pub opaque type Message {
  Ready(reply: process.Subject(Result(Nil, RegistryError)))
  Join(
    topic: String,
    owner: process.Pid,
    reply: process.Subject(Result(Nil, RegistryError)),
  )
  Leave(
    topic: String,
    owner: process.Pid,
    reply: process.Subject(Result(Nil, RegistryError)),
  )
  ProcessDown(process.Down)
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
    owners: List(Owner),
    pg: Option(PgGeneration),
    retry: Option(process.Timer),
  )
}

// nolint: unused_exports -- OTP supervisor callback invoked from Erlang
pub fn start(
  scope: atom.Atom,
) -> Result(actor.Started(Registry), actor.StartError) {
  actor.new_with_initialiser(call_timeout_ms, fn(_default_subject) {
    let registry = from_pid(process.self())
    schedule_recovery(State(
      scope: scope,
      registry: registry,
      owners: [],
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
pub fn from_pid(pid: process.Pid) -> Registry {
  Registry(subject: pubsub_native.subject_for_pid(
    pid,
    atom.create("pubsub_memberships"),
  ))
}

// nolint: unused_exports -- Erlang recovery tests inspect the actor owner
pub fn pid(registry: Registry) -> process.Pid {
  let assert Ok(pid) = process.subject_owner(registry.subject)
  pid
}

// nolint: unused_exports -- query compatibility adapter invoked from Erlang
pub fn is_alive(registry: Registry) -> Bool {
  process.is_alive(pid(registry))
}

// nolint: unused_exports -- startup compatibility adapter invoked from Erlang
pub fn ready(registry: Registry) -> Result(Nil, RegistryError) {
  process.call(registry.subject, call_timeout_ms, Ready)
}

// nolint: unused_exports -- mutation compatibility adapter invoked from Erlang
pub fn join(
  registry: Registry,
  topic: String,
  owner: process.Pid,
) -> Result(Nil, RegistryError) {
  process.call(registry.subject, call_timeout_ms, fn(reply) {
    Join(topic:, owner:, reply:)
  })
}

// nolint: unused_exports -- mutation compatibility adapter invoked from Erlang
pub fn leave(
  registry: Registry,
  topic: String,
  owner: process.Pid,
) -> Result(Nil, RegistryError) {
  process.call(registry.subject, call_timeout_ms, fn(reply) {
    Leave(topic:, owner:, reply:)
  })
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
    Ready(reply) -> reply_with(reply, synchronise(state, fn(_) { Ok(Nil) }))
    Join(topic, owner, reply) -> handle_join(state, topic, owner, reply)
    Leave(topic, owner, reply) -> {
      let state = remove_topic(state, topic, owner)
      reply_with(
        reply,
        synchronise(state, fn(state) {
          pubsub_native.try_leave(state.scope, topic, owner)
          |> result.map_error(PgUnavailable)
        }),
      )
    }
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

fn handle_join(
  state: State,
  topic: String,
  owner: process.Pid,
  reply: process.Subject(Result(Nil, RegistryError)),
) -> actor.Next(State, Message) {
  case pubsub_native.is_local_pid(owner) {
    False -> {
      process.send(reply, Error(OwnerNotLocal))
      actor.continue(state)
    }
    True -> {
      let state = add_owner(state, topic, owner)
      reply_with(
        reply,
        synchronise(state, fn(state) { join_once(state.scope, topic, owner) }),
      )
    }
  }
}

fn reply_with(
  reply: process.Subject(Result(Nil, RegistryError)),
  outcome: #(Result(Nil, RegistryError), State),
) -> actor.Next(State, Message) {
  let #(result, state) = outcome
  process.send(reply, result)
  actor.continue(state)
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
  case list.find(state.owners, fn(owner) { owner.pid == pid }) {
    Ok(owner) -> {
      let updated = Owner(..owner, topics: set.insert(owner.topics, topic))
      State(..state, owners: replace_owner(state.owners, updated))
    }
    Error(Nil) -> {
      let owner =
        Owner(
          pid: pid,
          monitor: process.monitor(pid),
          topics: set.from_list([topic]),
        )
      State(..state, owners: [owner, ..state.owners])
    }
  }
}

fn replace_owner(owners: List(Owner), updated: Owner) -> List(Owner) {
  list.map(owners, fn(owner) {
    case owner.pid == updated.pid {
      True -> updated
      False -> owner
    }
  })
}

fn remove_topic(state: State, topic: String, pid: process.Pid) -> State {
  let owners =
    state.owners
    |> list.filter_map(remove_owner_topic(_, topic, pid))
  State(..state, owners: owners)
}

fn remove_owner_topic(
  owner: Owner,
  topic: String,
  pid: process.Pid,
) -> Result(Owner, Nil) {
  use <- bool.guard(when: owner.pid != pid, return: Ok(owner))
  keep_remaining_topics(owner, set.delete(owner.topics, topic))
}

fn keep_remaining_topics(
  owner: Owner,
  topics: Set(String),
) -> Result(Owner, Nil) {
  use <- bool.guard(
    when: !set.is_empty(topics),
    return: Ok(Owner(..owner, topics: topics)),
  )
  process.demonitor_process(owner.monitor)
  Error(Nil)
}

fn remove_down_owner(
  owners: List(Owner),
  monitor: process.Monitor,
  pid: process.Pid,
) -> List(Owner) {
  list.filter(owners, fn(owner) { owner.pid != pid || owner.monitor != monitor })
}

fn synchronise(
  state: State,
  operation: fn(State) -> Result(Nil, RegistryError),
) -> #(Result(Nil, RegistryError), State) {
  let state = prune_dead_owners(state)
  case pubsub_native.registered_scope(state.scope) {
    Error(Nil) -> unavailable(state, ScopeRecovering)
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
    Some(_) | None -> replay(state, pg_pid)
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
  use _ <- result.try(replay_owners(state.scope, state.owners))
  case stable_scope(state.scope, pg_pid) {
    True -> Ok(state)
    False -> Error(ScopeRecovering)
  }
}

fn replay_owners(
  scope: atom.Atom,
  owners: List(Owner),
) -> Result(Nil, RegistryError) {
  list.fold(owners, Ok(Nil), fn(result, owner) {
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
    list.filter(state.owners, fn(owner) {
      case process.is_alive(owner.pid) {
        True -> True
        False -> {
          process.demonitor_process(owner.monitor)
          False
        }
      }
    })
  State(..state, owners: owners)
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
