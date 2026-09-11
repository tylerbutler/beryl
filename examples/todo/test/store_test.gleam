import gleeunit/should
import todo_server/store

pub fn starts_empty_and_allocates_monotonic_ids_test() {
  let assert Ok(store) = store.start()

  store.all(store)
  |> should.equal(Ok([]))

  store.add(store, "  Write the guide  ")
  |> should.equal(
    Ok(store.Todo(id: 0, text: "Write the guide", completed: False)),
  )
  store.add(store, "Ship the example")
  |> should.equal(
    Ok(store.Todo(id: 1, text: "Ship the example", completed: False)),
  )
}

pub fn rejects_empty_and_overlong_text_without_mutating_test() {
  let assert Ok(store) = store.start()

  store.add(store, " \n\t ")
  |> should.equal(Error(store.EmptyText))
  store.add(
    store,
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  |> should.equal(Error(store.TextTooLong))
  store.all(store)
  |> should.equal(Ok([]))
}

pub fn toggles_and_deletes_canonical_todos_test() {
  let assert Ok(store) = store.start()
  let assert Ok(item) = store.add(store, "Test realtime")

  store.toggle(store, item.id)
  |> should.equal(Ok(store.Todo(..item, completed: True)))
  store.delete(store, item.id)
  |> should.equal(Ok(item.id))
  store.all(store)
  |> should.equal(Ok([]))
}

pub fn unknown_ids_are_explicit_and_do_not_mutate_test() {
  let assert Ok(store) = store.start()
  let assert Ok(item) = store.add(store, "Keep me")

  store.toggle(store, 99)
  |> should.equal(Error(store.UnknownTodo))
  store.delete(store, 99)
  |> should.equal(Error(store.UnknownTodo))
  store.all(store)
  |> should.equal(Ok([item]))
}
