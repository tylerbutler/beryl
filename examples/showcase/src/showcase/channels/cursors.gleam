//// The `cursor:*` channel: one live cursor room per joined topic.
////
//// The same behavior the standalone cursors server implements with raw
//// app-side dispatch (`cursors/app`), written as a `beryl_channels`
//// channel: the per-topic state is this channel's own private state
//// instead of an entry in a socket-wide `Dict`, and every effect is an
//// action on this channel's topic.

import beryl/presence.{type Presence}
import beryl_channels/channel
import example_helpers/color
import example_helpers/payload
import example_helpers/presence as presence_helpers
import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import showcase/hub.{type Hub}
import showcase/roster

/// Dependencies the cursor channel reads. Presence writes go through
/// actions; the handle is only needed for the leave-time snapshot.
pub type Ctx {
  Ctx(presence: Presence, hub: Hub)
}

/// Private state of one joined cursor room.
type State {
  State(topic: String, socket_id: String, username: String, color: String)
}

/// Server-side messages this channel sends itself.
type Note {
  /// Run the post-acknowledgment work: track presence, publish the roster.
  Joined
}

const supported_reactions = ["👍", "❤️", "😂", "🎉", "🔥"]

/// The `cursor:*` channel.
pub fn channel(ctx: Ctx) -> channel.Handler {
  channel.handler("cursor:*", fn(info, topic, join_payload) {
    let username = payload.string_or(join_payload, "username", "Anonymous")
    let state =
      State(
        topic: topic,
        socket_id: info.socket_id,
        username: username,
        color: color.pastel_for(info.socket_id),
      )

    // Presence tracking and the roster broadcast happen after the join
    // acknowledgment, which is what this self-notification schedules.
    channel.notify(info.self, Joined)

    channel.accept_with(
      channel.joined(state, callbacks(ctx)),
      json.object([
        #("socket_id", json.string(state.socket_id)),
        #("username", json.string(state.username)),
        #("color", json.string(state.color)),
      ]),
    )
  })
}

fn callbacks(ctx: Ctx) -> channel.Callbacks(State, Note) {
  channel.callbacks()
  |> channel.on_info(fn(state: State, note: Note) {
    let Joined = note
    // `broadcast_presence` encodes at apply time, after the
    // `presence_track` before it — so the roster already includes the
    // joining user.
    channel.continue_with(
      state,
      channel.actions()
        |> channel.presence_track(state.username, meta(state))
        |> channel.broadcast_presence(
          "presence_list",
          presence_helpers.encode_users,
        ),
    )
  })
  |> channel.on_message(fn(state: State, message: channel.Message) {
    case message.event {
      "cursor_move" ->
        channel.continue_with(
          state,
          channel.actions()
            |> channel.broadcast_from(
              "cursor_move",
              move(state, message.payload),
            ),
        )

      "reaction" ->
        case decode_reaction(message.payload) {
          Some(reaction) ->
            channel.continue_with(
              state,
              channel.actions() |> channel.broadcast_from("reaction", reaction),
            )
          None -> channel.continue(state)
        }

      _ -> channel.continue(state)
    }
  })
  |> channel.on_terminate(fn(state: State, _reason) {
    // A channel has no actions left by the time it terminates, so the
    // roster the leaver is no longer part of is published through the hub.
    hub.publish(
      ctx.hub,
      state.topic,
      "presence_list",
      roster.without(ctx.presence, state.topic, state.socket_id, state.username),
    )
  })
}

fn meta(state: State) -> Json {
  json.object([
    #("username", json.string(state.username)),
    #("color", json.string(state.color)),
  ])
}

fn move(state: State, raw: Dynamic) -> Json {
  json.object([
    #("socket_id", json.string(state.socket_id)),
    #("x", payload.json_number_or_zero(raw, "x")),
    #("y", payload.json_number_or_zero(raw, "y")),
    #("username", json.string(state.username)),
    #("color", json.string(state.color)),
  ])
}

fn decode_reaction(raw: Dynamic) -> Option(Json) {
  case
    payload.string_field(raw, "reaction"),
    payload.float_field(raw, "x"),
    payload.float_field(raw, "y")
  {
    Ok(reaction), Ok(x), Ok(y) ->
      case
        list.contains(supported_reactions, reaction)
        && in_range(x)
        && in_range(y)
      {
        True ->
          Some(
            json.object([
              #("reaction", json.string(reaction)),
              #("x", json.float(x)),
              #("y", json.float(y)),
            ]),
          )
        False -> None
      }
    _, _, _ -> None
  }
}

fn in_range(value: Float) -> Bool {
  value >=. 0.0 && value <=. 1.0
}
