import live_poll/poll
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result

pub opaque type Store {
  Store(subject: Subject(Message))
}

pub type CloseResult {
  ClosedNow(poll.Poll)
  AlreadyClosed(poll.Poll)
  RoomNotFound
}

type Message {
  Join(room: String)
  Leave(room: String)
  Get(room: String, reply: Subject(poll.Poll))
  Vote(
    room: String,
    choice: poll.Choice,
    reply: Subject(Result(poll.Poll, poll.VoteError)),
  )
  Close(room: String, reply: Subject(CloseResult))
}

type State {
  State(polls: Dict(String, poll.Poll), members: Dict(String, Int))
}

pub fn start() -> Result(Store, actor.StartError) {
  actor.new(State(polls: dict.new(), members: dict.new()))
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Store(started.data) })
}

pub fn join(store: Store, room: String) -> Nil {
  process.send(store.subject, Join(room))
}

pub fn leave(store: Store, room: String) -> Nil {
  process.send(store.subject, Leave(room))
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
    Join(room) -> {
      let #(poll, polls) = find(state.polls, room)
      let count = dict.get(state.members, room) |> result.unwrap(0)
      actor.continue(State(
        polls: dict.insert(polls, room, poll),
        members: dict.insert(state.members, room, count + 1),
      ))
    }
    Leave(room) ->
      case dict.get(state.members, room) {
        Ok(count) if count > 1 ->
          actor.continue(
            State(..state, members: dict.insert(state.members, room, count - 1)),
          )
        _ ->
          actor.continue(State(
            polls: dict.delete(state.polls, room),
            members: dict.delete(state.members, room),
          ))
      }
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
