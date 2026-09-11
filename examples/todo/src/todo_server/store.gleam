import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string

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
}

pub opaque type Store {
  Store(subject: fn() -> Subject(Message))
}

type Message {
  All(reply: Subject(Result(List(Todo), Error)))
  Add(text: String, reply: Subject(Result(Todo, Error)))
  Toggle(id: Int, reply: Subject(Result(Todo, Error)))
  Delete(id: Int, reply: Subject(Result(Int, Error)))
}

type State {
  State(next_id: Int, todos: List(Todo))
}

pub fn start() -> Result(Store, actor.StartError) {
  start_actor(None)
  |> result.map(fn(started) {
    let subject = started.data
    Store(subject: fn() { subject })
  })
}

pub fn child_spec() -> #(Store, supervision.ChildSpecification(Store)) {
  let name = process.new_name("todo_store")
  let store = Store(subject: fn() { process.named_subject(name) })
  let spec =
    supervision.worker(fn() { start_actor(Some(name)) })
    |> supervision.map_data(fn(_subject) { store })

  #(store, spec)
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
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  let builder =
    actor.new(State(next_id: 0, todos: []))
    |> actor.on_message(handle_message)

  case name {
    None -> actor.start(builder)
    Some(name) -> builder |> actor.named(name) |> actor.start
  }
}

fn call(
  store: Store,
  message: fn(Subject(Result(value, Error))) -> Message,
) -> Result(value, Error) {
  let reply = process.new_subject()
  process.send(store.subject(), message(reply))

  case process.receive(from: reply, within: receive_timeout_ms) {
    Ok(result) -> result
    Error(_) -> Error(Timeout)
  }
}

fn handle_message(
  state: State,
  message: Message,
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
          process.send(reply, Ok(item))
          actor.continue(State(
            next_id: state.next_id + 1,
            todos: list.append(state.todos, [item]),
          ))
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
          process.send(reply, Ok(updated))
          actor.continue(State(..state, todos: todos))
        }
      }

    Delete(id, reply) ->
      case list.any(state.todos, fn(item) { item.id == id }) {
        False -> {
          process.send(reply, Error(UnknownTodo))
          actor.continue(state)
        }
        True -> {
          process.send(reply, Ok(id))
          actor.continue(
            State(
              ..state,
              todos: list.filter(state.todos, fn(item) { item.id != id }),
            ),
          )
        }
      }
  }
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
