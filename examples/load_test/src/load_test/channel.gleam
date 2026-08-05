import beryl/socket.{
  type Effect, type Input, type Next, AcceptJoin, Broadcast, Join, Message,
  PresenceTrack, PresenceUntrack, RejectJoin, ReplyError,
}
import beryl/wire
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result

pub fn init(_info) {
  #(Nil, [])
}

pub fn update(model: Nil, input: Input(msg)) -> Next(Nil, msg) {
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
    Message(topic, event, payload, ref) ->
      socket.Next(model, message_effects(topic, event, payload, ref))
    _ -> socket.Next(model, [])
  }
}

pub fn message_effects(
  topic: String,
  event: String,
  payload: Dynamic,
  ref: Option(socket.Ref),
) -> List(Effect) {
  case event {
    "echo" -> socket.reply_ok(ref, wire.dynamic_to_json(payload))
    "broadcast" | "broadcast_ack" -> {
      let outgoing = wire.dynamic_to_json(payload)
      [Broadcast(topic, event, outgoing), ..socket.reply_ok(ref, outgoing)]
    }
    "presence_track" -> track(topic, payload, ref)
    "presence_untrack" -> untrack(topic, payload, ref)
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
      Some(value) -> wire.dynamic_to_json(value)
    }),
  )
}

fn track(
  topic: String,
  payload: Dynamic,
  ref: Option(socket.Ref),
) -> List(Effect) {
  case key_and_meta(payload) {
    Error(_) ->
      reply_error(
        ref,
        json.object([#("reason", json.string("invalid_presence"))]),
      )
    Ok(#(key, meta)) -> [
      PresenceTrack(topic, key, meta),
      ..socket.reply_ok(ref, json.object([#("key", json.string(key))]))
    ]
  }
}

fn untrack(
  topic: String,
  payload: Dynamic,
  ref: Option(socket.Ref),
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
    Ok(key) -> [
      PresenceUntrack(topic, key),
      ..socket.reply_ok(ref, json.object([#("key", json.string(key))]))
    ]
  }
}

fn reply_error(ref: Option(socket.Ref), payload: json.Json) -> List(Effect) {
  case ref {
    Some(value) -> [ReplyError(value, payload)]
    None -> []
  }
}
