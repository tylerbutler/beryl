import gleam/list
import gleam/string

pub type Todo {
  Todo(id: Int, text: String, completed: Bool)
}

pub opaque type State {
  State(todos: List(Todo))
}

pub fn new() -> State {
  State(todos: [])
}

pub fn from_todos(todos: List(Todo)) -> Result(State, Nil) {
  case valid(todos) {
    True -> Ok(State(todos:))
    False -> Error(Nil)
  }
}

pub fn todos(state: State) -> List(Todo) {
  state.todos
}

pub fn put(state: State, item: Todo) -> State {
  let todos = case
    list.any(state.todos, fn(existing) { existing.id == item.id })
  {
    True ->
      list.map(state.todos, fn(existing) {
        case existing.id == item.id {
          True -> item
          False -> existing
        }
      })
    False -> list.append(state.todos, [item])
  }
  State(todos:)
}

pub fn delete(state: State, id: Int) -> State {
  State(todos: list.filter(state.todos, fn(item) { item.id != id }))
}

pub fn items_left(state: State) -> Int {
  state.todos
  |> list.filter(fn(item) { !item.completed })
  |> list.length
}

fn valid(todos: List(Todo)) -> Bool {
  list.all(todos, fn(item) { item.id >= 0 && string.trim(item.text) != "" })
  && unique_ids(todos)
}

fn unique_ids(todos: List(Todo)) -> Bool {
  case todos {
    [] -> True
    [item, ..rest] ->
      !list.any(rest, fn(other) { other.id == item.id }) && unique_ids(rest)
  }
}
