import beryl
import beryl/channel.{type Channel, type HandleResult, type JoinResult}
import beryl/presence.{type Presence}
import beryl/socket.{type Socket}
import gleam/dynamic/decode
import gleam/int
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
) -> Channel(CursorAssigns) {
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
  payload: json.Json,
  socket: Socket(CursorAssigns),
) -> JoinResult(CursorAssigns) {
  // Extract username from join payload, default to "Anonymous"
  let username = extract_string(payload, "username", "Anonymous")
  let color = random_pastel_color(socket.id(socket))

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
    json.object(list.map(users, fn(entry) { #(entry.pid, entry.meta) }))

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
  payload: json.Json,
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

fn terminate(_reason: channel.StopReason, socket: Socket(CursorAssigns)) -> Nil {
  let assigns = socket.get_assigns(socket)
  let socket_id = socket.id(socket)

  // Untrack from presence
  presence.untrack(assigns.presence, assigns.topic, assigns.username, socket_id)

  // Broadcast updated presence list
  let users = presence.list(assigns.presence, assigns.topic)
  let users_json =
    json.object(list.map(users, fn(entry) { #(entry.pid, entry.meta) }))
  beryl.broadcast(assigns.channels, assigns.topic, "presence_list", users_json)
}

// --- Helpers ---

/// Generate a deterministic pastel color from a socket ID
fn random_pastel_color(seed: String) -> String {
  let hash =
    seed
    |> to_charcode_sum
  let hue = hash % 360
  "hsl(" <> int.to_string(hue) <> ", 70%, 65%)"
}

fn to_charcode_sum(s: String) -> Int {
  s
  |> string_to_codepoints
  |> list.fold(0, fn(acc, cp) { acc + cp })
}

@external(erlang, "cursors_ffi", "string_to_codepoints")
fn string_to_codepoints(s: String) -> List(Int)

/// Extract a string field from a JSON value, with a default
fn extract_string(
  payload: json.Json,
  field_name: String,
  default: String,
) -> String {
  let json_str = json.to_string(payload)
  let decoder = {
    use value <- decode.field(field_name, decode.string)
    decode.success(value)
  }
  case json.parse(json_str, decoder) {
    Ok(value) -> value
    Error(_) -> default
  }
}

/// Extract a number from JSON payload and return it as Json
fn extract_json_number(payload: json.Json, field_name: String) -> json.Json {
  let json_str = json.to_string(payload)
  let float_decoder = {
    use value <- decode.field(field_name, decode.float)
    decode.success(value)
  }
  case json.parse(json_str, float_decoder) {
    Ok(value) -> json.float(value)
    Error(_) -> {
      let int_decoder = {
        use value <- decode.field(field_name, decode.int)
        decode.success(value)
      }
      case json.parse(json_str, int_decoder) {
        Ok(value) -> json.int(value)
        Error(_) -> json.float(0.0)
      }
    }
  }
}
