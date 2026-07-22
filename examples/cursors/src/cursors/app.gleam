//// Embeddable cursor-channel logic for app-side dispatch (ADR 0002).
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
  ctx: Ctx,
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

  // Presence effects apply after this update returns, so the broadcast
  // list is built from the current presence plus the joining user.
  let users_json =
    presence_list_json(ctx, topic, including: [#(socket_id, meta)], except: [])

  let reply =
    json.object([
      #("socket_id", json.string(socket_id)),
      #("username", json.string(username)),
      #("color", json.string(color)),
    ])
  #(Some(Model(username: username, color: color)), [
    event.AcceptJoin(ref, Some(reply)),
    event.PresenceTrack(topic, username, meta),
    event.Broadcast(topic, "presence_list", users_json),
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
  ctx: Ctx,
  socket_id: String,
  topic: String,
  model: Model,
) -> List(Effect) {
  // The untrack effect applies after this update returns, so the
  // broadcast list is the current presence minus the leaving socket.
  let users_json =
    presence_list_json(ctx, topic, including: [], except: [socket_id])
  [
    event.PresenceUntrack(topic, model.username),
    event.Broadcast(topic, "presence_list", users_json),
  ]
}

/// Build the `presence_list` payload from the presence actor's current
/// state, adjusted for effects in the same list that have not applied yet.
fn presence_list_json(
  ctx: Ctx,
  topic: String,
  including including: List(#(String, json.Json)),
  except except: List(String),
) -> json.Json {
  let current =
    presence.list(ctx.presence, topic)
    |> list.filter(fn(entry) { !list.contains(except, entry.session_id) })
    |> list.map(fn(entry) { #(entry.session_id, entry.meta) })
  let additions =
    list.filter(including, fn(added) {
      let #(session_id, _meta) = added
      !list.any(current, fn(entry) { entry.0 == session_id })
    })
  json.object(list.append(current, additions))
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
