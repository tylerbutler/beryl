import beryl
import beryl/channel.{type Channel, type HandleResult, type JoinResult}
import beryl/socket.{type Socket}
import beryl/topic
import collab_docs/doc_store.{type Store}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}

/// State stored in each socket's assigns.
pub type Assigns {
  Assigns(
    channels: beryl.Channels,
    store: Store,
    topic_name: String,
    document_key: String,
  )
}

/// Create a channel handler for collaborative document topics.
pub fn new_handler(channels: beryl.Channels, store: Store) -> Channel(Assigns) {
  channel.new(fn(topic_name, _payload, socket) {
    join(channels, store, topic_name, socket)
  })
  |> channel.with_handle_in(handle_in)
}

/// Build a collision-resistant key for a tenant/document pair.
pub fn document_key(tenant: String, document: String) -> String {
  json.array([tenant, document], json.string)
  |> json.to_string
}

fn join(
  channels: beryl.Channels,
  store: Store,
  topic_name: String,
  socket: Socket(Assigns),
) -> JoinResult(Assigns) {
  let pattern = topic.parse_pattern("document:*:*")

  case topic.extract_wildcards(pattern, topic_name) {
    Ok([tenant, document]) -> {
      let document_key = document_key(tenant, document)
      let assigns = Assigns(channels:, store:, topic_name:, document_key:)
      let socket = socket.set_assigns(socket, assigns)
      let state = case doc_store.get_state(store, document_key) {
        Ok(encoded) -> json.string(encoded)
        Error(_) -> json.null()
      }

      channel.JoinOk(
        reply: Some(
          json.object([
            #("tenant", json.string(tenant)),
            #("document", json.string(document)),
            #("state", state),
          ]),
        ),
        socket:,
      )
    }

    _ -> channel.JoinError(reason: state_error("invalid_topic"))
  }
}

fn handle_in(
  event: String,
  payload: json.Json,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  case event {
    "sync_state" -> sync_state(payload, socket)
    _ ->
      channel.Reply(
        event: "state_error",
        payload: state_error("unknown_event"),
        socket:,
      )
  }
}

fn sync_state(
  payload: json.Json,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  case extract_state(payload) {
    Ok(state) -> {
      let assigns = socket.get_assigns(socket)
      doc_store.merge_state(assigns.store, assigns.document_key, state)
      beryl.broadcast_from(
        assigns.channels,
        socket.id(socket),
        assigns.topic_name,
        "doc_state",
        json.object([#("state", json.string(state))]),
      )
      channel.NoReply(socket)
    }

    Error(_) ->
      channel.Reply(
        event: "state_error",
        payload: state_error("invalid_state"),
        socket:,
      )
  }
}

fn extract_state(payload: json.Json) -> Result(String, Nil) {
  let decoder = {
    use state <- decode.field("state", decode.string)
    decode.success(state)
  }

  json.parse(json.to_string(payload), decoder)
  |> result_nil
}

fn result_nil(result: Result(a, b)) -> Result(a, Nil) {
  case result {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}

fn state_error(code: String) -> json.Json {
  json.object([#("code", json.string(code))])
}
