import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/result
import todo_app/domain

pub type Client

pub type Event {
  Connecting
  Joined(List(domain.Todo))
  Disconnected(String)
  Added(domain.Todo)
  Updated(domain.Todo)
  Deleted(Int)
  DecodeFailed(String)
}

pub type MutationError {
  Rejected(code: String, message: String)
  InvalidResponse(String)
}

@external(javascript, "./todo_channel_ffi.mjs", "connect")
fn connect_ffi(
  on_connecting: fn() -> Nil,
  on_joined: fn(Dynamic) -> Nil,
  on_disconnected: fn(Dynamic) -> Nil,
  on_added: fn(Dynamic) -> Nil,
  on_updated: fn(Dynamic) -> Nil,
  on_deleted: fn(Dynamic) -> Nil,
) -> Client

@external(javascript, "./todo_channel_ffi.mjs", "addTodo")
fn add_todo_ffi(
  client: Client,
  text: String,
  on_ok: fn(Dynamic) -> Nil,
  on_error: fn(Dynamic) -> Nil,
) -> Nil

@external(javascript, "./todo_channel_ffi.mjs", "toggleTodo")
fn toggle_todo_ffi(
  client: Client,
  id: Int,
  on_ok: fn(Dynamic) -> Nil,
  on_error: fn(Dynamic) -> Nil,
) -> Nil

@external(javascript, "./todo_channel_ffi.mjs", "deleteTodo")
fn delete_todo_ffi(
  client: Client,
  id: Int,
  on_ok: fn(Dynamic) -> Nil,
  on_error: fn(Dynamic) -> Nil,
) -> Nil

@external(javascript, "./todo_channel_ffi.mjs", "close")
pub fn close(client: Client) -> Nil

@external(javascript, "./todo_channel_ffi.mjs", "reconnect")
pub fn reconnect(client: Client) -> Nil

pub fn connect(on_event: fn(Event) -> Nil) -> Client {
  connect_ffi(
    fn() { on_event(Connecting) },
    fn(payload) {
      case decode_snapshot(payload) {
        Ok(todos) -> on_event(Joined(todos))
        Error(_) ->
          on_event(DecodeFailed("Could not decode the join snapshot."))
      }
    },
    fn(payload) { on_event(Disconnected(decode_reason(payload))) },
    fn(payload) {
      case decode_todo(payload) {
        Ok(item) -> on_event(Added(item))
        Error(_) -> on_event(DecodeFailed("Could not decode todo_added."))
      }
    },
    fn(payload) {
      case decode_todo(payload) {
        Ok(item) -> on_event(Updated(item))
        Error(_) -> on_event(DecodeFailed("Could not decode todo_updated."))
      }
    },
    fn(payload) {
      case decode_deleted(payload) {
        Ok(id) -> on_event(Deleted(id))
        Error(_) -> on_event(DecodeFailed("Could not decode todo_deleted."))
      }
    },
  )
}

pub fn add(
  client: Client,
  text: String,
  callback: fn(Result(domain.Todo, MutationError)) -> Nil,
) -> Nil {
  add_todo_ffi(
    client,
    text,
    fn(payload) {
      callback(
        decode_todo(payload)
        |> result.replace_error(InvalidResponse("Could not decode add reply.")),
      )
    },
    fn(payload) { callback(Error(decode_mutation_error(payload))) },
  )
}

pub fn toggle(
  client: Client,
  id: Int,
  callback: fn(Result(domain.Todo, MutationError)) -> Nil,
) -> Nil {
  toggle_todo_ffi(
    client,
    id,
    fn(payload) {
      callback(
        decode_todo(payload)
        |> result.replace_error(InvalidResponse(
          "Could not decode toggle reply.",
        )),
      )
    },
    fn(payload) { callback(Error(decode_mutation_error(payload))) },
  )
}

pub fn delete(
  client: Client,
  id: Int,
  callback: fn(Result(Int, MutationError)) -> Nil,
) -> Nil {
  delete_todo_ffi(
    client,
    id,
    fn(payload) {
      callback(
        decode_deleted(payload)
        |> result.replace_error(InvalidResponse(
          "Could not decode delete reply.",
        )),
      )
    },
    fn(payload) { callback(Error(decode_mutation_error(payload))) },
  )
}

pub fn decode_snapshot(payload: Dynamic) -> Result(List(domain.Todo), Nil) {
  let decoder = {
    use todos <- decode.field("todos", decode.list(todo_decoder()))
    decode.success(todos)
  }
  use todos <- result.try(
    decode.run(payload, decoder)
    |> result.replace_error(Nil),
  )
  case domain.from_todos(todos) {
    Ok(_) -> Ok(todos)
    Error(Nil) -> Error(Nil)
  }
}

pub fn decode_todo(payload: Dynamic) -> Result(domain.Todo, Nil) {
  use item <- result.try(
    decode.run(payload, todo_decoder())
    |> result.replace_error(Nil),
  )
  case domain.from_todos([item]) {
    Ok(_) -> Ok(item)
    Error(Nil) -> Error(Nil)
  }
}

pub fn decode_deleted(payload: Dynamic) -> Result(Int, Nil) {
  let decoder = {
    use id <- decode.field("id", decode.int)
    decode.success(id)
  }
  use id <- result.try(
    decode.run(payload, decoder)
    |> result.replace_error(Nil),
  )
  case id >= 0 {
    True -> Ok(id)
    False -> Error(Nil)
  }
}

fn todo_decoder() -> decode.Decoder(domain.Todo) {
  use id <- decode.field("id", decode.int)
  use text <- decode.field("text", decode.string)
  use completed <- decode.field("completed", decode.bool)
  decode.success(domain.Todo(id:, text:, completed:))
}

fn decode_reason(payload: Dynamic) -> String {
  let decoder = {
    use message <- decode.field("message", decode.string)
    decode.success(message)
  }
  decode.run(payload, decoder)
  |> result.unwrap("Connection lost. Reconnecting…")
}

fn decode_mutation_error(payload: Dynamic) -> MutationError {
  let decoder = {
    use code <- decode.field("code", decode.string)
    use message <- decode.field("message", decode.string)
    decode.success(#(code, message))
  }

  case decode.run(payload, decoder) {
    Ok(#(code, message)) -> Rejected(code:, message:)
    Error(_) -> InvalidResponse("Could not decode the server error.")
  }
}
