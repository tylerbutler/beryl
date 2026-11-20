import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/otp/actor
import gleam/result
import live_poll/poll

pub opaque type Store {
  Store(subject: Subject(Message))
}

pub type CloseResult {
  ClosedNow(poll.Poll)
  AlreadyClosed(poll.Poll)
  RoomNotFound
}

type Message {
  Join(room: String, owner: Pid)
  Leave(room: String, owner: Pid)
  OwnerDown(process.Down)
  Get(room: String, reply: Subject(poll.Poll))
  Vote(
    room: String,
    choice: poll.Choice,
    reply: Subject(Result(poll.Poll, poll.VoteError)),
  )
  Close(room: String, reply: Subject(CloseResult))
}

type State {
  State(
    polls: Dict(String, poll.Poll),
    members: Dict(String, Dict(Pid, Monitor)),
  )
}

pub fn start() -> Result(Store, actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    actor.initialised(State(polls: dict.new(), members: dict.new()))
    |> actor.selecting(
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(OwnerDown),
    )
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Store(started.data) })
}

/// Register the calling process once per room and monitor its lifetime.
pub fn join(store: Store, room: String) -> Nil {
  process.send(store.subject, Join(room, process.self()))
}

/// Remove the calling process's membership, if it is still registered.
pub fn leave(store: Store, room: String) -> Nil {
  process.send(store.subject, Leave(room, process.self()))
}

pub fn get(store: Store, room: String) -> poll.Poll {
  process.call(store.subject, 1000, fn(reply) { Get(room, reply) })
}

pub fn vote(
  store: Store,
  room: String,
  choice: poll.Choice,
) -> Result(poll.Poll, poll.VoteError) {
  process.call(store.subject, 1000, fn(reply) { Vote(room, choice, reply) })
}

pub fn close(store: Store, room: String) -> CloseResult {
  process.call(store.subject, 1000, fn(reply) { Close(room, reply) })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Join(room, owner) -> {
      let #(poll, polls) = find(state.polls, room)
      let members = dict.get(state.members, room) |> result.unwrap(dict.new())
      let members = case dict.has_key(members, owner) {
        True -> members
        False -> dict.insert(members, owner, process.monitor(owner))
      }
      actor.continue(State(
        polls: dict.insert(polls, room, poll),
        members: dict.insert(state.members, room, members),
      ))
    }
    Leave(room, owner) -> actor.continue(remove_member(state, room, owner))
    OwnerDown(process.ProcessDown(monitor, owner, _)) ->
      actor.continue(
        dict.fold(state.members, state, fn(state, room, members) {
          case dict.get(members, owner) {
            Ok(current) if current == monitor ->
              remove_member(state, room, owner)
            Ok(_) | Error(_) -> state
          }
        }),
      )
    OwnerDown(process.PortDown(..)) -> actor.continue(state)
    Get(room, reply) -> {
      let #(current, polls) = find(state.polls, room)
      process.send(reply, current)
      actor.continue(State(..state, polls: polls))
    }
    Vote(room, choice, reply) -> {
      let #(current, polls) = find(state.polls, room)
      case poll.vote(current, choice) {
        Ok(updated) -> {
          process.send(reply, Ok(updated))
          actor.continue(
            State(..state, polls: dict.insert(polls, room, updated)),
          )
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(State(..state, polls: polls))
        }
      }
    }
    Close(room, reply) -> {
      case dict.get(state.polls, room) {
        Ok(current) -> {
          case poll.close(current) {
            poll.ClosedNow(updated) -> {
              process.send(reply, ClosedNow(updated))
              actor.continue(
                State(..state, polls: dict.insert(state.polls, room, updated)),
              )
            }
            poll.AlreadyClosed(unchanged) -> {
              process.send(reply, AlreadyClosed(unchanged))
              actor.continue(state)
            }
          }
        }
        Error(_) -> {
          process.send(reply, RoomNotFound)
          actor.continue(state)
        }
      }
    }
  }
}

fn remove_member(state: State, room: String, owner: Pid) -> State {
  let members = dict.get(state.members, room) |> result.unwrap(dict.new())
  case dict.get(members, owner) {
    Error(_) -> state
    Ok(monitor) -> {
      process.demonitor_process(monitor)
      let remaining = dict.delete(members, owner)
      case dict.size(remaining) {
        0 ->
          State(
            polls: dict.delete(state.polls, room),
            members: dict.delete(state.members, room),
          )
        _ ->
          State(..state, members: dict.insert(state.members, room, remaining))
      }
    }
  }
}

fn find(
  polls: Dict(String, poll.Poll),
  room: String,
) -> #(poll.Poll, Dict(String, poll.Poll)) {
  case dict.get(polls, room) {
    Ok(current) -> #(current, polls)
    Error(_) -> {
      let current = poll.new()
      #(current, dict.insert(polls, room, current))
    }
  }
}
