import gleam/dynamic/decode
import gleam/json
import todo_app/domain

const version = 1

type Persisted {
  Persisted(version: Int, next_id: Int, todos: List(domain.Todo))
}

pub fn encode(state: domain.State) -> String {
  json.object([
    #("version", json.int(version)),
    #("next_id", json.int(domain.next_id(state))),
    #("todos", json.array(domain.todos(state), encode_todo)),
  ])
  |> json.to_string
}

pub fn decode(encoded: String) -> Result(domain.State, Nil) {
  case json.parse(from: encoded, using: persisted_decoder()) {
    Ok(Persisted(version: persisted_version, next_id:, todos:))
      if persisted_version == version
    -> domain.restore(next_id, todos)
    _ -> Error(Nil)
  }
}

fn encode_todo(item: domain.Todo) -> json.Json {
  let domain.Todo(id:, text:, completed:) = item
  json.object([
    #("id", json.int(id)),
    #("text", json.string(text)),
    #("completed", json.bool(completed)),
  ])
}

fn persisted_decoder() -> decode.Decoder(Persisted) {
  use persisted_version <- decode.field("version", decode.int)
  use next_id <- decode.field("next_id", decode.int)
  use todos <- decode.field("todos", decode.list(todo_decoder()))

  decode.success(Persisted(version: persisted_version, next_id:, todos:))
}

fn todo_decoder() -> decode.Decoder(domain.Todo) {
  use id <- decode.field("id", decode.int)
  use text <- decode.field("text", decode.string)
  use completed <- decode.field("completed", decode.bool)

  decode.success(domain.Todo(id:, text:, completed:))
}
