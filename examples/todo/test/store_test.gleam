import gleam/erlang/process
import gleam/json
import gleam/otp/static_supervisor
import gleeunit/should
import todo_server/store

@external(erlang, "todo_store_test_ffi", "with_suspended")
fn with_suspended(pid: process.Pid, action: fn() -> a) -> a

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

pub fn timed_out_queued_write_expires_before_mutating_test() -> Nil {
  let assert Ok(store) = store.start()
  let assert Ok(pid) = store.process_id(store)
  with_suspended(pid, fn() {
    store.add(store, "Expired") |> should.equal(Error(store.Timeout))
  })
  store.all(store) |> should.equal(Ok([]))
}

pub fn store_publishes_mutations_in_commit_order_before_reply_test() -> Nil {
  let published = process.new_subject()
  let store = store.new()
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(
      store.child_spec(store, fn(event, payload) {
        Ok(process.send(published, #(event, json.to_string(payload))))
      }),
    )
    |> static_supervisor.start()
  let assert Ok(item) = store.add(store, "Ordered")
  let _ = process.receive(published, 1000)
  let assert Ok(_) = store.toggle(store, item.id)
  let assert Ok(_) = store.toggle(store, item.id)
  process.receive(published, 1000)
  |> should.equal(
    Ok(#("todo_updated", "{\"id\":0,\"text\":\"Ordered\",\"completed\":true}")),
  )
  process.receive(published, 1000)
  |> should.equal(
    Ok(#("todo_updated", "{\"id\":0,\"text\":\"Ordered\",\"completed\":false}")),
  )
  store.all(store) |> should.equal(Ok([item]))
}

pub fn rejected_publication_does_not_commit_or_allocate_an_id_test() -> Nil {
  let store = store.new()
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(store.child_spec(store, fn(_, _) { Error(Nil) }))
    |> static_supervisor.start()
  store.add(store, "Rejected") |> should.equal(Error(store.PublicationRejected))
  store.all(store) |> should.equal(Ok([]))
}
