//// Embeddable cursor-channel logic for app-side dispatch.
////
//// A topic-scoped `Model`/`join`/`update`/`closed` triple: a composing
//// app (see the showcase example) routes `cursor:*` events here and
//// stores the returned model per topic. Mirrors the behavior of
//// `cursors/cursor_channel` on the channel-module API.

import beryl/event.{type Effect, type Ref}
import beryl/presence.{type Presence}
import example_helpers/color
import example_helpers/payload
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}

/// Per-topic state for one socket in a cursor room.
pub type Model {
  Model(username: String, color: String)
}

/// Dependencies the cursor logic reads (presence is written through
/// effects; the handle is only needed for reads like `presence.list`).
pub type Ctx {
  Ctx(presence: Presence)
}

/// Handle a join for a `cursor:*` topic. Returns `None` when rejected.
pub fn join(
  _ctx: Ctx,
  socket_id: String,
  topic: String,
  payload: Dynamic,
  ref: Ref,
) -> #(Option(Model), List(Effect)) {
  let username = payload.string_or(payload, "username", "Anonymous")
  let color = color.pastel_for(socket_id)
  let meta =
    json.object([
      #("username", json.string(username)),
      #("color", json.string(color)),
    ])

  let reply =
    json.object([
      #("socket_id", json.string(socket_id)),
      #("username", json.string(username)),
      #("color", json.string(color)),
    ])
  // BroadcastPresence encodes at apply time, after the PresenceTrack
  // before it — so the list already includes the joining user.
  #(Some(Model(username: username, color: color)), [
    event.AcceptJoin(ref, Some(reply)),
    event.PresenceTrack(topic, username, meta),
    event.BroadcastPresence(topic, "presence_list", encode_users),
  ])
}

/// Handle a client message on a joined `cursor:*` topic.
pub fn update(
  _ctx: Ctx,
  socket_id: String,
  topic: String,
  model: Model,
  event_name: String,
  payload: Dynamic,
) -> #(Model, List(Effect)) {
  case event_name {
    "cursor_move" -> {
      let move_payload =
        json.object([
          #("socket_id", json.string(socket_id)),
          #("x", extract_json_number(payload, "x")),
          #("y", extract_json_number(payload, "y")),
          #("username", json.string(model.username)),
          #("color", json.string(model.color)),
        ])
      #(model, [event.BroadcastFrom(topic, "cursor_move", move_payload)])
    }
    _ -> #(model, [])
  }
}

/// Handle the topic closing (leave, kick, crash, or disconnect).
pub fn closed(
  _ctx: Ctx,
  _socket_id: String,
  topic: String,
  model: Model,
) -> List(Effect) {
  // The snapshot encodes after the untrack before it, so the broadcast
  // list already excludes the leaving user.
  [
    event.PresenceUntrack(topic, model.username),
    event.BroadcastPresence(topic, "presence_list", encode_users),
  ]
}

/// Encode presence entries as the `presence_list` payload:
/// `{session_id: meta}`.
fn encode_users(entries: List(presence.PresenceEntry)) -> json.Json {
  json.object(list.map(entries, fn(entry) { #(entry.session_id, entry.meta) }))
}

/// Extract a number from a JSON payload as Json, defaulting to 0.0.
fn extract_json_number(payload: Dynamic, field_name: String) -> json.Json {
  let float_decoder = {
    use value <- decode.field(field_name, decode.float)
    decode.success(value)
  }
  case decode.run(payload, float_decoder) {
    Ok(value) -> json.float(value)
    Error(_) -> {
      let int_decoder = {
        use value <- decode.field(field_name, decode.int)
        decode.success(value)
      }
      case decode.run(payload, int_decoder) {
        Ok(value) -> json.int(value)
        Error(_) -> json.float(0.0)
      }
    }
  }
}
