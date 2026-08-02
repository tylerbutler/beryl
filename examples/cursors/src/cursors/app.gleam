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

import beryl/socket.{type Effect, type Ref}
import example_helpers/color
import example_helpers/payload
import example_helpers/presence as presence_helpers
import example_helpers/router
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Per-topic state for one socket in a cursor room.
pub type Model {
  Model(username: String, color: String)
}

const supported_reactions = ["👍", "❤️", "😂", "🎉", "🔥"]

/// Handle a join for a `cursor:*` topic. Returns `None` when rejected.
pub fn join(
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
    socket.BroadcastPresence(
      topic,
      "presence_list",
      presence_helpers.encode_users,
    ),
  ])
}

/// Handle a client message on a joined `cursor:*` topic.
pub fn update(
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
pub fn closed(_socket_id: String, topic: String, model: Model) -> List(Effect) {
  // The snapshot encodes after the untrack before it, so the broadcast
  // list already excludes the leaving user.
  [
    socket.PresenceUntrack(topic, model.username),
    socket.BroadcastPresence(
      topic,
      "presence_list",
      presence_helpers.encode_users,
    ),
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

/// The `cursor:*` namespace, adapted to whatever socket-wide model holds it.
///
/// `socket_id`, `get`, and `put` project that model onto the pieces this app
/// owns, so the standalone server below and the composing showcase app share
/// one adapter instead of writing the same dict plumbing twice.
pub fn namespace(
  socket_id socket_id: fn(model) -> String,
  get get: fn(model) -> Dict(String, Model),
  put put: fn(model, Dict(String, Model)) -> model,
) -> router.Namespace(model) {
  router.stateful(
    matches: string.starts_with(_, "cursor:"),
    socket_id:,
    get:,
    put:,
    join:,
    message: fn(socket_id, topic, model, event_name, payload, _ref) {
      update(socket_id, topic, model, event_name, payload)
    },
    closed:,
  )
}

/// `update` for the standalone cursors `beryl.start` runtime. Topics
/// outside the registered namespaces are rejected (fail closed).
pub fn standalone_update(
  model: Standalone,
  ev: socket.Input(Nil),
) -> socket.Next(Standalone, Nil) {
  let cursors =
    namespace(
      socket_id: fn(model: Standalone) { model.socket_id },
      get: fn(model: Standalone) { model.cursors },
      put: fn(model: Standalone, cursors) {
        Standalone(..model, cursors: cursors)
      },
    )
  router.route([cursors], router.unknown_topic(), model, ev)
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
