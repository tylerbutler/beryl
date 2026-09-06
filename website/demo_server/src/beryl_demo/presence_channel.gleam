//// Validated presence channel for the beryl demo service.
////
//// The channel enforces the demo topic format, validates every field of the
//// join payload, tracks presence for the socket, and leaves the topic when
//// the scenario's absolute TTL delivers an `Expire` info message.

import beryl/channel.{type Handler}
import beryl/presence.{type Presence}
import beryl/presence/wire as presence_wire
import beryl_demo/config
import beryl_demo/expiry.{type Expiry}
import gleam/bool
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string

/// Server-originated messages delivered to the channel's `on_info` callback.
pub type Info {
  Expire
}

/// A decoded join payload with all fields validated.
type JoinPayload {
  JoinPayload(
    client_id: String,
    compatibility_version: Int,
    name: String,
    color: String,
  )
}

/// True when `topic` matches the demo presence pattern:
/// `demo:presence:` followed by 32 lowercase hexadecimal characters.
pub fn valid_topic(topic: String) -> Bool {
  case string.split(topic, ":") {
    ["demo", "presence", id] ->
      string.length(id) == 32
      && id
      |> string.to_graphemes
      |> list.all(fn(character) {
        string.contains("0123456789abcdef", character)
      })
    _ -> False
  }
}

/// Validate join fields exposed for unit tests. Returns `Ok(Nil)` when every
/// value is valid, or `Error(json)` describing the first violation.
pub fn validate_join(
  client_id client_id: String,
  compatibility_version compatibility_version: Int,
  name name: String,
  color color: String,
) -> Result(Nil, Json) {
  JoinPayload(client_id:, compatibility_version:, name:, color:)
  |> validate_payload
  |> result.replace(Nil)
}

fn validate_payload(payload: JoinPayload) -> Result(JoinPayload, Json) {
  let name_length = string.length(payload.name)
  use <- bool.guard(
    string.length(payload.client_id) != 36,
    Error(error_with_code(422, "invalid client_id")),
  )
  use <- bool.guard(
    payload.compatibility_version != config.compatibility_version,
    Error(error_with_code(409, "unsupported compatibility_version")),
  )
  use <- bool.guard(
    name_length < 1 || name_length > 40,
    Error(error_with_code(422, "invalid name")),
  )
  case payload.color {
    "emerald" | "magenta" -> Ok(payload)
    _ -> Error(error_with_code(422, "invalid color"))
  }
}

fn payload_decoder() -> decode.Decoder(JoinPayload) {
  use client_id <- decode.field("client_id", decode.string)
  use compatibility_version <- decode.field("compatibility_version", decode.int)
  use name <- decode.field("name", decode.string)
  use color <- decode.field("color", decode.string)
  decode.success(JoinPayload(client_id:, compatibility_version:, name:, color:))
}

/// Error payload returned to the client on a rejected join or unknown event.
fn error_with_code(code: Int, message: String) -> Json {
  json.object([#("code", json.int(code)), #("error", json.string(message))])
}

/// Build the presence channel handler for `demo:presence:*` topics.
pub fn handler(presence_actor: Presence, expiry_actor: Expiry) -> Handler {
  channel.handler("demo:presence:*", fn(context) {
    case validate_request(context, expiry_actor) {
      Error(reason) -> channel.reject(reason)
      Ok(payload) -> accept(context, payload, presence_actor, expiry_actor)
    }
  })
}

fn validate_request(
  context: channel.JoinContext(Info),
  expiry_actor: Expiry,
) -> Result(JoinPayload, Json) {
  use <- bool.guard(
    !valid_topic(context.topic),
    Error(error_with_code(404, "unknown topic")),
  )
  use <- bool.guard(
    expiry.is_expired(expiry_actor, context.topic),
    Error(error_with_code(410, "scenario expired")),
  )
  use payload <- result.try(
    decode.run(context.payload, payload_decoder())
    |> result.replace_error(error_with_code(422, "invalid join payload")),
  )
  validate_payload(payload)
}

/// Accept a validated join.
///
/// The reply carries the topic's presence snapshot from before this socket is
/// tracked; the `presence_track` action then broadcasts this socket's own join
/// diff to every subscriber, including this socket. When the topic closes for
/// any reason the runtime untracks this socket's presence on that topic only.
fn accept(
  context: channel.JoinContext(Info),
  payload: JoinPayload,
  presence_actor: Presence,
  expiry_actor: Expiry,
) -> channel.JoinResult(Nil, Info) {
  let self = context.self
  expiry.track(expiry_actor, context.topic, context.socket_id, fn() {
    channel.notify(self, Expire)
  })
  let snapshot =
    presence.list(presence_actor, context.topic)
    |> result.unwrap([])
  let meta =
    json.object([
      #("name", json.string(payload.name)),
      #("color", json.string(payload.color)),
    ])
  let reply =
    json.object([
      #("client_id", json.string(payload.client_id)),
      #("compatibility_version", json.int(config.compatibility_version)),
      #("presence_state", presence_wire.encode_state(snapshot)),
    ])

  channel.accept(Nil)
  |> channel.with_reply(reply)
  |> channel.with_actions([channel.presence_track(payload.client_id, meta)])
  |> channel.on_message(fn(state, message) {
    channel.next(state, [
      channel.reply_error(message.reply, error_with_code(404, "unknown event")),
    ])
  })
  |> channel.on_info(fn(_state, info) {
    case info {
      Expire -> channel.close([])
    }
  })
  |> channel.on_terminate(fn(_state, _reason) {
    expiry.untrack(expiry_actor, context.topic, context.socket_id)
    []
  })
}
