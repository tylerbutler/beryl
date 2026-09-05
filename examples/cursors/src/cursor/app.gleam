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
import example_helper/color
import example_helper/payload
import example_helper/session_presence
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/result

/// Per-topic state for one socket in a cursor room.
pub type Model {
  Model(username: String, color: String)
}

pub type Context {
  Context(presence: session_presence.Tracker)
}

pub type Note {
  PublishRoster(topic: String)
}

const supported_reactions = ["👍", "❤️", "😂", "🎉", "🔥"]

/// Handle a join for a `cursor:*` topic.
pub fn join(
  context: Context,
  socket_id: String,
  topic: String,
  payload: Dynamic,
  ref: JoinRef,
) -> #(Model, List(Effect)) {
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
  session_presence.track_without_publish(
    context.presence,
    topic,
    socket_id,
    meta,
  )
  #(Model(username: username, color: color), [
    socket.AcceptJoin(ref, Some(reply)),
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
          #("x", payload.json_number_or_zero(payload, "x")),
          #("y", payload.json_number_or_zero(payload, "y")),
          #("username", json.string(model.username)),
          #("color", json.string(model.color)),
        ])
      #(model, [socket.BroadcastFrom(topic, "cursor_move", move_payload)])
    }
    "reaction" ->
      case decode_reaction(payload) {
        Ok(#(reaction, x, y)) -> {
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
        Error(Nil) -> #(model, [])
      }
    _ -> #(model, [])
  }
}

/// Handle the topic closing (leave, kick, crash, or disconnect).
pub fn closed(
  context: Context,
  socket_id: String,
  topic: String,
  _model: Model,
) -> List(Effect) {
  session_presence.untrack(context.presence, topic, socket_id)
  []
}

// --- Socket-wide model and dispatch ---

/// Socket-wide model for the standalone cursors server: the socket id plus
/// one per-topic `Model` per joined `cursor:*` topic.
pub type CursorRooms {
  CursorRooms(
    socket_id: String,
    self: socket.Sender(Note),
    topics: Dict(String, Model),
  )
}

/// `init` for the `beryl.child_spec` runtime.
pub fn cursor_rooms_init(
  info: socket.ConnectInfo(Note),
) -> #(CursorRooms, List(Effect)) {
  #(
    CursorRooms(socket_id: info.socket_id, self: info.self, topics: dict.new()),
    [],
  )
}

/// Build the raw socket update. A join's model is committed only when the
/// join is accepted.
pub fn cursor_rooms_update(
  context: Context,
) -> fn(CursorRooms, socket.Input(Note)) -> socket.Next(CursorRooms) {
  let pattern = topic.parse_pattern("cursor:*")
  fn(state: CursorRooms, input) {
    case input {
      socket.Join(topic_name, payload, ref) ->
        case topic.matches(pattern, topic_name) {
          False ->
            socket.Next(state, [
              socket.RejectJoin(ref, unknown_topic()),
            ])
          True -> {
            let #(model, effects) =
              join(context, state.socket_id, topic_name, payload, ref)
            socket.notify(state.self, PublishRoster(topic_name))
            socket.Next(
              CursorRooms(
                ..state,
                topics: dict.insert(state.topics, topic_name, model),
              ),
              effects,
            )
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
                context,
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
          False, Ok(_) | False, Error(_) | True, Error(_) ->
            socket.Next(state, [])
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
              closed(context, state.socket_id, topic_name, model),
            )
          False, Ok(_) | False, Error(_) | True, Error(_) ->
            socket.Next(state, [])
        }

      socket.Binary(_, _) -> socket.Next(state, [])

      socket.Info(PublishRoster(topic_name)) -> {
        session_presence.publish(context.presence, topic_name)
        socket.Next(state, [])
      }
    }
  }
}

fn unknown_topic() -> json.Json {
  json.object([#("reason", json.string("unknown_topic"))])
}

fn decode_reaction(payload: Dynamic) -> Result(#(String, Float, Float), Nil) {
  use reaction <- result.try(payload.string_field(payload, "reaction"))
  use x <- result.try(payload.float_field(payload, "x"))
  use y <- result.try(payload.float_field(payload, "y"))
  case
    list.contains(supported_reactions, reaction)
    && coordinate_in_range(x)
    && coordinate_in_range(y)
  {
    True -> Ok(#(reaction, x, y))
    False -> Error(Nil)
  }
}

fn coordinate_in_range(value: Float) -> Bool {
  value >=. 0.0 && value <=. 1.0
}
