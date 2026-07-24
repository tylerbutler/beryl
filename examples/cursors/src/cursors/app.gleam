//// Cursor-channel logic for app-side dispatch.
////
//// Two layers share one source of truth:
////
//// - A topic-scoped `Model`/`join`/`update`/`closed` surface that a
////   composing app (see the showcase example) routes `cursor:*` events
////   through, storing the returned model per topic.
//// - A socket-wide `Standalone` model plus `standalone_init`/
////   `standalone_update` wrappers that drive the standalone cursors server
////   through `beryl.start`, reusing the same per-topic surface.

import beryl/presence.{type Presence}
import beryl/socket.{type Effect, type Ref}
import example_helpers/color
import example_helpers/payload
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

/// Per-topic state for one socket in a cursor room.
pub type Model {
  Model(username: String, color: String)
}

/// Dependencies the cursor logic reads (presence is written through
/// effects; the handle is only needed for reads like `presence.list`).
pub type Context {
  Context(presence: Presence)
}

const supported_reactions = ["👍", "❤️", "😂", "🎉", "🔥"]

/// Handle a join for a `cursor:*` topic. Returns `None` when rejected.
pub fn join(
  _context: Context,
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
    socket.AcceptJoin(ref, Some(reply)),
    socket.PresenceTrack(topic, username, meta),
    socket.BroadcastPresence(topic, "presence_list", encode_users),
  ])
}

/// Handle a client message on a joined `cursor:*` topic.
pub fn update(
  _context: Context,
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
      #(model, [socket.BroadcastFrom(topic, "cursor_move", move_payload)])
    }
    "reaction" ->
      case decode_reaction(payload) {
        Some(#(reaction, x, y)) -> {
          let reaction_payload =
            json.object([
              #("reaction", json.string(reaction)),
              #("x", json.float(x)),
              #("y", json.float(y)),
            ])
          #(model, [
            socket.BroadcastFrom(topic, "reaction", reaction_payload),
          ])
        }
        None -> #(model, [])
      }
    _ -> #(model, [])
  }
}

/// Handle the topic closing (leave, kick, crash, or disconnect).
pub fn closed(
  _context: Context,
  _socket_id: String,
  topic: String,
  model: Model,
) -> List(Effect) {
  // The snapshot encodes after the untrack before it, so the broadcast
  // list already excludes the leaving user.
  [
    socket.PresenceUntrack(topic, model.username),
    socket.BroadcastPresence(topic, "presence_list", encode_users),
  ]
}

// --- Standalone app-side dispatch wrapper ---

/// Socket-wide state for the standalone cursors server: one per-topic
/// `Model` per joined `cursor:*` topic, keyed by topic.
pub type Standalone {
  Standalone(socket_id: String, cursors: Dict(String, Model))
}

/// `init` for the standalone cursors `beryl.start` runtime.
pub fn standalone_init(
  info: socket.ConnectInfo(Nil),
) -> #(Standalone, List(Effect)) {
  #(Standalone(socket_id: info.socket_id, cursors: dict.new()), [])
}

/// `update` for the standalone cursors `beryl.start` runtime: route
/// each event to the embeddable `join`/`update`/`closed` surface, keyed by
/// topic. Non-`cursor:*` joins are rejected (fail closed), mirroring the old
/// `cursor:*` handler registration.
pub fn standalone_update(
  context: Context,
  model: Standalone,
  ev: socket.Input(Nil),
) -> socket.Next(Standalone, Nil) {
  case ev {
    socket.Join(topic, payload, ref) ->
      case topic {
        "cursor:" <> _ -> {
          let #(joined, effects) =
            join(context, model.socket_id, topic, payload, ref)
          case joined {
            Some(sub) ->
              socket.Next(
                Standalone(
                  ..model,
                  cursors: dict.insert(model.cursors, topic, sub),
                ),
                effects,
              )
            None -> socket.Next(model, effects)
          }
        }
        _ ->
          socket.Next(model, [
            socket.RejectJoin(
              ref,
              json.object([#("reason", json.string("unknown_topic"))]),
            ),
          ])
      }

    socket.Message(topic, event_name, payload, _ref) ->
      case dict.get(model.cursors, topic) {
        Ok(sub) -> {
          let #(sub, effects) =
            update(context, model.socket_id, topic, sub, event_name, payload)
          socket.Next(
            Standalone(..model, cursors: dict.insert(model.cursors, topic, sub)),
            effects,
          )
        }
        Error(Nil) -> socket.Next(model, [])
      }

    socket.Closed(topic, _reason) ->
      case dict.get(model.cursors, topic) {
        Ok(sub) ->
          socket.Next(
            Standalone(..model, cursors: dict.delete(model.cursors, topic)),
            closed(context, model.socket_id, topic, sub),
          )
        Error(Nil) -> socket.Next(model, [])
      }

    socket.Binary(_, _) | socket.Info(_) -> socket.Next(model, [])
  }
}

/// Encode presence entries as the `presence_list` payload:
/// `{session_id: meta}`.
fn encode_users(entries: List(presence.PresenceEntry)) -> json.Json {
  json.object(list.map(entries, fn(entry) { #(entry.session_id, entry.meta) }))
}

fn decode_reaction(payload: Dynamic) -> Option(#(String, Float, Float)) {
  let reaction_decoder = {
    use reaction <- decode.field("reaction", decode.string)
    decode.success(reaction)
  }

  case
    decode.run(payload, reaction_decoder),
    decode_number(payload, "x"),
    decode_number(payload, "y")
  {
    Ok(reaction), Ok(x), Ok(y) -> {
      let valid =
        list.contains(supported_reactions, reaction)
        && coordinate_in_range(x)
        && coordinate_in_range(y)
      case valid {
        True -> Some(#(reaction, x, y))
        False -> None
      }
    }
    _, _, _ -> None
  }
}

fn decode_number(payload: Dynamic, field_name: String) -> Result(Float, Nil) {
  let float_decoder = {
    use value <- decode.field(field_name, decode.float)
    decode.success(value)
  }
  case decode.run(payload, float_decoder) {
    Ok(value) -> Ok(value)
    Error(_) -> {
      let int_decoder = {
        use value <- decode.field(field_name, decode.int)
        decode.success(value)
      }
      case decode.run(payload, int_decoder) {
        Ok(value) -> Ok(int.to_float(value))
        Error(_) -> Error(Nil)
      }
    }
  }
}

fn coordinate_in_range(value: Float) -> Bool {
  value >=. 0.0 && value <=. 1.0
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
