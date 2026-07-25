//// Chat-room logic for app-side dispatch.
////
//// Two layers share one source of truth:
////
//// - A topic-scoped `Model`/`join`/`update`/`closed` surface that a
////   composing app (see the showcase example) routes `room:*` events
////   through, storing the returned model per topic.
//// - A socket-wide `Standalone` model plus `standalone_init`/
////   `standalone_update` wrappers that drive the standalone chatrooms
////   server through `beryl.start`, reusing the same per-topic surface.
////
//// Wire behavior matches the original per-topic handler, including its
//// replies (an ok-status reply carrying an error payload).

import beryl/group.{type Groups}
import beryl/presence.{type Presence}
import beryl/socket.{type Effect, type Ref}
import example_helpers/color
import example_helpers/payload
import example_helpers/presence as presence_helpers
import example_helpers/reply
import example_helpers/router
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string

/// Maximum users per room — join rejected when full
const max_room_users = 20

/// Per-topic state for one socket in a chat room.
pub type Model {
  Model(username: String, color: String, room_name: String)
}

/// Dependencies the chat logic reads: the room group for join validation
/// and the presence handle for reads (writes go through effects).
pub type Ctx {
  Ctx(presence: Presence, groups: Groups)
}

/// Handle a join for a `room:*` topic. Returns `None` when rejected.
pub fn join(
  ctx: Ctx,
  socket_id: String,
  topic: String,
  payload: Dynamic,
  ref: Ref,
) -> #(Option(Model), List(Effect)) {
  let room_name = case string.split(topic, ":") {
    [_, name] -> name
    _ -> "unknown"
  }

  // Validate the room exists (must be in the "public" group).
  let room_exists = case group.topics(ctx.groups, "public") {
    Ok(topics) -> set.contains(topics, topic)
    Error(_) -> False
  }

  case room_exists {
    False -> #(None, [
      socket.RejectJoin(ref, error("Room not found: " <> room_name)),
    ])
    True -> {
      let current_users = presence.list(ctx.presence, topic)
      case list.length(current_users) >= max_room_users {
        True -> #(None, [
          socket.RejectJoin(
            ref,
            error_with_code(
              403,
              "Room is full (max " <> int.to_string(max_room_users) <> ")",
            ),
          ),
        ])
        False -> {
          let username = payload.string_or(payload, "username", "Anonymous")
          let color = color.pastel_for(socket_id)
          let meta = presence_meta(username, color, typing: False)

          let sys_payload = system_message(username <> " joined the room")

          let reply =
            json.object([
              #("socket_id", json.string(socket_id)),
              #("username", json.string(username)),
              #("color", json.string(color)),
              #("room", json.string(room_name)),
            ])
          // BroadcastPresence encodes at apply time, after the
          // PresenceTrack before it — the list already includes the
          // joining user.
          #(
            Some(Model(username: username, color: color, room_name: room_name)),
            [
              socket.AcceptJoin(ref, Some(reply)),
              socket.PresenceTrack(topic, username, meta),
              socket.Broadcast(
                "lobby",
                "rooms_changed",
                room_changed(room_name),
              ),
              socket.Broadcast(topic, "new_msg", sys_payload),
              socket.BroadcastPresence(
                topic,
                "presence_list",
                presence_helpers.encode_users,
              ),
            ],
          )
        }
      }
    }
  }
}

/// Handle a client message on a joined `room:*` topic.
pub fn update(
  _ctx: Ctx,
  socket_id: String,
  topic: String,
  model: Model,
  event_name: String,
  payload: Dynamic,
  ref: Option(Ref),
) -> #(Model, List(Effect)) {
  case event_name {
    "new_msg" -> {
      let text = payload.string_or(payload, "text", "")
      case string.trim(text) {
        "" -> #(
          model,
          reply.ok(ref, error_with_code(422, "Message cannot be empty")),
        )
        trimmed -> {
          let msg_payload =
            json.object([
              #("text", json.string(trimmed)),
              #("username", json.string(model.username)),
              #("color", json.string(model.color)),
              #("socket_id", json.string(socket_id)),
              #("type", json.string("user")),
              #("timestamp", json.int(timestamp_ms())),
            ])
          #(
            model,
            list.append(
              [socket.Broadcast(topic, "new_msg", msg_payload)],
              reply.ok(
                ref,
                json.object([
                  #("status", json.string("ok")),
                  #("timestamp", json.int(timestamp_ms())),
                ]),
              ),
            ),
          )
        }
      }
    }

    "typing" -> #(model, typing_effects(model, socket_id, topic, typing: True))
    "stop_typing" -> #(
      model,
      typing_effects(model, socket_id, topic, typing: False),
    )

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
  let sys_payload = system_message(model.username <> " left the room")
  // The snapshot encodes after the untrack before it, so the broadcast
  // list already excludes the leaving user.
  [
    socket.PresenceUntrack(topic, model.username),
    socket.Broadcast("lobby", "rooms_changed", room_changed(model.room_name)),
    socket.Broadcast(topic, "new_msg", sys_payload),
    socket.BroadcastPresence(
      topic,
      "presence_list",
      presence_helpers.encode_users,
    ),
  ]
}

// --- Standalone app-side dispatch wrapper ---

/// Socket-wide state for the standalone chatrooms server: one per-topic
/// `Model` per joined `room:*` topic, keyed by topic. The application-wide
/// `lobby` topic is read-only and carries no state.
pub type Standalone {
  Standalone(socket_id: String, rooms: Dict(String, Model))
}

/// `init` for the standalone chatrooms `beryl.start` runtime.
pub fn standalone_init(
  info: socket.ConnectInfo(Nil),
) -> #(Standalone, List(Effect)) {
  #(Standalone(socket_id: info.socket_id, rooms: dict.new()), [])
}

/// The `room:*` namespace, adapted to whatever socket-wide model holds it.
///
/// `socket_id`, `get`, and `put` project that model onto the pieces this app
/// owns, so the standalone server below and the composing showcase app share
/// one adapter instead of writing the same dict plumbing twice.
pub fn namespace(
  ctx: Ctx,
  socket_id socket_id: fn(model) -> String,
  get get: fn(model) -> Dict(String, Model),
  put put: fn(model, Dict(String, Model)) -> model,
) -> router.Namespace(model) {
  router.Namespace(
    matches: fn(topic) { string.starts_with(topic, "room:") },
    join: fn(model, topic, payload, ref) {
      let #(joined, effects) = join(ctx, socket_id(model), topic, payload, ref)
      case joined {
        Some(sub) -> #(put(model, dict.insert(get(model), topic, sub)), effects)
        None -> #(model, effects)
      }
    },
    message: fn(model, topic, event_name, payload, ref) {
      case dict.get(get(model), topic) {
        Ok(sub) -> {
          let #(sub, effects) =
            update(ctx, socket_id(model), topic, sub, event_name, payload, ref)
          #(put(model, dict.insert(get(model), topic, sub)), effects)
        }
        Error(Nil) -> #(model, [])
      }
    },
    closed: fn(model, topic) {
      case dict.get(get(model), topic) {
        Ok(sub) -> #(
          put(model, dict.delete(get(model), topic)),
          closed(ctx, socket_id(model), topic, sub),
        )
        Error(Nil) -> #(model, [])
      }
    },
  )
}

/// `update` for the standalone chatrooms `beryl.start` runtime. Topics
/// outside the registered namespaces are rejected (fail closed).
pub fn standalone_update(
  ctx: Ctx,
  model: Standalone,
  ev: socket.Input(Nil),
) -> socket.Next(Standalone, Nil) {
  let rooms =
    namespace(
      ctx,
      socket_id: fn(model: Standalone) { model.socket_id },
      get: fn(model: Standalone) { model.rooms },
      put: fn(model: Standalone, rooms) { Standalone(..model, rooms: rooms) },
    )
  router.route(
    [router.accept_only("lobby"), rooms],
    router.unknown_topic(),
    model,
    ev,
  )
}

// --- Helpers ---

/// Re-tracking the same key through `PresenceTrack` replaces the entry, so
/// a typing toggle is a track with updated meta plus the indicator
/// broadcast to everyone else.
fn typing_effects(
  model: Model,
  socket_id: String,
  topic: String,
  typing typing: Bool,
) -> List(Effect) {
  let typing_payload =
    json.object([
      #("username", json.string(model.username)),
      #("socket_id", json.string(socket_id)),
      #("typing", json.bool(typing)),
    ])
  [
    socket.PresenceTrack(
      topic,
      model.username,
      presence_meta(model.username, model.color, typing: typing),
    ),
    socket.BroadcastFrom(topic, "typing", typing_payload),
  ]
}

fn presence_meta(
  username: String,
  color: String,
  typing typing: Bool,
) -> json.Json {
  json.object([
    #("username", json.string(username)),
    #("color", json.string(color)),
    #("typing", json.bool(typing)),
  ])
}

fn system_message(text: String) -> json.Json {
  json.object([
    #("text", json.string(text)),
    #("type", json.string("system")),
    #("timestamp", json.int(timestamp_ms())),
  ])
}

fn room_changed(room_name: String) -> json.Json {
  json.object([#("room", json.string(room_name))])
}

fn error(message: String) -> json.Json {
  json.object([#("error", json.string(message))])
}

fn error_with_code(code: Int, message: String) -> json.Json {
  json.object([#("code", json.int(code)), #("error", json.string(message))])
}

@external(erlang, "chatrooms_ffi", "timestamp_ms")
fn timestamp_ms() -> Int
