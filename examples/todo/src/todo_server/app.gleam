import beryl/socket.{
  type Effect, type Input, type Next, type Ref, AcceptJoin, Broadcast,
  RejectJoin, ReplyError, ReplyOk,
}
import beryl/socket/router
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import todo_server/store

const topic = "todos"

pub fn init(_info: socket.ConnectInfo(Nil)) -> #(Nil, List(Effect)) {
  #(Nil, [])
}

pub fn update(store: store.Store) -> fn(Nil, Input(Nil)) -> Next(Nil, Nil) {
  let namespaces = [namespace(store)]
  fn(model, input) {
    router.route(namespaces, router.unknown_topic(), model, input)
  }
}

fn namespace(store: store.Store) -> router.Namespace(Nil) {
  router.namespace(
    pattern: topic,
    join: fn(model, _match, _payload, ref) {
      case store.all(store) {
        Ok(todos) -> #(model, [AcceptJoin(ref, Some(snapshot_json(todos)))])
        Error(_) -> #(model, [
          RejectJoin(
            ref,
            error_json("store_unavailable", "The Todo store did not respond."),
          ),
        ])
      }
    },
    message: fn(model, match, event, payload, ref) {
      #(model, handle_message(store, match.topic, event, payload, ref))
    },
    closed: fn(model, _match, _reason) { #(model, []) },
  )
}

fn handle_message(
  store: store.Store,
  topic_name: String,
  event: String,
  payload: Dynamic,
  ref: Option(Ref),
) -> List(Effect) {
  case event {
    "add_todo" -> add_todo(store, topic_name, payload, ref)
    "toggle_todo" -> toggle_todo(store, topic_name, payload, ref)
    "delete_todo" -> delete_todo(store, topic_name, payload, ref)
    _ ->
      reply_error(
        ref,
        "unknown_event",
        "The todos topic does not handle event '" <> event <> "'.",
      )
  }
}

fn add_todo(
  store: store.Store,
  topic_name: String,
  payload: Dynamic,
  ref: Option(Ref),
) -> List(Effect) {
  case decode.run(payload, decode.at(["text"], decode.string)) {
    Error(_) ->
      reply_error(
        ref,
        "invalid_payload",
        "Expected a string field named 'text'.",
      )
    Ok(text) ->
      case store.add(store, text) {
        Ok(item) ->
          mutation_effects(ref, topic_name, "todo_added", todo_json(item))
        Error(store.EmptyText) ->
          reply_error(ref, "empty_todo", "Todo text cannot be empty.")
        Error(store.TextTooLong) ->
          reply_error(
            ref,
            "text_too_long",
            "Todo text cannot be longer than 160 characters.",
          )
        Error(store.UnknownTodo) ->
          reply_error(ref, "unknown_id", "The Todo ID does not exist.")
        Error(store.Timeout) ->
          reply_error(
            ref,
            "store_unavailable",
            "The Todo store did not respond.",
          )
      }
  }
}

fn toggle_todo(
  store: store.Store,
  topic_name: String,
  payload: Dynamic,
  ref: Option(Ref),
) -> List(Effect) {
  case decode_id(payload) {
    Error(Nil) ->
      reply_error(
        ref,
        "invalid_payload",
        "Expected an integer field named 'id'.",
      )
    Ok(id) ->
      case store.toggle(store, id) {
        Ok(item) ->
          mutation_effects(ref, topic_name, "todo_updated", todo_json(item))
        Error(store.UnknownTodo) ->
          reply_error(ref, "unknown_id", "The Todo ID does not exist.")
        Error(store.Timeout) ->
          reply_error(
            ref,
            "store_unavailable",
            "The Todo store did not respond.",
          )
        Error(store.EmptyText) | Error(store.TextTooLong) ->
          reply_error(ref, "invalid_todo", "The stored Todo is invalid.")
      }
  }
}

fn delete_todo(
  store: store.Store,
  topic_name: String,
  payload: Dynamic,
  ref: Option(Ref),
) -> List(Effect) {
  case decode_id(payload) {
    Error(Nil) ->
      reply_error(
        ref,
        "invalid_payload",
        "Expected an integer field named 'id'.",
      )
    Ok(id) ->
      case store.delete(store, id) {
        Ok(deleted_id) ->
          mutation_effects(
            ref,
            topic_name,
            "todo_deleted",
            deleted_json(deleted_id),
          )
        Error(store.UnknownTodo) ->
          reply_error(ref, "unknown_id", "The Todo ID does not exist.")
        Error(store.Timeout) ->
          reply_error(
            ref,
            "store_unavailable",
            "The Todo store did not respond.",
          )
        Error(store.EmptyText) | Error(store.TextTooLong) ->
          reply_error(ref, "invalid_todo", "The stored Todo is invalid.")
      }
  }
}

fn decode_id(payload: Dynamic) -> Result(Int, Nil) {
  decode.run(payload, decode.at(["id"], decode.int))
  |> result.replace_error(Nil)
}

fn mutation_effects(
  ref: Option(Ref),
  topic_name: String,
  event: String,
  payload: json.Json,
) -> List(Effect) {
  case ref {
    Some(ref) -> [
      ReplyOk(ref, payload),
      Broadcast(topic_name, event, payload),
    ]
    None -> [Broadcast(topic_name, event, payload)]
  }
}

fn reply_error(
  ref: Option(Ref),
  code: String,
  message: String,
) -> List(Effect) {
  case ref {
    Some(ref) -> [ReplyError(ref, error_json(code, message))]
    None -> []
  }
}

fn snapshot_json(todos: List(store.Todo)) -> json.Json {
  json.object([#("todos", json.array(todos, todo_json))])
}

fn todo_json(item: store.Todo) -> json.Json {
  let store.Todo(id:, text:, completed:) = item
  json.object([
    #("id", json.int(id)),
    #("text", json.string(text)),
    #("completed", json.bool(completed)),
  ])
}

fn deleted_json(id: Int) -> json.Json {
  json.object([#("id", json.int(id))])
}

fn error_json(code: String, message: String) -> json.Json {
  json.object([
    #("code", json.string(code)),
    #("message", json.string(message)),
  ])
}
