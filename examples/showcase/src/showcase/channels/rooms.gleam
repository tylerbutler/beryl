//// The `room:*` channel: one joined chat room per topic.
////
//// The same behavior the standalone chatrooms server implements with raw
//// app-side dispatch (`chatrooms/app`), written as a `beryl_channels`
//// channel. Wire shapes are unchanged, including the ok-status replies
//// that carry an error payload and the refless events that get no reply
//// at all.

import beryl/group.{type Groups}
import beryl/presence.{type Presence}
import beryl/socket.{type Ref}
import beryl_channels/channel
import example_helpers/color
import example_helpers/payload
import example_helpers/presence as presence_helpers
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import gleam/set
import gleam/string
import showcase/hub.{type Hub}
import showcase/reply
import showcase/roster

/// Maximum users per room — join rejected when full.
const max_room_users = 20

/// The application-wide topic the room list is announced on. No channel
/// claims it in the showcase, so it currently has no subscribers; the
/// announcement is kept so the composed app behaves like the standalone
/// one.
const lobby_topic = "lobby"

/// Dependencies the chat channel reads: the room group for join
/// validation, presence for the capacity check and the leave-time roster,
/// and the hub for what a channel cannot address itself.
pub type Ctx {
  Ctx(presence: Presence, groups: Groups, hub: Hub)
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

/// Server-side messages this channel sends itself.
type Note {
  /// Run the post-acknowledgment work: track presence, announce the join.
  Joined
}

/// The `room:*` channel.
pub fn channel(ctx: Ctx) -> channel.Handler {
  channel.handler("room:*", fn(info, topic, join_payload) {
    let room_name = room_name(topic)

    case room_exists(ctx, topic) {
      False -> channel.reject(error("Room not found: " <> room_name))

      True ->
        case room_is_full(ctx, topic) {
          True ->
            channel.reject(error_with_code(
              403,
              "Room is full (max " <> int.to_string(max_room_users) <> ")",
            ))

          False -> {
            let state =
              State(
                topic: topic,
                socket_id: info.socket_id,
                username: payload.string_or(
                  join_payload,
                  "username",
                  "Anonymous",
                ),
                color: color.pastel_for(info.socket_id),
                room_name: room_name,
              )

            // Presence tracking and the join announcements happen after
            // the join acknowledgment, which is what this
            // self-notification schedules.
            channel.notify(info.self, Joined)

            channel.accept_with(
              channel.joined(state, callbacks(ctx)),
              json.object([
                #("socket_id", json.string(state.socket_id)),
                #("username", json.string(state.username)),
                #("color", json.string(state.color)),
                #("room", json.string(state.room_name)),
              ]),
            )
          }
        }
    }
  })
}

fn callbacks(ctx: Ctx) -> channel.Callbacks(State, Note) {
  channel.callbacks()
  |> channel.on_info(fn(state: State, note: Note) {
    let Joined = note
    // The room list lives on another topic, so it goes through the hub;
    // everything else is an action on this channel's own topic.
    hub.publish(
      ctx.hub,
      lobby_topic,
      "rooms_changed",
      room_changed(state.room_name),
    )

    // `broadcast_presence` encodes at apply time, after the
    // `presence_track` before it — so the roster already includes the
    // joining user.
    channel.continue_with(
      state,
      channel.actions()
        |> channel.presence_track(
          state.username,
          presence_meta(state, typing: False),
        )
        |> channel.broadcast(
          "new_msg",
          system_message(state.username <> " joined the room"),
        )
        |> channel.broadcast_presence(
          "presence_list",
          presence_helpers.encode_users,
        ),
    )
  })
  |> channel.on_message(fn(state: State, message: channel.Message) {
    case message.event {
      "new_msg" ->
        channel.continue_with(
          state,
          new_msg(state, message.payload, message.reply),
        )

      "typing" -> channel.continue_with(state, typing(state, typing: True))

      "stop_typing" ->
        channel.continue_with(state, typing(state, typing: False))

      _ -> channel.continue(state)
    }
  })
  |> channel.on_terminate(fn(state: State, _reason) {
    // A channel has no actions left by the time it terminates, so the
    // departure announcements are published through the hub.
    hub.publish(
      ctx.hub,
      lobby_topic,
      "rooms_changed",
      room_changed(state.room_name),
    )
    hub.publish(
      ctx.hub,
      state.topic,
      "new_msg",
      system_message(state.username <> " left the room"),
    )
    hub.publish(
      ctx.hub,
      state.topic,
      "presence_list",
      roster.without(ctx.presence, state.topic, state.socket_id, state.username),
    )
  })
}

/// The message broadcast and its reply, in that order: the sender sees its
/// own message before the acknowledgment, exactly as before.
fn new_msg(state: State, raw: Dynamic, ref: Option(Ref)) -> channel.Actions {
  case string.trim(payload.string_or(raw, "text", "")) {
    "" ->
      channel.actions()
      |> reply.ok(ref, error_with_code(422, "Message cannot be empty"))

    trimmed ->
      channel.actions()
      |> channel.broadcast("new_msg", user_message(state, trimmed))
      |> reply.ok(
        ref,
        json.object([
          #("status", json.string("ok")),
          #("timestamp", json.int(timestamp_ms())),
        ]),
      )
  }
}

/// Re-tracking the same key replaces the entry, so a typing toggle is a
/// track with updated meta plus the indicator broadcast to everyone else.
fn typing(state: State, typing typing: Bool) -> channel.Actions {
  channel.actions()
  |> channel.presence_track(
    state.username,
    presence_meta(state, typing: typing),
  )
  |> channel.broadcast_from(
    "typing",
    json.object([
      #("username", json.string(state.username)),
      #("socket_id", json.string(state.socket_id)),
      #("typing", json.bool(typing)),
    ]),
  )
}

fn room_exists(ctx: Ctx, topic: String) -> Bool {
  case group.topics(ctx.groups, "public") {
    Ok(topics) -> set.contains(topics, topic)
    Error(_) -> False
  }
}

fn room_is_full(ctx: Ctx, topic: String) -> Bool {
  list.length(presence.list(ctx.presence, topic)) >= max_room_users
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
