//// The `room:*` channel: one joined chat room per topic.
////
//// The same behavior the standalone chatroom server implements with raw
//// app-side dispatch (`chatroom/app`), written as a `beryl/channel`
//// channel. Wire shapes are unchanged, including the ok-status replies
//// that carry an error payload and the refless events that get no reply
//// at all.
////
//// The capacity check and presence track are one serialized tracker
//// operation, so concurrent socket actors cannot overshoot the cap.

import beryl/channel
import beryl/group.{type Groups}
import beryl/socket.{type ReplyRef}
import example_helper/broadcast_hub as hub
import example_helper/color
import example_helper/payload
import example_helper/session_presence
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/set
import gleam/string

/// Maximum users per room — join rejected when full.
const max_room_users = 20

/// Dependencies the chat channel reads: the room group for join
/// validation, presence for the capacity check, and the hub for the one
/// announcement that targets another topic.
pub type Context {
  Context(presence: session_presence.Tracker, groups: Groups, hub: hub.Hub)
}

/// Private state of one joined room.
type State {
  State(
    topic: String,
    socket_id: String,
    username: String,
    color: String,
    room_name: String,
  )
}

/// This channel schedules no server-side messages for itself, so its
/// `info` type is `Nil`.
type Note {
  PublishRoster
}

/// The `room:*` channel.
pub fn channel(application_context: Context) -> channel.Handler {
  channel.handler("room:*", fn(join_context) {
    let room_name = room_name(join_context.topic)

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
      join_context.topic,
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
      // The room list lives on another topic, so it is the one thing here
      // that goes through the hub.
      announce_rooms_changed(application_context, state.room_name)
      channel.notify(join_context.self, PublishRoster)

      channel.accept(state)
      |> channel.on_message(fn(state: State, message: channel.Message) {
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
      |> channel.on_terminate(fn(state: State, _reason) {
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

/// The message broadcast and its reply, in that order: the sender sees its
/// own message before the acknowledgment, exactly as before.
fn new_message(
  state: State,
  raw: Dynamic,
  ref: Option(ReplyRef),
) -> List(channel.Action(channel.Active)) {
  case string.trim(payload.string_or(raw, "text", "")) {
    "" -> [
      channel.reply_ok(ref, error_with_code(422, "Message cannot be empty")),
    ]

    trimmed -> [
      channel.broadcast("new_msg", user_message(state, trimmed)),
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

/// Re-tracking the same key replaces the entry, so a typing toggle is a
/// track with updated meta plus the indicator broadcast to everyone else.
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

/// The room list is announced on the application-wide read-only `lobby`
/// channel — the one thing here a room-scoped action cannot address, and
/// the only reason the showcase has a hub.
fn announce_rooms_changed(context: Context, room_name: String) -> Nil {
  hub.publish(context.hub, "lobby", "rooms_changed", room_changed(room_name))
}

fn room_exists(context: Context, topic: String) -> Bool {
  case group.topics(context.groups, "public") {
    Ok(topics) -> set.contains(topics, topic)
    Error(_) -> False
  }
}

fn room_name(topic: String) -> String {
  case string.split(topic, ":") {
    [_, name] -> name
    _ -> "unknown"
  }
}

fn presence_meta(state: State, typing typing: Bool) -> Json {
  json.object([
    #("username", json.string(state.username)),
    #("color", json.string(state.color)),
    #("typing", json.bool(typing)),
  ])
}

fn user_message(state: State, text: String) -> Json {
  json.object([
    #("text", json.string(text)),
    #("username", json.string(state.username)),
    #("color", json.string(state.color)),
    #("socket_id", json.string(state.socket_id)),
    #("type", json.string("user")),
    #("timestamp", json.int(timestamp_ms())),
  ])
}

fn system_message(text: String) -> Json {
  json.object([
    #("text", json.string(text)),
    #("type", json.string("system")),
    #("timestamp", json.int(timestamp_ms())),
  ])
}

fn room_changed(room_name: String) -> Json {
  json.object([#("room", json.string(room_name))])
}

fn error(message: String) -> Json {
  json.object([#("error", json.string(message))])
}

fn error_with_code(code: Int, message: String) -> Json {
  json.object([#("code", json.int(code)), #("error", json.string(message))])
}

@external(erlang, "showcase_ffi", "timestamp_ms")
fn timestamp_ms() -> Int
