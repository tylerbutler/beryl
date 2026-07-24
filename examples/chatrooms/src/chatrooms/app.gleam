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

/// Per-socket state for the application-wide lobby topic.
pub type Lobby {
  Lobby
}

/// Dependencies the chat logic reads: the room group for join validation
/// and the presence handle for reads (writes go through effects).
pub type Context {
  Context(presence: Presence, groups: Groups)
}

/// Handle a join for a `room:*` topic. Returns `None` when rejected.
pub fn join(
  context: Context,
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
  let room_exists = case group.topics(context.groups, "public") {
    Ok(topics) -> set.contains(topics, topic)
    Error(_) -> False
  }

  case room_exists {
    False -> #(None, [
      socket.RejectJoin(ref, error("Room not found: " <> room_name)),
    ])
    True -> {
      let current_users = presence.list(context.presence, topic)
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

          let system_payload = system_message(username <> " joined the room")

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
              socket.Broadcast(topic, "new_msg", system_payload),
              socket.BroadcastPresence(topic, "presence_list", encode_users),
            ],
          )
        }
      }
    }
  }
}

/// Handle a client message on a joined `room:*` topic.
pub fn update(
  _context: Context,
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
          let message_payload =
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
              [socket.Broadcast(topic, "new_msg", message_payload)],
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
  _context: Context,
  _socket_id: String,
  topic: String,
  model: Model,
) -> List(Effect) {
  let system_payload = system_message(model.username <> " left the room")
  // The snapshot encodes after the untrack before it, so the broadcast
  // list already excludes the leaving user.
  [
    socket.PresenceUntrack(topic, model.username),
    socket.Broadcast("lobby", "rooms_changed", room_changed(model.room_name)),
    socket.Broadcast(topic, "new_msg", system_payload),
    socket.BroadcastPresence(topic, "presence_list", encode_users),
  ]
}

// --- Standalone app-side dispatch wrapper ---

/// Accept the application-wide `lobby` topic.
pub fn lobby_join(ref: Ref) -> #(Lobby, List(Effect)) {
  #(Lobby, [socket.AcceptJoin(ref, None)])
}

/// The lobby is read-only; client events produce no effects.
pub fn lobby_update(
  model: Lobby,
  _event_name: String,
  _payload: Dynamic,
  _ref: Option(Ref),
) -> #(Lobby, List(Effect)) {
  #(model, [])
}

/// Closing the lobby requires no external cleanup.
pub fn lobby_closed(_model: Lobby) -> List(Effect) {
  []
}

/// Socket-wide state for the standalone chatrooms server: one per-topic
/// `Model` per joined `room:*` topic, keyed by topic.
pub type Standalone {
  Standalone(
    socket_id: String,
    rooms: Dict(String, Model),
    lobby: Option(Lobby),
  )
}

/// `init` for the standalone chatrooms `beryl.start` runtime.
pub fn standalone_init(
  info: socket.ConnectInfo(Nil),
) -> #(Standalone, List(Effect)) {
  #(Standalone(socket_id: info.socket_id, rooms: dict.new(), lobby: None), [])
}

/// `update` for the standalone chatrooms `beryl.start` runtime: route
/// each event to the embeddable `join`/`update`/`closed` surface, keyed by
/// topic. Non-`room:*` joins are rejected (fail closed), mirroring the old
/// `room:*` handler registration.
pub fn standalone_update(
  context: Context,
  model: Standalone,
  ev: socket.Input(Nil),
) -> socket.Next(Standalone, Nil) {
  case ev {
    socket.Join(topic, payload, ref) ->
      case topic {
        "lobby" -> {
          let #(lobby, effects) = lobby_join(ref)
          socket.Next(Standalone(..model, lobby: Some(lobby)), effects)
        }
        "room:" <> _ -> {
          let #(joined, effects) =
            join(context, model.socket_id, topic, payload, ref)
          case joined {
            Some(sub) ->
              socket.Next(
                Standalone(..model, rooms: dict.insert(model.rooms, topic, sub)),
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

    socket.Message(topic, event_name, payload, ref) ->
      case topic {
        "lobby" ->
          case model.lobby {
            Some(lobby) -> {
              let #(lobby, effects) =
                lobby_update(lobby, event_name, payload, ref)
              socket.Next(Standalone(..model, lobby: Some(lobby)), effects)
            }
            None -> socket.Next(model, [])
          }
        _ ->
          case dict.get(model.rooms, topic) {
            Ok(sub) -> {
              let #(sub, effects) =
                update(
                  context,
                  model.socket_id,
                  topic,
                  sub,
                  event_name,
                  payload,
                  ref,
                )
              socket.Next(
                Standalone(..model, rooms: dict.insert(model.rooms, topic, sub)),
                effects,
              )
            }
            Error(Nil) -> socket.Next(model, [])
          }
      }

    socket.Closed(topic, _reason) ->
      case topic {
        "lobby" ->
          case model.lobby {
            Some(lobby) ->
              socket.Next(Standalone(..model, lobby: None), lobby_closed(lobby))
            None -> socket.Next(model, [])
          }
        _ ->
          case dict.get(model.rooms, topic) {
            Ok(sub) ->
              socket.Next(
                Standalone(..model, rooms: dict.delete(model.rooms, topic)),
                closed(context, model.socket_id, topic, sub),
              )
            Error(Nil) -> socket.Next(model, [])
          }
      }

    socket.Binary(_, _) | socket.Info(_) -> socket.Next(model, [])
  }
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

/// Reply only when the client sent a ref (matching the channel-module
/// behavior of dropping refless replies). The ok status with an error
/// payload mirrors the previous wire behavior exactly.
fn reply_ok(ref: Option(Ref), reply_payload: json.Json) -> List(Effect) {
  case ref {
    Some(r) -> [socket.ReplyOk(r, reply_payload)]
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
