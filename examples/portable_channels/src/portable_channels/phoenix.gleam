//// Phoenix framing adapter. Roost owns all text and binary wire encoding.

import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import roost
import roost/frame

/// A client frame after Roost has validated its framing.
pub type Inbound {
  Inbound(
    join_ref: Option(String),
    ref: Option(String),
    topic: String,
    event: String,
    payload: Dynamic,
  )
}

/// Decode text or binary Phoenix pushes from a client.
pub fn decode(data: frame.WireData) -> Result(Inbound, frame.DecodeError) {
  use incoming <- result.try(roost.decode(data, frame.ClientToServer))
  case incoming {
    frame.Push(join_ref, ref, topic, event, payload) -> {
      let payload = case payload {
        frame.JsonPayload(value) -> value
        frame.BinaryPayload(value) -> dynamic.bit_array(value)
      }
      Ok(Inbound(join_ref, ref, topic, event, payload))
    }
    frame.Reply(..) | frame.Broadcast(..) ->
      Error(frame.InvalidFormat("Expected a client push"))
  }
}

/// Encode a logical server event using Roost.
pub fn encode(
  join_ref: Option(String),
  ref: Option(String),
  topic: String,
  event: String,
  payload: json.Json,
) -> Result(frame.WireData, frame.EncodeError) {
  roost.encode(
    frame.Push(join_ref, ref, topic, event, frame.JsonPayload(payload)),
    frame.ServerToClient,
  )
}

/// Encode a reply, retaining the optional wire references.
pub fn reply(
  join_ref: Option(String),
  ref: Option(String),
  topic: String,
  succeeded: Bool,
  payload: json.Json,
) -> Result(frame.WireData, frame.EncodeError) {
  let status = case succeeded {
    True -> frame.StatusOk
    False -> frame.StatusError
  }
  case ref {
    Some(ref) ->
      roost.encode(
        frame.Reply(join_ref, ref, topic, status, frame.JsonPayload(payload)),
        frame.ServerToClient,
      )
    None ->
      encode(
        join_ref,
        None,
        topic,
        frame.reply_event,
        json.object([
          #(
            "status",
            json.string(case succeeded {
              True -> "ok"
              False -> "error"
            }),
          ),
          #("response", payload),
        ]),
      )
  }
}
