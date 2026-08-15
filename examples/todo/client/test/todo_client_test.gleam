import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import todo_app/domain
import todo_channel
import todo_client

pub fn main() -> Nil {
  gleeunit.main()
}

fn dynamic_json(raw: String) {
  let assert Ok(value) = json.parse(from: raw, using: decode.dynamic)
  value
}

pub fn domain_put_is_idempotent_by_server_id_test() {
  let first = domain.Todo(id: 7, text: "Write", completed: False)
  let updated = domain.Todo(..first, completed: True)
  let state =
    domain.new()
    |> domain.put(first)
    |> domain.put(first)
    |> domain.put(updated)

  domain.todos(state)
  |> should.equal([updated])
  domain.items_left(state)
  |> should.equal(0)
}

pub fn domain_delete_preserves_other_server_ids_test() {
  let first = domain.Todo(id: 4, text: "One", completed: False)
  let second = domain.Todo(id: 9, text: "Two", completed: False)
  let state =
    domain.new()
    |> domain.put(first)
    |> domain.put(second)
    |> domain.delete(4)

  domain.todos(state)
  |> should.equal([second])
  domain.items_left(state)
  |> should.equal(1)
}

pub fn channel_decodes_snapshot_and_canonical_mutations_test() {
  todo_channel.decode_snapshot(dynamic_json(
    "{\"todos\":[{\"id\":3,\"text\":\"Ship\",\"completed\":false}]}",
  ))
  |> should.equal(
    Ok([
      domain.Todo(id: 3, text: "Ship", completed: False),
    ]),
  )

  todo_channel.decode_todo(dynamic_json(
    "{\"id\":3,\"text\":\"Ship\",\"completed\":true}",
  ))
  |> should.equal(Ok(domain.Todo(id: 3, text: "Ship", completed: True)))

  todo_channel.decode_deleted(dynamic_json("{\"id\":3}"))
  |> should.equal(Ok(3))
}

pub fn channel_rejects_malformed_or_duplicate_snapshot_data_test() {
  todo_channel.decode_snapshot(dynamic_json("{\"todos\":\"bad\"}"))
  |> should.equal(Error(Nil))
  todo_channel.decode_snapshot(dynamic_json(
    "{\"todos\":[{\"id\":1,\"text\":\"One\",\"completed\":false},{\"id\":1,\"text\":\"Two\",\"completed\":false}]}",
  ))
  |> should.equal(Error(Nil))
  todo_channel.decode_todo(dynamic_json(
    "{\"id\":-1,\"text\":\"Bad\",\"completed\":false}",
  ))
  |> should.equal(Error(Nil))
}

pub fn joined_snapshot_replaces_client_state_test() {
  let stale = domain.Todo(id: 1, text: "Stale", completed: False)
  let fresh = domain.Todo(id: 2, text: "Fresh", completed: True)
  let model =
    todo_client.Model(
      ..todo_client.initial_model(),
      state: domain.put(domain.new(), stale),
    )

  let #(model, _) =
    todo_client.update(
      model,
      todo_client.ChannelEvent(
        todo_channel.Joined([
          fresh,
        ]),
      ),
    )

  domain.todos(model.state)
  |> should.equal([fresh])
  model.connection
  |> should.equal(todo_client.Connected)
}

pub fn duplicate_reply_and_broadcast_are_idempotent_test() {
  let item = domain.Todo(id: 5, text: "One row", completed: False)
  let #(model, _) =
    todo_client.update(
      todo_client.initial_model(),
      todo_client.ChannelEvent(todo_channel.Added(item)),
    )
  let #(model, _) =
    todo_client.update(model, todo_client.AddFinished("One row", Ok(item)))

  domain.todos(model.state)
  |> should.equal([item])
}

pub fn add_input_clears_only_after_matching_acknowledgement_test() {
  let item = domain.Todo(id: 5, text: "First", completed: False)
  let model =
    todo_client.Model(
      ..todo_client.initial_model(),
      input: "Second",
      pending_add: Some("First"),
    )

  let #(model, _) =
    todo_client.update(model, todo_client.AddFinished("First", Ok(item)))

  model.input
  |> should.equal("Second")
  model.pending_add
  |> should.equal(None)
  domain.todos(model.state)
  |> should.equal([item])
}
