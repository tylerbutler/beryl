//// JavaScript host boundary for the portable protocol and Roost.

import beryl_protocol as protocol
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import portable_channels/phoenix
import roost/frame

/// A state change and ordered host work.
pub type Transition {
  Transition(state: protocol.State, actions: List(Action))
}

/// Work that the Durable Object executes in order.
pub type Action {
  Authorize(operation: protocol.Operation, topic: String, payload: Dynamic)
  Deliver(
    operation: Option(protocol.Operation),
    topic: String,
    event: String,
    payload: Dynamic,
  )
  Cleanup(operation: protocol.Operation, topic: String)
  SendText(data: String)
  SendBinary(data: BitArray)
  Disconnect(reason: String)
  Schedule(deadline: Option(Int))
}

/// A failure at the host's protocol or framing boundary.
pub type HostError {
  Protocol(protocol.Error)
  Decode(frame.DecodeError)
  Encode(frame.EncodeError)
  InvalidPayload
}

@external(javascript, "./portable_channels_ffi.mjs", "parse")
fn parse_payload(value: String) -> Result(json.Json, Nil)

/// Create one connection with host-issued identity and bounded protocol work.
pub fn new_connection(
  epoch: String,
  heartbeat_timeout_ms: Int,
  now: Int,
) -> Result(protocol.State, HostError) {
  use config <- result.try(
    protocol.with_limits(
      protocol.config(),
      max_topic_bytes: 255,
      max_event_bytes: 64,
      max_channels: 1,
      max_pending: 64,
      heartbeat_timeout_ms: heartbeat_timeout_ms,
    )
    |> result.map_error(Protocol),
  )
  protocol.new(config, epoch, now)
  |> result.map_error(Protocol)
}

/// Decode and dispatch a Phoenix text frame through Roost.
pub fn receive_text(
  state: protocol.State,
  data: String,
  now: Int,
) -> Result(Transition, HostError) {
  receive(state, frame.TextData(data), now)
}

/// Decode and dispatch a Phoenix binary frame through Roost.
pub fn receive_binary(
  state: protocol.State,
  data: BitArray,
  now: Int,
) -> Result(Transition, HostError) {
  receive(state, frame.BinaryData(data), now)
}

fn receive(
  state: protocol.State,
  data: frame.WireData,
  now: Int,
) -> Result(Transition, HostError) {
  use incoming <- result.try(phoenix.decode(data) |> result.map_error(Decode))
  let decoded = case incoming.event, incoming.topic {
    "phx_join", _ ->
      protocol.Join(
        incoming.topic,
        incoming.payload,
        incoming.join_ref,
        incoming.ref,
      )
    "phx_leave", _ ->
      protocol.Leave(incoming.topic, incoming.join_ref, incoming.ref)
    "heartbeat", "phoenix" -> protocol.Heartbeat(incoming.ref)
    event, topic ->
      protocol.Message(
        topic,
        event,
        incoming.payload,
        incoming.join_ref,
        incoming.ref,
      )
  }
  advance(state, protocol.Receive(decoded), now)
}

/// Accept authorization and admit the topic before sending its join reply.
pub fn join_accepted(
  state: protocol.State,
  operation: protocol.Operation,
  payload: String,
  now: Int,
) -> Result(Transition, HostError) {
  use payload <- result.try(
    parse_payload(payload) |> result.replace_error(InvalidPayload),
  )
  advance(
    state,
    protocol.AcceptJoin(operation, payload, protocol.InvalidateImmediately),
    now,
  )
}

/// Reject authorization without retaining credentials.
pub fn join_rejected(
  state: protocol.State,
  operation: protocol.Operation,
  now: Int,
) -> Result(Transition, HostError) {
  advance(
    state,
    protocol.RejectJoin(
      operation,
      json.object([#("reason", json.string("unauthorized"))]),
    ),
    now,
  )
}

/// Consume an application's reply operation when the client supplied a ref.
pub fn reply(
  state: protocol.State,
  operation: Option(protocol.Operation),
  payload: String,
  succeeded: Bool,
  now: Int,
) -> Result(Transition, HostError) {
  case operation {
    None -> Ok(Transition(state, []))
    Some(operation) -> {
      use payload <- result.try(
        parse_payload(payload) |> result.replace_error(InvalidPayload),
      )
      let status = case succeeded {
        True -> protocol.StatusOk
        False -> protocol.StatusError
      }
      advance(state, protocol.Reply(operation, status, payload), now)
    }
  }
}

/// Push only to an established channel instance.
pub fn push(
  state: protocol.State,
  topic: String,
  event: String,
  payload: String,
  now: Int,
) -> Result(Transition, HostError) {
  case protocol.channel(state, topic) {
    Error(Nil) -> Ok(Transition(state, []))
    Ok(channel) -> {
      use payload <- result.try(
        parse_payload(payload) |> result.replace_error(InvalidPayload),
      )
      advance(state, protocol.Push(channel, event, payload), now)
    }
  }
}

/// Complete host cleanup before terminal frames or replacement authorization.
pub fn cleaned_up(
  state: protocol.State,
  operation: protocol.Operation,
  now: Int,
) -> Result(Transition, HostError) {
  advance(state, protocol.CleanupFinished(operation), now)
}

/// Check the current deadline, including after a delayed alarm.
pub fn expire(
  state: protocol.State,
  now: Int,
) -> Result(Transition, HostError) {
  advance(state, protocol.CheckDeadline, now)
}

/// Run connection cleanup when the transport closes.
pub fn disconnect(
  state: protocol.State,
  now: Int,
) -> Result(Transition, HostError) {
  advance(state, protocol.Disconnect(protocol.Normal), now)
}

/// Export validated protocol state without host objects or credentials.
pub fn snapshot(state: protocol.State, now: Int) -> Result(String, HostError) {
  protocol.export(state, now)
  |> result.map_error(Protocol)
}

/// Restore state and turn unrecoverable work into ordered recovery actions.
pub fn restore(
  snapshot: String,
  now: Int,
  elapsed: Int,
) -> Result(Transition, HostError) {
  use restored <- result.try(
    protocol.restore(snapshot, elapsed, now)
    |> result.map_error(Protocol),
  )
  convert(restored.0, restored.1, [], now)
}

/// Return the wall-clock alarm time, or -1 when no deadline remains.
pub fn next_deadline(state: protocol.State) -> Int {
  protocol.next_deadline(state)
  |> option.unwrap(-1)
}

fn advance(
  state: protocol.State,
  input: protocol.Input,
  now: Int,
) -> Result(Transition, HostError) {
  use next <- result.try(
    protocol.step(state, input, now)
    |> result.map_error(Protocol),
  )
  convert(next.0, next.1, [], now)
}

fn convert(
  state: protocol.State,
  actions: List(protocol.Action),
  reversed: List(Action),
  now: Int,
) -> Result(Transition, HostError) {
  case actions {
    [] -> Ok(Transition(state, list.reverse(reversed)))
    [action, ..rest] ->
      case action {
        protocol.DeliverJoin(_, operation, topic, payload) ->
          convert(
            state,
            rest,
            [Authorize(operation, topic, payload), ..reversed],
            now,
          )
        protocol.AdmitJoin(_, operation, _) -> {
          // This host has no separate subscription index to allocate.
          use admitted <- result.try(
            protocol.step(
              state,
              protocol.AdmissionFinished(operation, True),
              now,
            )
            |> result.map_error(Protocol),
          )
          convert(admitted.0, list.append(admitted.1, rest), reversed, now)
        }
        protocol.Joined(_, _) -> convert(state, rest, reversed, now)
        protocol.DeliverMessage(_, topic, event, payload, operation) ->
          convert(
            state,
            rest,
            [Deliver(operation, topic, event, payload), ..reversed],
            now,
          )
        protocol.CloseChannel(_, operation, topic, _) ->
          convert(state, rest, [Cleanup(operation, topic), ..reversed], now)
        protocol.Send(outbound) -> {
          use encoded <- result.try(encode(outbound))
          let send = case encoded {
            frame.TextData(data) -> SendText(data)
            frame.BinaryData(data) -> SendBinary(data)
          }
          convert(state, rest, [send, ..reversed], now)
        }
        protocol.CloseConnection(reason) ->
          convert(
            state,
            rest,
            [Disconnect(close_reason(reason)), ..reversed],
            now,
          )
        protocol.Deadline(deadline) ->
          convert(state, rest, [Schedule(deadline), ..reversed], now)
      }
  }
}

fn encode(outbound: protocol.Outbound) -> Result(frame.WireData, HostError) {
  case outbound {
    protocol.ReplyMessage(join_ref, ref, topic, status, payload) ->
      phoenix.reply(join_ref, ref, topic, status == protocol.StatusOk, payload)
    protocol.PushMessage(topic, event, payload) ->
      phoenix.encode(None, None, topic, event, payload)
    protocol.TerminalMessage(join_ref, topic, reason) -> {
      let event = case reason {
        protocol.Normal | protocol.Shutdown | protocol.HeartbeatTimeout ->
          frame.close_event
        protocol.Fault(_) -> frame.error_event
      }
      phoenix.encode(join_ref, None, topic, event, json.object([]))
    }
    protocol.HeartbeatReply(ref) ->
      phoenix.reply(None, ref, frame.heartbeat_topic, True, json.object([]))
  }
  |> result.map_error(Encode)
}

fn close_reason(reason: protocol.CloseReason) -> String {
  case reason {
    protocol.Normal -> "normal"
    protocol.Shutdown -> "shutdown"
    protocol.HeartbeatTimeout -> "heartbeat_timeout"
    protocol.Fault(reason) -> reason
  }
}
