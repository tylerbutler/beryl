//// The `cursor:*` channel: one live cursor room per joined topic.
////
//// The same behavior the standalone cursors server implements with raw
//// app-side dispatch (`cursors/app`), written as a `beryl_channels`
//// channel: the per-topic state is this channel's own private state
//// instead of an entry in a socket-wide `Dict`, and every effect is an
//// action on this channel's topic — including the join-time presence
//// track and the leave-time roster.

import beryl_channels/channel
import example_helpers/color
import example_helpers/payload
import example_helpers/presence as presence_helpers
import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}

/// Private state of one joined cursor room.
type State {
  State(socket_id: String, username: String, color: String)
}

/// This channel schedules no server-side messages for itself, so its
/// `info` type is `Nil`: joining, moving, and leaving are each handled in
/// the turn that carries them.
type Note =
  Nil

const supported_reactions = ["👍", "❤️", "😂", "🎉", "🔥"]

/// The `cursor:*` channel.
pub fn channel() -> channel.Handler {
  channel.handler("cursor:*", fn(info, _topic, join_payload) {
    let username = payload.string_or(join_payload, "username", "Anonymous")
    let state =
      State(
        socket_id: info.socket_id,
        username: username,
        color: color.pastel_for(info.socket_id),
      )

    channel.accept_with(
      channel.joined(state, callbacks()),
      json.object([
        #("socket_id", json.string(state.socket_id)),
        #("username", json.string(state.username)),
        #("color", json.string(state.color)),
      ]),
    )
    // Applied right after the acknowledgment, in the same turn.
    // `broadcast_presence` encodes when it is applied, after the track
    // before it, so the roster already includes the joining user.
    |> channel.with_actions(
      channel.actions()
      |> channel.presence_track(state.username, meta(state))
      |> channel.broadcast_presence(
        "presence_list",
        presence_helpers.encode_users,
      ),
    )
  })
}

fn callbacks() -> channel.Callbacks(State, Note) {
  channel.callbacks()
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
    // Untrack first, then snapshot: the roster is encoded when the action
    // is applied, so it reflects this leave *and* any join that landed in
    // between — a snapshot built here in Gleam could go stale.
    channel.actions()
    |> channel.presence_untrack(state.username)
    |> channel.broadcast_presence(
      "presence_list",
      presence_helpers.encode_users,
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
