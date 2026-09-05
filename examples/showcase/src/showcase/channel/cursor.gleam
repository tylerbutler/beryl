//// The `cursor:*` channel: one live cursor room per joined topic.
////
//// The same behavior the standalone cursor server implements with raw
//// app-side dispatch (`cursor/app`), written as a `beryl/channel`
//// channel: the per-topic state is this channel's own private state
//// instead of an entry in a socket-wide `Dict`, and every effect is an
//// action on this channel's topic. Session presence remains the
//// example-local ETS tracker used by the standalone app.

import beryl/channel
import example_helper/color
import example_helper/payload
import example_helper/session_presence
import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/list
import gleam/result

/// Private state of one joined cursor room.
type State {
  State(socket_id: String, username: String, color: String)
}

/// This channel schedules no server-side messages for itself, so its
/// `info` type is `Nil`: joining, moving, and leaving are each handled in
/// the turn that carries them.
type Note {
  PublishRoster
}

const supported_reactions = ["👍", "❤️", "😂", "🎉", "🔥"]

/// Dependencies shared with the standalone cursor app.
pub type Context {
  Context(presence: session_presence.Tracker)
}

/// The `cursor:*` channel.
pub fn channel(application_context: Context) -> channel.Handler {
  channel.handler("cursor:*", fn(join_context) {
    let username =
      payload.string_or(join_context.payload, "username", "Anonymous")
    let state =
      State(
        socket_id: join_context.socket_id,
        username: username,
        color: color.pastel_for(join_context.socket_id),
      )

    session_presence.track_without_publish(
      application_context.presence,
      join_context.topic,
      join_context.socket_id,
      meta(state),
    )
    channel.notify(join_context.self, PublishRoster)

    channel.accept(state)
    |> channel.on_message(fn(state: State, message: channel.Message) {
      case message.event {
        "cursor_move" ->
          channel.next(state, [
            channel.broadcast_from("cursor_move", move(state, message.payload)),
          ])

        "reaction" ->
          case decode_reaction(message.payload) {
            Ok(reaction) ->
              channel.next(state, [
                channel.broadcast_from("reaction", reaction),
              ])
            Error(Nil) -> channel.stay(state)
          }

        _ -> channel.stay(state)
      }
    })
    |> channel.on_info(fn(state, note) {
      let PublishRoster = note
      session_presence.publish(application_context.presence, join_context.topic)
      channel.stay(state)
    })
    |> channel.on_terminate(fn(state: State, _reason) {
      session_presence.untrack(
        application_context.presence,
        join_context.topic,
        state.socket_id,
      )
      []
    })
    |> channel.with_reply(
      json.object([
        #("socket_id", json.string(state.socket_id)),
        #("username", json.string(state.username)),
        #("color", json.string(state.color)),
      ]),
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

fn decode_reaction(raw: Dynamic) -> Result(Json, Nil) {
  use reaction <- result.try(payload.string_field(raw, "reaction"))
  use x <- result.try(payload.float_field(raw, "x"))
  use y <- result.try(payload.float_field(raw, "y"))
  case
    list.contains(supported_reactions, reaction) && in_range(x) && in_range(y)
  {
    True ->
      Ok(
        json.object([
          #("reaction", json.string(reaction)),
          #("x", json.float(x)),
          #("y", json.float(y)),
        ]),
      )
    False -> Error(Nil)
  }
}

fn in_range(value: Float) -> Bool {
  value >=. 0.0 && value <=. 1.0
}
