import gleeunit
import todo_app/domain
import todo_app/storage

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn add_rejects_whitespace_and_trims_text_test() {
  assert domain.add(domain.new(), " \n\t ") == Error(Nil)

  let assert Ok(state) = domain.add(domain.new(), "  Write the tests  ")
  assert domain.todos(state)
    == [
      domain.Todo(id: 0, text: "Write the tests", completed: False),
    ]
  assert domain.next_id(state) == 1
}

pub fn toggle_and_items_left_test() {
  let assert Ok(state) = domain.add(domain.new(), "One")
  let assert Ok(state) = domain.add(state, "Two")

  assert domain.items_left(state) == 2
  let state = domain.toggle(state, 0)
  assert domain.items_left(state) == 1
  assert domain.todos(state)
    == [
      domain.Todo(id: 0, text: "One", completed: True),
      domain.Todo(id: 1, text: "Two", completed: False),
    ]
}

pub fn delete_preserves_monotonic_ids_test() {
  let assert Ok(state) = domain.add(domain.new(), "One")
  let assert Ok(state) = domain.add(state, "Two")
  let state = domain.delete(state, 0)
  let assert Ok(state) = domain.add(state, "Three")

  assert domain.todos(state)
    == [
      domain.Todo(id: 1, text: "Two", completed: False),
      domain.Todo(id: 2, text: "Three", completed: False),
    ]
  assert domain.next_id(state) == 3
}

pub fn storage_round_trip_test() {
  let assert Ok(state) = domain.add(domain.new(), "Persist me")
  let state = domain.toggle(state, 0)
  let assert Ok(decoded) = state |> storage.encode |> storage.decode

  assert domain.next_id(decoded) == domain.next_id(state)
  assert domain.todos(decoded) == domain.todos(state)
}

pub fn storage_rejects_invalid_data_test() {
  assert storage.decode("{not json") == Error(Nil)
  assert storage.decode("{\"version\":2,\"next_id\":0,\"todos\":[]}")
    == Error(Nil)
  assert storage.decode(
      "{\"version\":1,\"next_id\":1,\"todos\":[{\"id\":1,\"text\":\"bad id\",\"completed\":false}]}",
    )
    == Error(Nil)
}
