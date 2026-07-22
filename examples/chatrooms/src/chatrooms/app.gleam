//// Embeddable chat-room logic for app-side dispatch.
////
//// A topic-scoped `Model`/`join`/`update`/`closed` triple: a composing
//// app (see the showcase example) routes `room:*` events here and stores
//// the returned model per topic. Mirrors the behavior of
//// `chatrooms/chat_channel` on the channel-module API, including its
//// wire-level replies (`msg_ack`, error payloads on an ok-status reply).

import beryl/event.{type Effect, type Ref}
import beryl/group.{type Groups}
import beryl/presence.{type Presence}
import example_helpers/color
import example_helpers/payload
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
      event.RejectJoin(ref, error("Room not found: " <> room_name)),
    ])
    True -> {
      let current_users = presence.list(ctx.presence, topic)
      case list.length(current_users) >= max_room_users {
        True -> #(None, [
          event.RejectJoin(
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
              event.AcceptJoin(ref, Some(reply)),
              event.PresenceTrack(topic, username, meta),
              event.Broadcast(topic, "new_msg", sys_payload),
              event.BroadcastPresence(topic, "presence_list", encode_users),
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
          reply_ok(ref, error_with_code(422, "Message cannot be empty")),
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
              [event.Broadcast(topic, "new_msg", msg_payload)],
              reply_ok(
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
    event.PresenceUntrack(topic, model.username),
    event.Broadcast(topic, "new_msg", sys_payload),
    event.BroadcastPresence(topic, "presence_list", encode_users),
  ]
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
    event.PresenceTrack(
      topic,
      model.username,
      presence_meta(model.username, model.color, typing: typing),
    ),
    event.BroadcastFrom(topic, "typing", typing_payload),
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

/// Reply only when the client sent a ref (matching the channel-module
/// behavior of dropping refless replies). The ok status with an error
/// payload mirrors the previous wire behavior exactly.
fn reply_ok(ref: Option(Ref), reply_payload: json.Json) -> List(Effect) {
  case ref {
    Some(r) -> [event.ReplyOk(r, reply_payload)]
    None -> []
  }
}

/// Encode presence entries as the `presence_list` payload:
/// `{session_id: meta}`.
fn encode_users(entries: List(presence.PresenceEntry)) -> json.Json {
  json.object(list.map(entries, fn(entry) { #(entry.session_id, entry.meta) }))
}

fn error(message: String) -> json.Json {
  json.object([#("error", json.string(message))])
}

fn error_with_code(code: Int, message: String) -> json.Json {
  json.object([#("code", json.int(code)), #("error", json.string(message))])
}

@external(erlang, "chatrooms_ffi", "timestamp_ms")
fn timestamp_ms() -> Int
