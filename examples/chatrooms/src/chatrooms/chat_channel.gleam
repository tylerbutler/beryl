import beryl
import beryl/channel.{type Channel, type HandleResult, type JoinResult}
import beryl/group
import beryl/presence.{type Presence}
import beryl/socket.{type Socket}
import example_helpers/color
import example_helpers/payload
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/set
import gleam/string

/// State stored in each socket's assigns
pub type ChatAssigns {
  ChatAssigns(
    username: String,
    color: String,
    channels: beryl.Channels,
    presence: Presence,
    groups: group.Groups,
    topic: String,
    room_name: String,
  )
}

/// Maximum users per room — join rejected when full
const max_room_users = 20

/// Create a new chat channel handler
pub fn new_handler(
  channels: beryl.Channels,
  presence: Presence,
  groups: group.Groups,
) -> Channel(ChatAssigns, info) {
  channel.new(fn(topic, payload, socket) {
    join(channels, presence, groups, topic, payload, socket)
  })
  |> channel.with_handle_in(handle_in)
  |> channel.with_terminate(terminate)
}

fn join(
  channels: beryl.Channels,
  presence: Presence,
  groups: group.Groups,
  topic: String,
  payload: Dynamic,
  socket: Socket(ChatAssigns),
) -> JoinResult(ChatAssigns) {
  // Extract room name from topic (e.g., "general" from "room:general")
  let room_name = case string.split(topic, ":") {
    [_, name] -> name
    _ -> "unknown"
  }

  // Validate room exists (must be in "public" group)
  let room_exists = case group.topics(groups, "public") {
    Ok(topics) -> set.contains(topics, topic)
    Error(_) -> False
  }

  case room_exists {
    False ->
      channel.JoinError(reason: channel.error("Room not found: " <> room_name))
    True -> {
      // Check room capacity
      let current_users = presence.list(presence, topic)
      case list.length(current_users) >= max_room_users {
        True ->
          channel.JoinError(reason: channel.error_with_code(
            403,
            "Room is full (max " <> int.to_string(max_room_users) <> ")",
          ))
        False -> {
          let username = payload.string_or(payload, "username", "Anonymous")
          let color = color.pastel_for(socket.id(socket))
          let assigns =
            ChatAssigns(
              username:,
              color:,
              channels:,
              presence:,
              groups:,
              topic:,
              room_name:,
            )
          let socket = socket.set_assigns(socket, assigns)
          let socket_id = socket.id(socket)

          // Track in presence
          let meta =
            json.object([
              #("username", json.string(username)),
              #("color", json.string(color)),
              #("typing", json.bool(False)),
            ])
          presence.track(presence, topic, username, socket_id, meta)

          // Broadcast system message: user joined
          let sys_payload =
            json.object([
              #("text", json.string(username <> " joined the room")),
              #("type", json.string("system")),
              #("timestamp", json.int(timestamp_ms())),
            ])
          beryl.broadcast(channels, topic, "new_msg", sys_payload)

          // Broadcast updated presence list
          let users = presence.list(presence, topic)
          let users_json =
            json.object(
              list.map(users, fn(entry) { #(entry.session_id, entry.meta) }),
            )
          beryl.broadcast(channels, topic, "presence_list", users_json)

          channel.JoinOk(
            reply: Some(
              json.object([
                #("socket_id", json.string(socket_id)),
                #("username", json.string(username)),
                #("color", json.string(color)),
                #("room", json.string(room_name)),
              ]),
            ),
            socket:,
          )
        }
      }
    }
  }
}

fn handle_in(
  event: String,
  payload: Dynamic,
  socket: Socket(ChatAssigns),
) -> HandleResult(ChatAssigns) {
  let assigns = socket.get_assigns(socket)

  case event {
    "new_msg" -> {
      let text = payload.string_or(payload, "text", "")
      case string.trim(text) {
        "" ->
          // Reject empty messages. This must be `ReplyError`: `Reply` always
          // encodes "status": "ok" and discards its event name, so app.js's
          // push.receive("error", ...) hook would never fire and the
          // rejection would look like a successful send.
          channel.ReplyError(
            payload: channel.error_with_code(422, "Message cannot be empty"),
            socket:,
          )
        trimmed -> {
          // Broadcast message to all in the room
          let msg_payload =
            json.object([
              #("text", json.string(trimmed)),
              #("username", json.string(assigns.username)),
              #("color", json.string(assigns.color)),
              #("socket_id", json.string(socket.id(socket))),
              #("type", json.string("user")),
              #("timestamp", json.int(timestamp_ms())),
            ])
          beryl.broadcast(
            assigns.channels,
            assigns.topic,
            "new_msg",
            msg_payload,
          )

          // Acknowledge delivery
          channel.Reply(
            event: "msg_ack",
            payload: json.object([
              #("status", json.string("ok")),
              #("timestamp", json.int(timestamp_ms())),
            ]),
            socket:,
          )
        }
      }
    }

    "typing" -> {
      // Update presence meta with typing=true
      let meta =
        json.object([
          #("username", json.string(assigns.username)),
          #("color", json.string(assigns.color)),
          #("typing", json.bool(True)),
        ])
      presence.track(
        assigns.presence,
        assigns.topic,
        assigns.username,
        socket.id(socket),
        meta,
      )

      // Broadcast typing indicator
      let typing_payload =
        json.object([
          #("username", json.string(assigns.username)),
          #("socket_id", json.string(socket.id(socket))),
          #("typing", json.bool(True)),
        ])
      beryl.broadcast_from(
        assigns.channels,
        socket.id(socket),
        assigns.topic,
        "typing",
        typing_payload,
      )
      channel.NoReply(socket)
    }

    "stop_typing" -> {
      // Update presence meta with typing=false
      let meta =
        json.object([
          #("username", json.string(assigns.username)),
          #("color", json.string(assigns.color)),
          #("typing", json.bool(False)),
        ])
      presence.track(
        assigns.presence,
        assigns.topic,
        assigns.username,
        socket.id(socket),
        meta,
      )

      let typing_payload =
        json.object([
          #("username", json.string(assigns.username)),
          #("socket_id", json.string(socket.id(socket))),
          #("typing", json.bool(False)),
        ])
      beryl.broadcast_from(
        assigns.channels,
        socket.id(socket),
        assigns.topic,
        "typing",
        typing_payload,
      )
      channel.NoReply(socket)
    }

    _ -> channel.NoReply(socket)
  }
}

fn terminate(_reason: channel.StopReason, socket: Socket(ChatAssigns)) -> Nil {
  let assigns = socket.get_assigns(socket)
  let socket_id = socket.id(socket)

  // Untrack all presences for this disconnecting socket
  presence.untrack_all(assigns.presence, socket_id)

  // Broadcast system leave message
  let sys_payload =
    json.object([
      #("text", json.string(assigns.username <> " left the room")),
      #("type", json.string("system")),
      #("timestamp", json.int(timestamp_ms())),
    ])
  beryl.broadcast(assigns.channels, assigns.topic, "new_msg", sys_payload)

  // Broadcast updated presence list
  let users = presence.list(assigns.presence, assigns.topic)
  let users_json =
    json.object(list.map(users, fn(entry) { #(entry.session_id, entry.meta) }))
  beryl.broadcast(assigns.channels, assigns.topic, "presence_list", users_json)
}

// --- Helpers ---

@external(erlang, "chatrooms_ffi", "timestamp_ms")
fn timestamp_ms() -> Int
