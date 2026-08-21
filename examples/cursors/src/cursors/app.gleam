//// Cursor-channel logic for app-side dispatch.
////
//// This example deliberately uses raw dispatch. It shows
//// `beryl.child_spec` driven by direct `socket.Input` matching, with
//// `beryl/topic` matching topics and the app owning its own model.
//// Applications composing several channels should prefer `beryl/channel`
//// (see the showcase example), which keeps each channel's state and
//// server-side message type private and needs no hand-written dispatch.
////
//// Two layers share one source of truth:
////
//// - A topic-scoped `Model`/`join`/`update`/`closed` surface holding the
////   actual cursor logic.
//// - A socket-wide `CursorRooms` model plus `cursor_rooms_init`/
////   `cursor_rooms_update` wrappers that drive the standalone cursors server
////   through a `beryl.child_spec` runtime, reusing that per-topic surface.

import beryl/socket.{type Effect, type JoinRef}
import beryl/topic
import example_helpers/color
import example_helpers/payload
import example_helpers/session_presence
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
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
  ref: JoinRef,
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
  let roster =
    session_presence.track_snapshot(ctx.presence, topic, socket_id, meta)
  #(Some(Model(username: username, color: color)), [
    socket.AcceptJoin(ref, Some(reply)),
    socket.Broadcast(topic, "presence_list", roster),
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
          #("x", payload.json_number_or_zero(payload, "x")),
          #("y", payload.json_number_or_zero(payload, "y")),
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
  ctx: Ctx,
  socket_id: String,
  topic: String,
  _model: Model,
) -> List(Effect) {
  session_presence.untrack(ctx.presence, topic, socket_id)
  []
}

// --- Socket-wide model and dispatch ---

/// Socket-wide model for the standalone cursors server: the socket id plus
/// one per-topic `Model` per joined `cursor:*` topic.
pub type CursorRooms {
  CursorRooms(socket_id: String, topics: Dict(String, Model))
}

/// `init` for the `beryl.child_spec` runtime.
pub fn cursor_rooms_init(
  info: socket.ConnectInfo(Nil),
) -> #(CursorRooms, List(Effect)) {
  #(CursorRooms(socket_id: info.socket_id, topics: dict.new()), [])
}

/// Build the raw socket update. A join's model is committed only when the
/// join is accepted.
pub fn cursor_rooms_update(
  ctx: Ctx,
) -> fn(CursorRooms, socket.Input(Nil)) -> socket.Next(CursorRooms) {
  let pattern = topic.parse_pattern("cursor:*")
  fn(state: CursorRooms, input) {
    case input {
      socket.Join(topic_name, payload, ref) ->
        case topic.matches(pattern, topic_name) {
          False ->
            socket.Next(state, [
              socket.RejectJoin(ref, unknown_topic()),
            ])
          True ->
            case join(ctx, state.socket_id, topic_name, payload, ref) {
              #(Some(model), effects) ->
                socket.Next(
                  CursorRooms(
                    ..state,
                    topics: dict.insert(state.topics, topic_name, model),
                  ),
                  effects,
                )
              #(None, effects) -> socket.Next(state, effects)
            }
        }

      socket.Message(topic_name, event_name, payload, _ref) ->
        case
          topic.matches(pattern, topic_name),
          dict.get(state.topics, topic_name)
        {
          True, Ok(model) -> {
            let #(model, effects) =
              update(
                ctx,
                state.socket_id,
                topic_name,
                model,
                event_name,
                payload,
              )
            socket.Next(
              CursorRooms(
                ..state,
                topics: dict.insert(state.topics, topic_name, model),
              ),
              effects,
            )
          }
          _, _ -> socket.Next(state, [])
        }

      socket.Closed(topic_name, _reason) ->
        case
          topic.matches(pattern, topic_name),
          dict.get(state.topics, topic_name)
        {
          True, Ok(model) ->
            socket.Next(
              CursorRooms(
                ..state,
                topics: dict.delete(state.topics, topic_name),
              ),
              closed(ctx, state.socket_id, topic_name, model),
            )
          _, _ -> socket.Next(state, [])
        }

      socket.Binary(_, _) | socket.Info(_) -> socket.Next(state, [])
    }
  }
}

fn unknown_topic() -> json.Json {
  json.object([#("reason", json.string("unknown_topic"))])
}

fn decode_reaction(payload: Dynamic) -> Option(#(String, Float, Float)) {
  case
    payload.string_field(payload, "reaction"),
    payload.float_field(payload, "x"),
    payload.float_field(payload, "y")
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

fn coordinate_in_range(value: Float) -> Bool {
  value >=. 0.0 && value <=. 1.0
}
