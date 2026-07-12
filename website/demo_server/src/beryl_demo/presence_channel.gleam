//// Validated presence channel handler for the beryl demo service.
////
//// The channel enforces the demo topic format, validates every field of the
//// join payload, tracks presence for the socket, and expires scenarios after
//// their absolute TTL by handling an `Expire` info message.

import beryl.{type Channels}
import beryl/channel.{type Channel}
import beryl/presence.{type Presence}
import beryl/presence/wire as presence_wire
import beryl/socket.{type Socket}
import beryl_demo/config
import beryl_demo/expiry.{type Expiry}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{Some}
import gleam/string

/// Socket assigns retained across `join`, `handle_info`, and `terminate`.
pub type Assigns {
  Assigns(presence: Presence, expiry: Expiry, topic: String)
}

/// Server-originated messages delivered to `handle_info`.
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
  case
    JoinPayload(
      client_id: client_id,
      compatibility_version: compatibility_version,
      name: name,
      color: color,
    )
    |> validate_payload
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

fn validate_payload(payload: JoinPayload) -> Result(JoinPayload, Json) {
  case string.length(payload.client_id) == 36 {
    False -> Error(channel.error_with_code(422, "invalid client_id"))
    True ->
      case payload.compatibility_version == config.compatibility_version {
        False ->
          Error(channel.error_with_code(
            409,
            "unsupported compatibility_version",
          ))
        True -> {
          let name_length = string.length(payload.name)
          case name_length >= 1 && name_length <= 40 {
            False -> Error(channel.error_with_code(422, "invalid name"))
            True ->
              case payload.color {
                "emerald" | "magenta" -> Ok(payload)
                _ -> Error(channel.error_with_code(422, "invalid color"))
              }
          }
        }
      }
  }
}

fn payload_decoder() -> decode.Decoder(JoinPayload) {
  use client_id <- decode.field("client_id", decode.string)
  use compatibility_version <- decode.field("compatibility_version", decode.int)
  use name <- decode.field("name", decode.string)
  use color <- decode.field("color", decode.string)
  decode.success(JoinPayload(
    client_id: client_id,
    compatibility_version: compatibility_version,
    name: name,
    color: color,
  ))
}

/// Build the presence channel handler for `demo:presence:*` topics.
///
/// The `channels` handle is currently unused inside the handler (all diffs are
/// broadcast from the presence `on_diff` callback in `server.gleam`) but is
/// accepted to keep the constructor stable when future events need it.
pub fn new(
  channels channels: Channels,
  presence_actor presence_actor: Presence,
  expiry_actor expiry_actor: Expiry,
) -> Channel(Assigns, Info) {
  let _ = channels

  channel.new(fn(topic, payload, socket) {
    join(topic, payload, socket, presence_actor, expiry_actor)
  })
  |> channel.with_handle_in(handle_in)
  |> channel.with_handle_info(handle_info)
  |> channel.with_terminate(terminate)
}

fn join(
  topic: String,
  payload: Dynamic,
  client_socket: Socket(Assigns),
  presence_actor: Presence,
  expiry_actor: Expiry,
) -> channel.JoinResult(Assigns) {
  case valid_topic(topic) {
    False -> channel.JoinError(channel.error_with_code(404, "unknown topic"))
    True ->
      case expiry.is_expired(expiry_actor, topic) {
        True ->
          channel.JoinError(channel.error_with_code(410, "scenario expired"))
        False ->
          decode_and_join(
            topic,
            payload,
            client_socket,
            presence_actor,
            expiry_actor,
          )
      }
  }
}

fn decode_and_join(
  topic: String,
  payload: Dynamic,
  client_socket: Socket(Assigns),
  presence_actor: Presence,
  expiry_actor: Expiry,
) -> channel.JoinResult(Assigns) {
  case channel.decode_payload(payload, payload_decoder()) {
    Error(_) ->
      channel.JoinError(channel.error_with_code(422, "invalid join payload"))
    Ok(decoded) ->
      case validate_payload(decoded) {
        Error(reason) -> channel.JoinError(reason)
        Ok(valid) ->
          track_and_reply(
            topic,
            valid,
            client_socket,
            presence_actor,
            expiry_actor,
          )
      }
  }
}

fn track_and_reply(
  topic: String,
  payload: JoinPayload,
  client_socket: Socket(Assigns),
  presence_actor: Presence,
  expiry_actor: Expiry,
) -> channel.JoinResult(Assigns) {
  let socket_id = socket.id(client_socket)
  let meta =
    json.object([
      #("name", json.string(payload.name)),
      #("color", json.string(payload.color)),
    ])
  let _ref =
    presence.track(presence_actor, topic, payload.client_id, socket_id, meta)
  expiry.track(expiry_actor, topic, socket_id)

  let assigns =
    Assigns(presence: presence_actor, expiry: expiry_actor, topic: topic)
  let updated_socket = socket.set_assigns(client_socket, assigns)

  let reply =
    json.object([
      #("client_id", json.string(payload.client_id)),
      #("compatibility_version", json.int(config.compatibility_version)),
      #(
        "presence_state",
        presence_wire.encode_state(presence.list(presence_actor, topic)),
      ),
    ])
  channel.JoinOk(reply: Some(reply), socket: updated_socket)
}

fn handle_in(
  _event: String,
  _payload: Dynamic,
  client_socket: Socket(Assigns),
) -> channel.HandleResult(Assigns) {
  channel.ReplyError(
    channel.error_with_code(404, "unknown event"),
    client_socket,
  )
}

fn handle_info(
  message: Info,
  _client_socket: Socket(Assigns),
) -> channel.HandleResult(Assigns) {
  case message {
    Expire -> channel.Stop(channel.Shutdown)
  }
}

fn terminate(
  _reason: channel.StopReason,
  client_socket: Socket(Assigns),
) -> Nil {
  let assigns = socket.get_assigns(client_socket)
  let socket_id = socket.id(client_socket)
  expiry.untrack(assigns.expiry, assigns.topic, socket_id)
  presence.untrack_all(assigns.presence, socket_id)
  Nil
}
