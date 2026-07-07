import beryl
import beryl/channel.{type Channel, type HandleResult, type JoinResult}
import beryl/presence.{type Presence}
import beryl/socket.{type Socket}
import example_helpers/color
import example_helpers/payload
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some}

/// State stored in each socket's assigns
pub type CursorAssigns {
  CursorAssigns(
    username: String,
    color: String,
    channels: beryl.Channels,
    presence: Presence,
    topic: String,
  )
}

/// Create a new cursor channel handler
pub fn new_handler(
  channels: beryl.Channels,
  presence: Presence,
) -> Channel(CursorAssigns, info) {
  channel.new(fn(topic, payload, socket) {
    join(channels, presence, topic, payload, socket)
  })
  |> channel.with_handle_in(handle_in)
  |> channel.with_terminate(terminate)
}

fn join(
  channels: beryl.Channels,
  presence: Presence,
  topic: String,
  payload: Dynamic,
  socket: Socket(CursorAssigns),
) -> JoinResult(CursorAssigns) {
  // Extract username from join payload, default to "Anonymous"
  let username = payload.string_or(payload, "username", "Anonymous")
  let color = color.pastel_for(socket.id(socket))

  // Set up assigns
  let assigns = CursorAssigns(username:, color:, channels:, presence:, topic:)
  let socket = socket.set_assigns(socket, assigns)
  let socket_id = socket.id(socket)

  // Track this user in presence
  let meta =
    json.object([
      #("username", json.string(username)),
      #("color", json.string(color)),
    ])
  presence.track(presence, topic, username, socket_id, meta)

  // Push the current presence list to the joining client
  let users = presence.list(presence, topic)
  let users_json =
    json.object(list.map(users, fn(entry) { #(entry.session_id, entry.meta) }))

  // Broadcast updated presence to all clients on this topic
  beryl.broadcast(channels, topic, "presence_list", users_json)

  channel.JoinOk(
    reply: Some(
      json.object([
        #("socket_id", json.string(socket_id)),
        #("username", json.string(username)),
        #("color", json.string(color)),
      ]),
    ),
    socket:,
  )
}

fn handle_in(
  event: String,
  payload: Dynamic,
  socket: Socket(CursorAssigns),
) -> HandleResult(CursorAssigns) {
  let assigns = socket.get_assigns(socket)

  case event {
    "cursor_move" -> {
      // Broadcast cursor position to all other clients
      let move_payload =
        json.object([
          #("socket_id", json.string(socket.id(socket))),
          #("x", extract_json_number(payload, "x")),
          #("y", extract_json_number(payload, "y")),
          #("username", json.string(assigns.username)),
          #("color", json.string(assigns.color)),
        ])
      beryl.broadcast_from(
        assigns.channels,
        socket.id(socket),
        assigns.topic,
        "cursor_move",
        move_payload,
      )
      channel.NoReply(socket)
    }
    _ -> channel.NoReply(socket)
  }
}

fn terminate(
  _reason: channel.StopReason,
  socket: Socket(CursorAssigns),
) -> Nil {
  let assigns = socket.get_assigns(socket)
  let socket_id = socket.id(socket)

  // Untrack from presence
  presence.untrack(assigns.presence, assigns.topic, assigns.username, socket_id)

  // Broadcast updated presence list
  let users = presence.list(assigns.presence, assigns.topic)
  let users_json =
    json.object(list.map(users, fn(entry) { #(entry.session_id, entry.meta) }))
  beryl.broadcast(assigns.channels, assigns.topic, "presence_list", users_json)
}

// --- Helpers ---

/// Extract a number from JSON payload and return it as Json
fn extract_json_number(payload: Dynamic, field_name: String) -> json.Json {
  let float_decoder = {
    use value <- decode.field(field_name, decode.float)
    decode.success(value)
  }
  case channel.decode_payload(payload, float_decoder) {
    Ok(value) -> json.float(value)
    Error(_) -> {
      let int_decoder = {
        use value <- decode.field(field_name, decode.int)
        decode.success(value)
      }
      case channel.decode_payload(payload, int_decoder) {
        Ok(value) -> json.int(value)
        Error(_) -> json.float(0.0)
      }
    }
  }
}
