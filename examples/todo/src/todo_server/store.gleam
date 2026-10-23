import gleam/erlang/process.{type Name, type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import todo_server/clock

const receive_timeout_ms = 1000

const max_text_length = 160

pub type Todo {
  Todo(id: Int, text: String, completed: Bool)
}

pub type Error {
  EmptyText
  TextTooLong
  UnknownTodo
  Timeout
  PublicationRejected
}

pub opaque type Store {
  Store(name: Option(Name(Message)), subject: fn() -> Subject(Message))
}

type Message {
  Request(deadline: Int, command: Command)
}

type Command {
  All(reply: Subject(Result(List(Todo), Error)))
  Add(text: String, reply: Subject(Result(Todo, Error)))
  Toggle(id: Int, reply: Subject(Result(Todo, Error)))
  Delete(id: Int, reply: Subject(Result(Int, Error)))
}

type State {
  State(next_id: Int, todos: List(Todo))
}

type CallEvent(value) {
  Replied(Result(value, Error))
  WorkerExited
}

pub fn start() -> Result(Store, actor.StartError) {
  start_actor(None, fn(_, _) { Ok(Nil) })
  |> result.map(fn(started) {
    let subject = started.data
    Store(name: None, subject: fn() { subject })
  })
}

pub fn new() -> Store {
  let name = process.new_name("todo_store")
  Store(name: Some(name), subject: fn() { process.named_subject(name) })
}

pub fn child_spec(
  store: Store,
  publish: fn(String, json.Json) -> Result(Nil, Nil),
) -> supervision.ChildSpecification(Store) {
  supervision.worker(fn() { start_actor(store.name, publish) })
  |> supervision.map_data(fn(_subject) { store })
}

@internal
pub fn process_id(store: Store) -> Result(process.Pid, Nil) {
  process.subject_owner(store.subject())
}

pub fn all(store: Store) -> Result(List(Todo), Error) {
  call(store, All)
}

pub fn add(store: Store, text: String) -> Result(Todo, Error) {
  call(store, fn(reply) { Add(text:, reply:) })
}

pub fn toggle(store: Store, id: Int) -> Result(Todo, Error) {
  call(store, fn(reply) { Toggle(id:, reply:) })
}

pub fn delete(store: Store, id: Int) -> Result(Int, Error) {
  call(store, fn(reply) { Delete(id:, reply:) })
}

fn start_actor(
  name: Option(Name(Message)),
  publish: fn(String, json.Json) -> Result(Nil, Nil),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  let builder =
    actor.new(State(next_id: 0, todos: []))
    |> actor.on_message(fn(state: State, request: Message) {
      case clock.monotonic_milliseconds() >= request.deadline {
        True -> actor.continue(state)
        False -> handle_message(state, request.command, publish)
      }
    })

  case name {
    None -> actor.start(builder)
    Some(name) -> builder |> actor.named(name) |> actor.start
  }
}

fn call(
  store: Store,
  message: fn(Subject(Result(value, Error))) -> Command,
) -> Result(value, Error) {
  // A short-lived reply owner prevents timed-out calls retaining late replies.
  let result = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      let reply = process.new_subject()
      let deadline = clock.monotonic_milliseconds() + receive_timeout_ms
      process.send(store.subject(), Request(deadline, message(reply)))
      let response = case process.receive(reply, receive_timeout_ms) {
        Ok(response) -> response
        Error(Nil) -> Error(Timeout)
      }
      process.send(result, response)
    })
  let monitor = process.monitor(worker)
  let response =
    process.new_selector()
    |> process.select_map(result, Replied)
    |> process.select_specific_monitor(monitor, fn(_) { WorkerExited })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  case response {
    Replied(response) -> response
    WorkerExited -> Error(Timeout)
  }
}

fn handle_message(
  state: State,
  message: Command,
  publish: fn(String, json.Json) -> Result(Nil, Nil),
) -> actor.Next(State, Message) {
  case message {
    All(reply) -> {
      process.send(reply, Ok(state.todos))
      actor.continue(state)
    }

    Add(text, reply) -> {
      let text = string.trim(text)
      case validate_text(text) {
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
        Ok(Nil) -> {
          let item = Todo(id: state.next_id, text:, completed: False)
          commit(
            state,
            State(
              next_id: state.next_id + 1,
              todos: list.append(state.todos, [item]),
            ),
            item,
            reply,
            "todo_added",
            todo_json(item),
            publish,
          )
        }
      }
    }

    Toggle(id, reply) ->
      case list.find(state.todos, fn(item) { item.id == id }) {
        Error(Nil) -> {
          process.send(reply, Error(UnknownTodo))
          actor.continue(state)
        }
        Ok(found) -> {
          let updated = Todo(..found, completed: !found.completed)
          let todos =
            list.map(state.todos, fn(item) {
              case item.id == id {
                True -> updated
                False -> item
              }
            })
          commit(
            state,
            State(..state, todos: todos),
            updated,
            reply,
            "todo_updated",
            todo_json(updated),
            publish,
          )
        }
      }

    Delete(id, reply) ->
      case list.any(state.todos, fn(item) { item.id == id }) {
        False -> {
          process.send(reply, Error(UnknownTodo))
          actor.continue(state)
        }
        True -> {
          commit(
            state,
            State(
              ..state,
              todos: list.filter(state.todos, fn(item) { item.id != id }),
            ),
            id,
            reply,
            "todo_deleted",
            json.object([#("id", json.int(id))]),
            publish,
          )
        }
      }
  }
}

fn commit(
  state: State,
  updated: State,
  value: value,
  reply: Subject(Result(value, Error)),
  event: String,
  payload: json.Json,
  publish: fn(String, json.Json) -> Result(Nil, Nil),
) -> actor.Next(State, Message) {
  case publish(event, payload) {
    Ok(Nil) -> {
      process.send(reply, Ok(value))
      actor.continue(updated)
    }
    Error(Nil) -> {
      process.send(reply, Error(PublicationRejected))
      actor.continue(state)
    }
  }
}

fn todo_json(item: Todo) -> json.Json {
  json.object([
    #("id", json.int(item.id)),
    #("text", json.string(item.text)),
    #("completed", json.bool(item.completed)),
  ])
}

fn validate_text(text: String) -> Result(Nil, Error) {
  case text {
    "" -> Error(EmptyText)
    _ ->
      case string.length(text) > max_text_length {
        True -> Error(TextTooLong)
        False -> Ok(Nil)
      }
  }
}
