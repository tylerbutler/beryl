//// Chat-room channels.
////
//// `lobby` is read-only. Each `room:*` join owns private state and uses a
//// late-bound broadcast hub for the one announcement sent to `lobby`.

import beryl/channel
import beryl/group.{type Groups}
import beryl/socket.{type ReplyRef}
import example_helper/broadcast_hub
import example_helper/color
import example_helper/payload
import example_helper/session_presence
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/json
import gleam/option.{type Option}
import gleam/set
import gleam/string

const max_room_users = 20

/// Dependencies shared by chat-room channels.
pub type Context {
  Context(
    presence: session_presence.Tracker,
    groups: Groups,
    hub: broadcast_hub.Hub,
  )
}

/// Private state for one socket in one room.
type State {
  State(
    topic: String,
    socket_id: String,
    username: String,
    color: String,
    room_name: String,
  )
}

type Note {
  PublishRoster
}

/// Build the standalone chat application's handler table.
pub fn handlers(application_context: Context) -> List(channel.Handler) {
  [lobby(), room(application_context)]
}

fn lobby() -> channel.Handler {
  channel.handler("lobby", fn(_context) { channel.accept(Nil) })
}

fn room(application_context: Context) -> channel.Handler {
  channel.handler("room:*", fn(join_context) {
    let room_name = case join_context.parameters {
      [name] -> name
      _ -> "unknown"
    }

    case room_exists(application_context, join_context.topic) {
      False -> channel.reject(error("Room not found: " <> room_name))
      True -> accept_room(application_context, join_context, room_name)
    }
  })
}

fn accept_room(
  application_context: Context,
  join_context: channel.JoinContext(Note),
  room_name: String,
) -> channel.JoinResult(State, Note) {
  let state =
    State(
      topic: join_context.topic,
      socket_id: join_context.socket_id,
      username: payload.string_or(join_context.payload, "username", "Anonymous"),
      color: color.pastel_for(join_context.socket_id),
      room_name: room_name,
    )

  case
    session_presence.track_if_below(
      application_context.presence,
      state.topic,
      state.socket_id,
      presence_meta(state, typing: False),
      max_room_users,
    )
  {
    Error(Nil) ->
      channel.reject(error_with_code(
        403,
        "Room is full (max " <> int.to_string(max_room_users) <> ")",
      ))
    Ok(Nil) -> {
      announce_rooms_changed(application_context, state.room_name)
      channel.notify(join_context.self, PublishRoster)

      channel.accept(state)
      |> channel.on_message(fn(state, message) {
        case message.event {
          "new_msg" ->
            channel.next(
              state,
              new_message(state, message.payload, message.reply),
            )
          "typing" ->
            channel.next(
              state,
              typing(application_context, state, typing: True),
            )
          "stop_typing" ->
            channel.next(
              state,
              typing(application_context, state, typing: False),
            )
          _ -> channel.stay(state)
        }
      })
      |> channel.on_info(fn(state, note) {
        let PublishRoster = note
        session_presence.publish(application_context.presence, state.topic)
        channel.stay(state)
      })
      |> channel.on_terminate(fn(state, _reason) {
        session_presence.untrack(
          application_context.presence,
          state.topic,
          state.socket_id,
        )
        announce_rooms_changed(application_context, state.room_name)
        [
          channel.broadcast(
            "new_msg",
            system_message(state.username <> " left the room"),
          ),
        ]
      })
      |> channel.with_reply(
        json.object([
          #("socket_id", json.string(state.socket_id)),
          #("username", json.string(state.username)),
          #("color", json.string(state.color)),
          #("room", json.string(state.room_name)),
        ]),
      )
      |> channel.with_actions([
        channel.broadcast(
          "new_msg",
          system_message(state.username <> " joined the room"),
        ),
      ])
    }
  }
}

fn new_message(
  state: State,
  raw: Dynamic,
  ref: Option(ReplyRef),
) -> List(channel.Action(channel.Active)) {
  case string.trim(payload.string_or(raw, "text", "")) {
    "" -> [
      channel.reply_ok(ref, error_with_code(422, "Message cannot be empty")),
    ]
    text -> [
      channel.broadcast("new_msg", user_message(state, text)),
      channel.reply_ok(
        ref,
        json.object([
          #("status", json.string("ok")),
          #("timestamp", json.int(timestamp_ms())),
        ]),
      ),
    ]
  }
}

fn typing(
  context: Context,
  state: State,
  typing typing: Bool,
) -> List(channel.Action(channel.Active)) {
  session_presence.track(
    context.presence,
    state.topic,
    state.socket_id,
    presence_meta(state, typing: typing),
  )
  [
    channel.broadcast_from(
      "typing",
      json.object([
        #("username", json.string(state.username)),
        #("socket_id", json.string(state.socket_id)),
        #("typing", json.bool(typing)),
      ]),
    ),
  ]
}

fn announce_rooms_changed(context: Context, room_name: String) -> Nil {
  broadcast_hub.publish(
    context.hub,
    "lobby",
    "rooms_changed",
    room_changed(room_name),
  )
}

fn room_exists(context: Context, topic: String) -> Bool {
  case group.topics(context.groups, "public") {
    Ok(topics) -> set.contains(topics, topic)
    Error(_) -> False
  }
}

fn presence_meta(state: State, typing typing: Bool) -> json.Json {
  json.object([
    #("username", json.string(state.username)),
    #("color", json.string(state.color)),
    #("typing", json.bool(typing)),
  ])
}

fn user_message(state: State, text: String) -> json.Json {
  json.object([
    #("text", json.string(text)),
    #("username", json.string(state.username)),
    #("color", json.string(state.color)),
    #("socket_id", json.string(state.socket_id)),
    #("type", json.string("user")),
    #("timestamp", json.int(timestamp_ms())),
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
