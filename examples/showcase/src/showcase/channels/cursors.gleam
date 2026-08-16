//// The `cursor:*` channel: one live cursor room per joined topic.
////
//// The same behavior the standalone cursors server implements with raw
//// app-side dispatch (`cursors/app`), written as a `beryl/channel`
//// channel: the per-topic state is this channel's own private state
//// instead of an entry in a socket-wide `Dict`, and every effect is an
//// action on this channel's topic. Session presence remains the
//// example-local ETS tracker used by the standalone app.

import beryl/channel
import example_helpers/color
import example_helpers/payload
import example_helpers/session_presence
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

/// Dependencies shared with the standalone cursor app.
pub type Ctx {
  Ctx(presence: session_presence.Tracker)
}

/// The `cursor:*` channel.
pub fn channel(ctx: Ctx) -> channel.Handler {
  channel.handler("cursor:*", fn(context) {
    let username = payload.string_or(context.payload, "username", "Anonymous")
    let state =
      State(
        socket_id: context.socket_id,
        username: username,
        color: color.pastel_for(context.socket_id),
      )

    session_presence.track(
      ctx.presence,
      context.topic,
      context.socket_id,
      meta(state),
    )

    channel.accept(state, callbacks(ctx, context.topic))
    |> channel.with_reply(
      json.object([
        #("socket_id", json.string(state.socket_id)),
        #("username", json.string(state.username)),
        #("color", json.string(state.color)),
      ]),
    )
  })
}

fn callbacks(ctx: Ctx, topic: String) -> channel.Callbacks(State, Note) {
  channel.callbacks()
  |> channel.on_message(fn(state: State, message: channel.Message) {
    case message.event {
      "cursor_move" ->
        channel.next(state, [
          channel.broadcast_from("cursor_move", move(state, message.payload)),
        ])

      "reaction" ->
        case decode_reaction(message.payload) {
          Some(reaction) ->
            channel.next(state, [
              channel.broadcast_from("reaction", reaction),
            ])
          None -> channel.next(state, [])
        }

      _ -> channel.next(state, [])
    }
  })
  |> channel.on_terminate(fn(state: State, _reason) {
    session_presence.untrack(ctx.presence, topic, state.socket_id)
    []
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
