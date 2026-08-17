//// Cursor-channel logic for app-side dispatch.
////
//// This example is deliberately the one built without `beryl_channels`: it
//// shows `beryl.child_spec` driven by a hand-written `update`, with
//// `beryl/socket/router` matching topics and the app owning its own model.
//// Applications composing several channels should prefer `beryl_channels`
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
import beryl/socket/router
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
  session_presence.track(ctx.presence, topic, socket_id, meta)
  #(Some(Model(username: username, color: color)), [
    socket.AcceptJoin(ref, Some(reply)),
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
///
/// The app owns this type. `beryl/socket/router` only decides which
/// namespace an input belongs to; storing per-topic state is the app's job,
/// which is what keeps the router itself free of any state-shape opinion.
pub type CursorRooms {
  CursorRooms(socket_id: String, topics: Dict(String, Model))
}

/// `init` for the `beryl.child_spec` runtime.
pub fn cursor_rooms_init(
  info: socket.ConnectInfo(Nil),
) -> #(CursorRooms, List(Effect)) {
  #(CursorRooms(socket_id: info.socket_id, topics: dict.new()), [])
}

/// Adapt the `cursor:*` handlers to the socket-wide model. A
/// join's model is committed only when the join is accepted.
fn namespace(ctx: Ctx) -> router.Namespace(CursorRooms) {
  router.namespace(
    pattern: "cursor:*",
    join: fn(state: CursorRooms, match: router.Match, payload, ref) {
      case join(ctx, state.socket_id, match.topic, payload, ref) {
        #(Some(model), effects) -> #(
          CursorRooms(
            ..state,
            topics: dict.insert(state.topics, match.topic, model),
          ),
          effects,
        )
        #(None, effects) -> #(state, effects)
      }
    },
    message: fn(
      state: CursorRooms,
      match: router.Match,
      event_name,
      payload,
      _ref,
    ) {
      case dict.get(state.topics, match.topic) {
        Ok(model) -> {
          let #(model, effects) =
            update(
              ctx,
              state.socket_id,
              match.topic,
              model,
              event_name,
              payload,
            )
          #(
            CursorRooms(
              ..state,
              topics: dict.insert(state.topics, match.topic, model),
            ),
            effects,
          )
        }
        Error(Nil) -> #(state, [])
      }
    },
    closed: fn(state: CursorRooms, match: router.Match, _reason) {
      case dict.get(state.topics, match.topic) {
        Ok(model) -> #(
          CursorRooms(..state, topics: dict.delete(state.topics, match.topic)),
          closed(ctx, state.socket_id, match.topic, model),
        )
        Error(Nil) -> #(state, [])
      }
    },
  )
}

/// Build the socket-wide update once, sharing the app-owned model.
pub fn cursor_rooms_update(
  ctx: Ctx,
) -> fn(CursorRooms, socket.Input(Nil)) -> socket.Next(CursorRooms) {
  let namespaces = [namespace(ctx)]
  fn(model, input) {
    router.route(namespaces, router.unknown_topic(), model, input)
  }
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
