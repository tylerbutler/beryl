//// The benchmark topics as `beryl/channel` handlers: the same events and
//// replies as `load_test/channel`, so a run against either API compares
//// topology alone.

import beryl/channel
import beryl/socket
import example_helpers/session_presence
import gleam/json
import gleam/list
import load_test/bench
import load_test/channel as raw

pub fn handlers(
  presence: session_presence.Tracker,
  cost_us: Int,
) -> List(channel.Handler) {
  [
    channel.handler("guardrail:forbidden", fn(_context) {
      channel.reject(json.object([#("reason", json.string("forbidden"))]))
    }),
    channel.handler("bench:*", fn(context) {
      channel.accept(Nil)
      |> channel.on_message(fn(_state, message) {
        bench.burn(cost_us)
        channel.next(Nil, actions(presence, context.topic, message))
      })
    }),
  ]
}

/// Lower the raw target's effect list onto channel actions. The raw
/// effects are the source of truth for what each event does.
fn actions(
  presence: session_presence.Tracker,
  topic: String,
  message: channel.Message,
) -> List(channel.Action(channel.Active)) {
  raw.message_effects(
    presence,
    topic,
    message.event,
    message.payload,
    message.reply,
  )
  |> list.filter_map(fn(effect) {
    case effect {
      socket.ReplyOk(payload: payload, ..) ->
        Ok(channel.reply_ok(message.reply, payload))
      socket.ReplyError(payload: payload, ..) ->
        Ok(channel.reply_error(message.reply, payload))
      socket.Broadcast(event: event, payload: payload, ..) ->
        Ok(channel.broadcast(event, payload))
      _ -> Error(Nil)
    }
  })
}
