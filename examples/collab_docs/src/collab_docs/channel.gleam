import beryl
import beryl/channel.{type Channel, type HandleResult, type JoinResult}
import beryl/socket.{type Socket}
import beryl/topic
import collab_docs/auth
import collab_docs/doc_store.{type Store}
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/option.{Some}
import gleam/result
import gleam/string

/// Maximum byte size of a `sync_state` payload's `state` field. Protects the
/// doc_store actor from unbounded merges by malicious or buggy clients.
const max_state_bytes = 65_536

/// Topic pattern for document channels: `document:<tenant>:<document>`.
/// Hoisted so we don't reparse on every join.
const document_topic_pattern_string = "document:*:*"

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
///
/// `secret` is the shared HMAC secret used to verify per-tenant bearer
/// tokens carried in the join payload. See `collab_docs/auth`.
pub fn new_handler(
  channels: beryl.Channels,
  store: Store,
  secret: BitArray,
) -> Channel(Assigns) {
  channel.new(fn(topic_name, payload, socket) {
    join(channels, store, secret, topic_name, payload, socket)
  })
  |> channel.with_handle_in(handle_in)
}

/// Build a collision-resistant key for a tenant/document pair.
pub fn build_document_key(tenant: String, document: String) -> String {
  json.array([tenant, document], json.string)
  |> json.to_string
}

fn extract_token(payload: json.Json) -> Result(String, Nil) {
  let decoder = {
    use token <- decode.field("token", decode.string)
    decode.success(token)
  }

  json.parse(json.to_string(payload), decoder)
  |> result.replace_error(Nil)
}

fn join(
  channels: beryl.Channels,
  store: Store,
  secret: BitArray,
  topic_name: String,
  payload: json.Json,
  socket: Socket(Assigns),
) -> JoinResult(Assigns) {
  let pattern = topic.parse_pattern(document_topic_pattern_string)

  case topic.extract_wildcards(pattern, topic_name) {
    Ok([tenant, document]) -> {
      // Channel-level auth: the join payload must carry a `token` HMAC-signed
      // for the tenant whose document is being joined. Without this, any
      // client could enumerate `document:<tenant>:<doc>` for arbitrary
      // tenants by guessing topic strings.
      case extract_token(payload) {
        Error(_) -> channel.JoinError(reason: error_payload("missing_token"))
        Ok(token) ->
          case auth.verify_tenant(token, tenant, secret) {
            Error(_) ->
              channel.JoinError(reason: error_payload("unauthorized"))
            Ok(Nil) -> {
              let document_key = build_document_key(tenant, document)
              let assigns =
                Assigns(channels:, store:, topic_name:, document_key:)
              let socket = socket.set_assigns(socket, assigns)
              let state = case doc_store.get_state(store, document_key) {
                Ok(encoded) -> json.string(encoded)
                Error(doc_store.NotFound) -> json.null()
                Error(doc_store.Timeout) -> {
                  io.println_error(
                    "[collab_docs.channel] doc_store.get_state timed out for key="
                    <> document_key,
                  )
                  json.null()
                }
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
          }
      }
    }

    _ -> channel.JoinError(reason: error_payload("invalid_topic"))
  }
}

fn handle_in(
  event: String,
  payload: json.Json,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  case event {
    "sync_state" -> sync_state(payload, socket)
    _ -> reply_error("unknown_event", socket)
  }
}

fn sync_state(
  payload: json.Json,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  case extract_state(payload) {
    Ok(state) ->
      case string.byte_size(state) > max_state_bytes {
        True -> reply_error("state_too_large", socket)
        False -> {
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
      }

    Error(_) -> reply_error("invalid_state", socket)
  }
}

fn reply_error(code: String, socket: Socket(Assigns)) -> HandleResult(Assigns) {
  channel.Reply(event: "state_error", payload: error_payload(code), socket:)
}

fn extract_state(payload: json.Json) -> Result(String, Nil) {
  let decoder = {
    use state <- decode.field("state", decode.string)
    decode.success(state)
  }

  json.parse(json.to_string(payload), decoder)
  |> result.replace_error(Nil)
}

fn error_payload(code: String) -> json.Json {
  json.object([#("code", json.string(code))])
}
