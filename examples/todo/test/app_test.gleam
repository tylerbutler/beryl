import beryl/socket
import gleam/dynamic
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleeunit/should
import todo_server/app
import todo_server/store

fn join_ref(topic: String) -> socket.Ref {
  socket.make_join_ref(topic: topic, join_ref: Some("join"), msg_ref: Some("1"))
}

fn message_ref() -> socket.Ref {
  socket.make_message_ref(
    topic: "todos",
    join_ref: Some("join"),
    msg_ref: Some("2"),
  )
}

fn object(fields: List(#(String, dynamic.Dynamic))) -> dynamic.Dynamic {
  fields
  |> list.map(fn(field) {
    let #(key, value) = field
    #(dynamic.string(key), value)
  })
  |> dynamic.properties
}

pub fn join_returns_the_current_snapshot_test() {
  let assert Ok(store) = store.start()
  let assert Ok(_) = store.add(store, "Existing")

  let next =
    app.update(store)(Nil, socket.Join("todos", object([]), join_ref("todos")))

  let assert socket.Next(_, [socket.AcceptJoin(_, Some(snapshot))]) = next
  json.to_string(snapshot)
  |> should.equal(
    "{\"todos\":[{\"id\":0,\"text\":\"Existing\",\"completed\":false}]}",
  )
}

pub fn unknown_topic_is_rejected_test() {
  let assert Ok(store) = store.start()
  let next =
    app.update(store)(Nil, socket.Join("other", object([]), join_ref("other")))

  let assert socket.Next(_, [socket.RejectJoin(_, reason)]) = next
  json.to_string(reason)
  |> should.equal("{\"reason\":\"unknown_topic\"}")
}

pub fn add_validates_payload_and_empty_text_test() {
  let assert Ok(store) = store.start()

  let assert socket.Next(_, [socket.ReplyError(_, malformed)]) =
    app.update(store)(
      Nil,
      socket.Message(
        "todos",
        "add_todo",
        object([#("text", dynamic.int(1))]),
        Some(message_ref()),
      ),
    )
  json.to_string(malformed)
  |> should.equal(
    "{\"code\":\"invalid_payload\",\"message\":\"Expected a string field named 'text'.\"}",
  )

  let assert socket.Next(_, [socket.ReplyError(_, empty)]) =
    app.update(store)(
      Nil,
      socket.Message(
        "todos",
        "add_todo",
        object([#("text", dynamic.string("   "))]),
        Some(message_ref()),
      ),
    )
  json.to_string(empty)
  |> should.equal(
    "{\"code\":\"empty_todo\",\"message\":\"Todo text cannot be empty.\"}",
  )
  store.all(store)
  |> should.equal(Ok([]))
}

pub fn mutation_replies_and_broadcasts_canonical_payload_test() {
  let assert Ok(store) = store.start()

  let assert socket.Next(
    _,
    [
      socket.ReplyOk(_, reply),
      socket.Broadcast("todos", "todo_added", broadcast),
    ],
  ) =
    app.update(store)(
      Nil,
      socket.Message(
        "todos",
        "add_todo",
        object([#("text", dynamic.string("  Canonical  "))]),
        Some(message_ref()),
      ),
    )

  json.to_string(reply)
  |> should.equal("{\"id\":0,\"text\":\"Canonical\",\"completed\":false}")
  json.to_string(broadcast)
  |> should.equal(json.to_string(reply))
}

pub fn unknown_id_returns_error_without_broadcast_test() {
  let assert Ok(store) = store.start()

  let assert socket.Next(_, [socket.ReplyError(_, error)]) =
    app.update(store)(
      Nil,
      socket.Message(
        "todos",
        "toggle_todo",
        object([#("id", dynamic.int(404))]),
        Some(message_ref()),
      ),
    )

  json.to_string(error)
  |> should.equal(
    "{\"code\":\"unknown_id\",\"message\":\"The Todo ID does not exist.\"}",
  )
}

pub fn toggle_and_delete_require_integer_ids_test() {
  let assert Ok(store) = store.start()
  let invalid = object([#("id", dynamic.string("not-an-integer"))])

  let assert socket.Next(_, [socket.ReplyError(_, toggle_error)]) =
    app.update(store)(
      Nil,
      socket.Message("todos", "toggle_todo", invalid, Some(message_ref())),
    )
  let assert socket.Next(_, [socket.ReplyError(_, delete_error)]) =
    app.update(store)(
      Nil,
      socket.Message("todos", "delete_todo", invalid, Some(message_ref())),
    )

  json.to_string(toggle_error)
  |> should.equal(
    "{\"code\":\"invalid_payload\",\"message\":\"Expected an integer field named 'id'.\"}",
  )
  json.to_string(delete_error)
  |> should.equal(json.to_string(toggle_error))
}
