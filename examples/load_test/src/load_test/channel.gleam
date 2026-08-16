import beryl/socket.{
  type Effect, type Input, type Next, AcceptJoin, Broadcast, Join, Message,
  RejectJoin, ReplyError, ReplyOk,
}
import beryl/wire
import example_helpers/session_presence
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result

pub fn init(_info) {
  #(Nil, [])
}

pub fn update(
  presence: session_presence.Tracker,
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
    Message(topic, event_name, payload, ref) ->
      socket.Next(
        model,
        message_effects(presence, topic, event_name, payload, ref),
      )
    _ -> socket.Next(model, [])
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
      reply_ok(ref, result.unwrap(wire.dynamic_to_json(payload), json.null()))
    "broadcast" | "broadcast_ack" -> {
      let outgoing = result.unwrap(wire.dynamic_to_json(payload), json.null())
      [Broadcast(topic, event_name, outgoing), ..reply_ok(ref, outgoing)]
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
      reply_ok(ref, json.object([#("key", json.string(key))]))
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
      reply_ok(ref, json.object([#("key", json.string(key))]))
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

fn reply_ok(ref: Option(socket.ReplyRef), payload: json.Json) -> List(Effect) {
  case ref {
    Some(value) -> [ReplyOk(value, payload)]
    None -> []
  }
}
