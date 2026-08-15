import gleam/list
import gleam/string

pub type Todo {
  Todo(id: Int, text: String, completed: Bool)
}

pub opaque type State {
  State(next_id: Int, todos: List(Todo))
}

pub fn new() -> State {
  State(next_id: 0, todos: [])
}

pub fn restore(next_id: Int, todos: List(Todo)) -> Result(State, Nil) {
  case valid(next_id, todos) {
    True -> Ok(State(next_id:, todos:))
    False -> Error(Nil)
  }
}

pub fn next_id(state: State) -> Int {
  state.next_id
}

pub fn todos(state: State) -> List(Todo) {
  state.todos
}

pub fn add(state: State, text: String) -> Result(State, Nil) {
  let text = string.trim(text)

  case text {
    "" -> Error(Nil)
    _ ->
      Ok(State(
        next_id: state.next_id + 1,
        todos: list.append(state.todos, [
          Todo(id: state.next_id, text:, completed: False),
        ]),
      ))
  }
}

pub fn toggle(state: State, id: Int) -> State {
  State(
    ..state,
    todos: list.map(state.todos, fn(item) {
      case item.id == id {
        True -> Todo(..item, completed: !item.completed)
        False -> item
      }
    }),
  )
}

pub fn delete(state: State, id: Int) -> State {
  State(..state, todos: list.filter(state.todos, fn(item) { item.id != id }))
}

pub fn items_left(state: State) -> Int {
  state.todos
  |> list.filter(fn(item) { !item.completed })
  |> list.length
}

fn valid(next_id: Int, todos: List(Todo)) -> Bool {
  next_id >= 0
  && list.all(todos, fn(item) {
    item.id >= 0 && item.id < next_id && string.trim(item.text) != ""
  })
  && unique_ids(todos)
}

fn unique_ids(todos: List(Todo)) -> Bool {
  case todos {
    [] -> True
    [item, ..rest] ->
      !list.any(rest, fn(other) { other.id == item.id }) && unique_ids(rest)
  }
}
