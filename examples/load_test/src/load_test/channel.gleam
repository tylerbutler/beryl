import beryl/channel
import beryl/socket.{
  type Effect, type Input, type Next, AcceptJoin, Broadcast, Join, Message,
  RejectJoin, ReplyError,
}
import beryl/wire
import example_helpers/session_presence
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import load_test/bench

pub fn init(_info: socket.ConnectInfo(msg)) -> #(Nil, List(Effect)) {
  #(Nil, [])
}

pub fn update(
  presence: session_presence.Tracker,
  cost_us: Int,
  model: Nil,
  input: Input(msg),
) -> Next(Nil) {
  case input {
    Join("guardrail:forbidden", _, ref) ->
      socket.Next(model, [
        RejectJoin(ref, json.object([#("reason", json.string("forbidden"))])),
      ])
    Join("bench:" <> _, _, ref) -> socket.Next(model, [AcceptJoin(ref, None)])
    Join(_, _, ref) ->
      socket.Next(model, [
        RejectJoin(ref, json.object([#("reason", json.string("unmatched"))])),
      ])
    Message(topic, event_name, payload, ref) -> {
      bench.burn(cost_us)
      socket.Next(
        model,
        message_effects(presence, topic, event_name, payload, ref),
      )
    }
    socket.Binary(..) | socket.Closed(..) | socket.Info(_) ->
      socket.Next(model, [])
  }
}

pub fn message_effects(
  presence: session_presence.Tracker,
  topic: String,
  event_name: String,
  payload: Dynamic,
  ref: Option(socket.ReplyRef),
) -> List(Effect) {
  case event_name {
    "echo" ->
      socket.reply_ok(
        ref,
        result.unwrap(wire.dynamic_to_json(payload), json.null()),
      )
    "broadcast" | "broadcast_ack" -> {
      let outgoing = result.unwrap(wire.dynamic_to_json(payload), json.null())
      [Broadcast(topic, event_name, outgoing), ..socket.reply_ok(ref, outgoing)]
    }
    "presence_track" -> track(presence, topic, payload, ref)
    "presence_untrack" -> untrack(presence, topic, payload, ref)
    _ ->
      reply_error(ref, json.object([#("reason", json.string("unknown_event"))]))
  }
}

fn key_and_meta(payload: Dynamic) -> Result(#(String, json.Json), Nil) {
  let decoder = {
    use key <- decode.field("key", decode.string)
    use meta <- decode.optional_field(
      "meta",
      None,
      decode.optional(decode.dynamic),
    )
    decode.success(#(key, meta))
  }
  use #(key, meta) <- result.try(
    decode.run(payload, decoder) |> result.replace_error(Nil),
  )
  Ok(
    #(key, case meta {
      None -> json.object([])
      Some(value) -> result.unwrap(wire.dynamic_to_json(value), json.object([]))
    }),
  )
}

fn track(
  presence: session_presence.Tracker,
  topic: String,
  payload: Dynamic,
  ref: Option(socket.ReplyRef),
) -> List(Effect) {
  case key_and_meta(payload) {
    Error(_) ->
      reply_error(
        ref,
        json.object([#("reason", json.string("invalid_presence"))]),
      )
    Ok(#(key, meta)) -> {
      session_presence.track(presence, topic, key, meta)
      socket.reply_ok(ref, json.object([#("key", json.string(key))]))
    }
  }
}

fn untrack(
  presence: session_presence.Tracker,
  topic: String,
  payload: Dynamic,
  ref: Option(socket.ReplyRef),
) -> List(Effect) {
  let decoder = {
    use key <- decode.field("key", decode.string)
    decode.success(key)
  }
  case decode.run(payload, decoder) {
    Error(_) ->
      reply_error(
        ref,
        json.object([#("reason", json.string("invalid_presence"))]),
      )
    Ok(key) -> {
      session_presence.untrack(presence, topic, key)
      socket.reply_ok(ref, json.object([#("key", json.string(key))]))
    }
  }
}

fn reply_error(
  ref: Option(socket.ReplyRef),
  payload: json.Json,
) -> List(Effect) {
  case ref {
    Some(value) -> [ReplyError(value, payload)]
    None -> []
  }
}

/// The same topics as `beryl/channel` handlers, with the same events and
/// replies as `update`, so a run against either API compares topology
/// alone. `message_effects` stays the source of truth for what each event
/// does.
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

/// Lower the raw target's effect list onto channel actions.
fn actions(
  presence: session_presence.Tracker,
  topic: String,
  message: channel.Message,
) -> List(channel.Action(channel.Active)) {
  message_effects(
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
      // `message_effects` never produces these; listing them keeps the two
      // bench targets from drifting silently if it ever does.
      socket.AcceptJoin(..)
      | socket.RejectJoin(..)
      | socket.Push(..)
      | socket.BroadcastFrom(..)
      | socket.PresenceTrack(..)
      | socket.PresenceUntrack(..)
      | socket.PushPresence(..)
      | socket.BroadcastPresence(..)
      | socket.KickTopic(..) -> Error(Nil)
    }
  })
}
