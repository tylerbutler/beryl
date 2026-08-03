import beryl
import beryl/channel.{type Channel, type HandleResult, type JoinResult}
import beryl/presence.{type Presence}
import beryl/socket.{type Socket}
import beryl/wire
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/result

pub type Assigns {
  Assigns(
    channels: beryl.Channels,
    presence: Presence,
    topic: String,
    tracking_refs: Dict(String, String),
  )
}

pub fn benchmark(
  channels: beryl.Channels,
  presence: Presence,
) -> Channel(Assigns, info) {
  channel.new(fn(topic, _payload, socket) {
    benchmark_join(channels, presence, topic, socket)
  })
  |> channel.with_handle_in(handle_in)
  |> channel.with_terminate(terminate)
}

pub fn forbidden() -> Channel(Nil, info) {
  channel.new(forbidden_join)
}

pub fn forbidden_join(
  _topic: String,
  _payload: Dynamic,
  _socket: Socket(Nil),
) -> JoinResult(Nil) {
  channel.JoinError(
    reason: json.object([#("reason", json.string("forbidden"))]),
  )
}

pub fn benchmark_join(
  channels: beryl.Channels,
  presence: Presence,
  topic: String,
  socket: Socket(Assigns),
) -> JoinResult(Assigns) {
  let assigns = Assigns(channels:, presence:, topic:, tracking_refs: dict.new())
  channel.JoinOk(reply: None, socket: socket.set_assigns(socket, assigns))
}

pub fn handle_in(
  event: String,
  payload: Dynamic,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  let assigns = socket.get_assigns(socket)
  case event {
    "echo" -> echo_reply(payload, socket)
    "broadcast" -> broadcast_reply("broadcast", payload, socket, assigns)
    "broadcast_ack" ->
      broadcast_reply("broadcast_ack", payload, socket, assigns)
    "presence_track" -> track(payload, socket, assigns)
    "presence_untrack" -> untrack(payload, socket, assigns)
    _ ->
      channel.ReplyError(
        payload: json.object([#("reason", json.string("unknown_event"))]),
        socket:,
      )
  }
}

pub fn echo_reply(
  payload: Dynamic,
  socket: Socket(assigns),
) -> HandleResult(assigns) {
  channel.Reply(event: "echo", payload: wire.dynamic_to_json(payload), socket:)
}

fn broadcast_reply(
  event: String,
  payload: Dynamic,
  socket: Socket(Assigns),
  assigns: Assigns,
) -> HandleResult(Assigns) {
  let outgoing = wire.dynamic_to_json(payload)
  beryl.broadcast(assigns.channels, assigns.topic, event, outgoing)
  channel.Reply(event:, payload: outgoing, socket:)
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
    channel.decode_payload(payload, decoder) |> result.replace_error(Nil),
  )
  Ok(
    #(key, case meta {
      None -> json.object([])
      Some(value) -> wire.dynamic_to_json(value)
    }),
  )
}

fn track(
  payload: Dynamic,
  socket: Socket(Assigns),
  assigns: Assigns,
) -> HandleResult(Assigns) {
  case key_and_meta(payload) {
    Error(_) ->
      channel.ReplyError(
        payload: json.object([#("reason", json.string("invalid_presence"))]),
        socket:,
      )
    Ok(#(key, meta)) -> {
      case dict.get(assigns.tracking_refs, key) {
        Ok(old_ref) -> presence.untrack(assigns.presence, old_ref)
        Error(_) -> Nil
      }
      let tracking_ref =
        presence.track(
          assigns.presence,
          assigns.topic,
          key,
          socket.id(socket),
          meta,
        )
      let updated =
        Assigns(
          ..assigns,
          tracking_refs: dict.insert(assigns.tracking_refs, key, tracking_ref),
        )
      channel.Reply(
        event: "presence_track",
        payload: json.object([#("key", json.string(key))]),
        socket: socket.set_assigns(socket, updated),
      )
    }
  }
}

fn untrack(
  payload: Dynamic,
  socket: Socket(Assigns),
  assigns: Assigns,
) -> HandleResult(Assigns) {
  let decoder = {
    use key <- decode.field("key", decode.string)
    decode.success(key)
  }
  case channel.decode_payload(payload, decoder) {
    Error(_) ->
      channel.ReplyError(
        payload: json.object([#("reason", json.string("invalid_presence"))]),
        socket:,
      )
    Ok(key) -> {
      case dict.get(assigns.tracking_refs, key) {
        Ok(tracking_ref) -> presence.untrack(assigns.presence, tracking_ref)
        Error(_) -> Nil
      }
      let updated =
        Assigns(
          ..assigns,
          tracking_refs: dict.delete(assigns.tracking_refs, key),
        )
      channel.Reply(
        event: "presence_untrack",
        payload: json.object([#("key", json.string(key))]),
        socket: socket.set_assigns(socket, updated),
      )
    }
  }
}

fn terminate(_reason: channel.StopReason, socket: Socket(Assigns)) -> Nil {
  let assigns = socket.get_assigns(socket)
  presence.untrack_all(assigns.presence, socket.id(socket))
}
