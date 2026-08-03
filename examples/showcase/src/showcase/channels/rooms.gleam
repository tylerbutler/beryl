//// The `room:*` channel: one joined chat room per topic.
////
//// The same behavior the standalone chatrooms server implements with raw
//// app-side dispatch (`chatrooms/app`), written as a `beryl_channels`
//// channel. Wire shapes are unchanged, including the ok-status replies
//// that carry an error payload and the refless events that get no reply
//// at all.
////
//// The capacity check and the presence track that satisfies it are both
//// part of accepting the join, so they share one update turn: a second
//// join cannot slip between them and overshoot the cap.

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

/// Maximum users per room — join rejected when full.
const max_room_users = 20

/// Dependencies the chat channel reads: the room group for join
/// validation, presence for the capacity check, and the hub for the one
/// announcement that targets another topic.
pub type Ctx {
  Ctx(presence: Presence, groups: Groups, hub: Hub)
}

/// Private state of one joined room.
type State {
  State(socket_id: String, username: String, color: String, room_name: String)
}

/// This channel schedules no server-side messages for itself, so its
/// `info` type is `Nil`.
type Note =
  Nil

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
                socket_id: info.socket_id,
                username: payload.string_or(
                  join_payload,
                  "username",
                  "Anonymous",
                ),
                color: color.pastel_for(info.socket_id),
                room_name: room_name,
              )

            // The room list lives on another topic, so it is the one
            // thing here that goes through the hub.
            announce_rooms_changed(ctx, state.room_name)

            channel.accept_with(
              channel.joined(state, callbacks(ctx)),
              json.object([
                #("socket_id", json.string(state.socket_id)),
                #("username", json.string(state.username)),
                #("color", json.string(state.color)),
                #("room", json.string(state.room_name)),
              ]),
            )
            // Applied right after the acknowledgment, in the same turn as
            // the capacity check above. `broadcast_presence` encodes when
            // it is applied, after the track before it, so the roster
            // already includes the joining user.
            |> channel.with_actions(
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
          }
        }
    }
  })
}

fn callbacks(ctx: Ctx) -> channel.Callbacks(State, Note) {
  channel.callbacks()
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
    announce_rooms_changed(ctx, state.room_name)

    // Untrack first, then announce, then snapshot: the roster is encoded
    // when the action is applied, so it reflects this leave *and* any
    // join that landed in between.
    channel.actions()
    |> channel.presence_untrack(state.username)
    |> channel.broadcast(
      "new_msg",
      system_message(state.username <> " left the room"),
    )
    |> channel.broadcast_presence(
      "presence_list",
      presence_helpers.encode_users,
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

/// The room list is announced on the application-wide `lobby` topic, which
/// no channel owns — the one thing here a topic-scoped action cannot
/// address, and the only reason the showcase has a hub.
fn announce_rooms_changed(ctx: Ctx, room_name: String) -> Nil {
  hub.publish(ctx.hub, "lobby", "rooms_changed", room_changed(room_name))
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
