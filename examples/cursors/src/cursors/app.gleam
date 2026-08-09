//// Cursor-channel logic for app-side dispatch.
////
//// Two layers share one source of truth:
////
//// - A topic-scoped `Model`/`join`/`update`/`closed` surface that a
////   composing app (see the showcase example) routes `cursor:*` events
////   through, storing the returned model per topic.
//// - A socket-wide `Standalone` model plus `standalone_init`/
////   `standalone_update` wrappers that drive the standalone cursors server
////   through a `beryl.child_spec` runtime, reusing the same per-topic surface.

import beryl/event.{type Effect, type Ref}
import example_helpers/color
import example_helpers/payload
import example_helpers/session_presence
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

pub type Ctx {
  Ctx(presence: session_presence.Tracker)
}

const supported_reactions = ["👍", "❤️", "😂", "🎉", "🔥"]

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

  let reply =
    json.object([
      #("socket_id", json.string(socket_id)),
      #("username", json.string(username)),
      #("color", json.string(color)),
    ])
  session_presence.track(ctx.presence, topic, socket_id, meta)
  #(Some(Model(username: username, color: color)), [
    event.AcceptJoin(ref, Some(reply)),
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
            event.BroadcastFrom(topic, "reaction", reaction_payload),
          ])
        }
        None -> #(model, [])
      }
    _ -> #(model, [])
  }
}

/// Handle the topic closing (leave, kick, crash, or disconnect).
pub fn closed(
  ctx: Ctx,
  socket_id: String,
  topic: String,
  _model: Model,
) -> List(Effect) {
  session_presence.untrack(ctx.presence, topic, socket_id)
  []
}

// --- Standalone app-side dispatch wrapper ---

/// Socket-wide state for the standalone cursors server: one per-topic
/// `Model` per joined `cursor:*` topic, keyed by topic.
pub type Standalone {
  Standalone(socket_id: String, cursors: Dict(String, Model))
}

/// `init` for the standalone cursors app-dispatch runtime.
pub fn standalone_init(
  info: event.ConnectInfo(Nil),
) -> #(Standalone, List(Effect)) {
  #(Standalone(socket_id: info.socket_id, cursors: dict.new()), [])
}

/// `update` for the standalone cursors app-dispatch runtime: route
/// each event to the embeddable `join`/`update`/`closed` surface, keyed by
/// topic. Non-`cursor:*` joins are rejected (fail closed), preserving the
/// example's topic-namespace boundary.
pub fn standalone_update(
  ctx: Ctx,
  model: Standalone,
  ev: event.Event(Nil),
) -> event.Next(Standalone, Nil) {
  case ev {
    event.Join(topic, payload, ref) ->
      case topic {
        "cursor:" <> _ -> {
          let #(joined, effects) =
            join(ctx, model.socket_id, topic, payload, ref)
          case joined {
            Some(sub) ->
              event.Next(
                Standalone(
                  ..model,
                  cursors: dict.insert(model.cursors, topic, sub),
                ),
                effects,
              )
            None -> event.Next(model, effects)
          }
        }
        _ ->
          event.Next(model, [
            event.RejectJoin(
              ref,
              json.object([#("reason", json.string("unknown_topic"))]),
            ),
          ])
      }

    event.Message(topic, event_name, payload, _ref) ->
      case dict.get(model.cursors, topic) {
        Ok(sub) -> {
          let #(sub, effects) =
            update(ctx, model.socket_id, topic, sub, event_name, payload)
          event.Next(
            Standalone(..model, cursors: dict.insert(model.cursors, topic, sub)),
            effects,
          )
        }
        Error(Nil) -> event.Next(model, [])
      }

    event.Closed(topic, _reason) ->
      case dict.get(model.cursors, topic) {
        Ok(sub) ->
          event.Next(
            Standalone(..model, cursors: dict.delete(model.cursors, topic)),
            closed(ctx, model.socket_id, topic, sub),
          )
        Error(Nil) -> event.Next(model, [])
      }

    event.Binary(_, _) | event.Info(_) -> event.Next(model, [])
  }
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
