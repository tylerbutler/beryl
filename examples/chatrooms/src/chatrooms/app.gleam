//// Chat-room logic for app-side dispatch.
////
//// Two layers share one source of truth:
////
//// - A topic-scoped `Model`/`join`/`update`/`closed` surface that a
////   composing app (see the showcase example) routes `room:*` events
////   through, storing the returned model per topic.
//// - A socket-wide `ChatRooms` model plus `chat_rooms_init`/
////   `chat_rooms_update` wrappers that drive the standalone chatrooms
////   server through a `beryl.child_spec` runtime, reusing the same per-topic
////   surface.
////
//// Wire behavior preserves the established room contract, including its
//// replies (an ok-status reply carrying an error payload).

import beryl/group.{type Groups}
import beryl/socket.{type Effect, type JoinRef, type ReplyRef}
import beryl/socket/router
import example_helpers/color
import example_helpers/payload
import example_helpers/session_presence
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string

const max_room_users = 20

/// Per-topic state for one socket in a chat room.
pub type Model {
  Model(username: String, color: String, room_name: String)
}

/// Dependencies shared by chat sockets.
pub type Ctx {
  Ctx(presence: session_presence.Tracker, groups: Groups)
}

/// Handle a join for a `room:*` topic. Returns `None` when rejected.
pub fn join(
  ctx: Ctx,
  socket_id: String,
  match: router.Match,
  payload: Dynamic,
  ref: JoinRef,
) -> #(Option(Model), List(Effect)) {
  let router.Match(topic:, params:) = match
  let room_name = case params {
    [name] -> name
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
      case session_presence.count(ctx.presence, topic) >= max_room_users {
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
          session_presence.track(ctx.presence, topic, socket_id, meta)
          let sys_payload = system_message(username <> " joined the room")
          let reply =
            json.object([
              #("socket_id", json.string(socket_id)),
              #("username", json.string(username)),
              #("color", json.string(color)),
              #("room", json.string(room_name)),
            ])
          #(
            Some(Model(username: username, color: color, room_name: room_name)),
            [
              socket.AcceptJoin(ref, Some(reply)),
              socket.Broadcast(
                "lobby",
                "rooms_changed",
                room_changed(room_name),
              ),
              socket.Broadcast(topic, "new_msg", sys_payload),
            ],
          )
        }
      }
    }
  }
}

/// Handle a client message on a joined `room:*` topic.
pub fn update(
  ctx: Ctx,
  socket_id: String,
  topic: String,
  model: Model,
  event_name: String,
  payload: Dynamic,
  ref: Option(ReplyRef),
) -> #(Model, List(Effect)) {
  case event_name {
    "new_msg" -> {
      let text = payload.string_or(payload, "text", "")
      case string.trim(text) {
        "" -> #(
          model,
          socket.reply_ok(ref, error_with_code(422, "Message cannot be empty")),
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
          #(model, [
            socket.Broadcast(topic, "new_msg", msg_payload),
            ..socket.reply_ok(
              ref,
              json.object([
                #("status", json.string("ok")),
                #("timestamp", json.int(timestamp_ms())),
              ]),
            )
          ])
        }
      }
    }

    "typing" -> #(
      model,
      typing_effects(ctx, model, socket_id, topic, typing: True),
    )
    "stop_typing" -> #(
      model,
      typing_effects(ctx, model, socket_id, topic, typing: False),
    )

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
  session_presence.untrack(ctx.presence, topic, socket_id)
  let sys_payload = system_message(model.username <> " left the room")
  [
    socket.Broadcast("lobby", "rooms_changed", room_changed(model.room_name)),
    socket.Broadcast(topic, "new_msg", sys_payload),
  ]
}

// --- Socket-wide model and dispatch ---

/// Socket-wide model for the standalone chatrooms server: the socket id
/// plus one per-topic `Model` per joined `room:*` topic. The app owns this
/// type; `beryl/socket/router` only decides which namespace an input
/// belongs to.
pub type ChatRooms {
  ChatRooms(socket_id: String, topics: Dict(String, Model))
}

/// `init` for the `beryl.child_spec` runtime.
pub fn chat_rooms_init(
  info: socket.ConnectInfo(Nil),
) -> #(ChatRooms, List(Effect)) {
  #(ChatRooms(socket_id: info.socket_id, topics: dict.new()), [])
}

/// Adapt the `room:*` handlers to the socket-wide model. A
/// join's model is committed only when the join is accepted.
fn namespace(ctx: Ctx) -> router.Namespace(ChatRooms) {
  router.namespace(
    pattern: "room:*",
    join: fn(state: ChatRooms, match: router.Match, payload, ref) {
      case join(ctx, state.socket_id, match, payload, ref) {
        #(Some(model), effects) -> #(
          ChatRooms(
            ..state,
            topics: dict.insert(state.topics, match.topic, model),
          ),
          effects,
        )
        #(None, effects) -> #(state, effects)
      }
    },
    message: fn(state: ChatRooms, match: router.Match, event_name, payload, ref) {
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
              ref,
            )
          #(
            ChatRooms(
              ..state,
              topics: dict.insert(state.topics, match.topic, model),
            ),
            effects,
          )
        }
        Error(Nil) -> #(state, [])
      }
    },
    closed: fn(state: ChatRooms, match: router.Match, _reason) {
      case dict.get(state.topics, match.topic) {
        Ok(model) -> #(
          ChatRooms(..state, topics: dict.delete(state.topics, match.topic)),
          closed(ctx, state.socket_id, match.topic, model),
        )
        Error(Nil) -> #(state, [])
      }
    },
  )
}

/// Build the socket-wide update once, sharing the app-owned model.
pub fn chat_rooms_update(
  ctx: Ctx,
) -> fn(ChatRooms, socket.Input(Nil)) -> socket.Next(ChatRooms) {
  let namespaces = [router.accept_only("lobby"), namespace(ctx)]
  fn(model, input) {
    router.route(namespaces, router.unknown_topic(), model, input)
  }
}

// --- Helpers ---

fn typing_effects(
  ctx: Ctx,
  model: Model,
  socket_id: String,
  topic: String,
  typing typing: Bool,
) -> List(Effect) {
  session_presence.track(
    ctx.presence,
    topic,
    socket_id,
    presence_meta(model.username, model.color, typing: typing),
  )
  let typing_payload =
    json.object([
      #("username", json.string(model.username)),
      #("socket_id", json.string(socket_id)),
      #("typing", json.bool(typing)),
    ])
  [socket.BroadcastFrom(topic, "typing", typing_payload)]
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
