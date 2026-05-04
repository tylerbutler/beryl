import beryl
import beryl/channel
import beryl/socket
import beryl/transport/websocket
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit
import gleeunit/should
import wisp
import wisp/simulate

pub fn main() {
  gleeunit.main()
}

type Frame {
  Frame(
    join_ref: Option(String),
    ref: Option(String),
    topic: String,
    event: String,
    payload: dynamic.Dynamic,
  )
}

type Serializer {
  Serializer(
    join: fn(String, String, String, Json) -> String,
    leave: fn(String, String, String, Json) -> String,
    event: fn(String, String, String, String, Json) -> String,
    heartbeat: fn(String) -> String,
    decode: fn(String) -> Result(Frame, Nil),
  )
}

fn json_serializer() -> Serializer {
  Serializer(
    join: fn(join_ref, ref, topic, payload) {
      encode_json_frame(Some(join_ref), Some(ref), topic, "phx_join", payload)
    },
    leave: fn(join_ref, ref, topic, payload) {
      encode_json_frame(Some(join_ref), Some(ref), topic, "phx_leave", payload)
    },
    event: fn(join_ref, ref, topic, event, payload) {
      encode_json_frame(Some(join_ref), Some(ref), topic, event, payload)
    },
    heartbeat: fn(ref) {
      encode_json_frame(
        None,
        Some(ref),
        "phoenix",
        "heartbeat",
        json.object([]),
      )
    },
    decode: decode_json_frame,
  )
}

fn encode_json_frame(
  join_ref: Option(String),
  ref: Option(String),
  topic: String,
  event: String,
  payload: Json,
) -> String {
  json.to_string(
    json.preprocessed_array([
      option_to_json(join_ref),
      option_to_json(ref),
      json.string(topic),
      json.string(event),
      payload,
    ]),
  )
}

fn option_to_json(value: Option(String)) -> Json {
  case value {
    Some(inner) -> json.string(inner)
    None -> json.null()
  }
}

fn decode_json_frame(raw: String) -> Result(Frame, Nil) {
  let decoder = {
    use join_ref <- decode.subfield([0], decode.optional(decode.string))
    use ref <- decode.subfield([1], decode.optional(decode.string))
    use topic <- decode.subfield([2], decode.string)
    use event <- decode.subfield([3], decode.string)
    use payload <- decode.subfield([4], decode.dynamic)
    decode.success(Frame(
      join_ref: join_ref,
      ref: ref,
      topic: topic,
      event: event,
      payload: payload,
    ))
  }

  json.parse(from: raw, using: decoder)
  |> result_nil
}

fn result_nil(result: Result(a, b)) -> Result(a, Nil) {
  case result {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}

fn assert_json_string(
  payload: dynamic.Dynamic,
  field: String,
  expected: String,
) {
  let decoder = {
    use actual <- decode.field(field, decode.string)
    decode.success(actual)
  }
  let assert Ok(actual) = decode.run(payload, decoder)
  actual |> should.equal(expected)
}

fn assert_json_bool(payload: dynamic.Dynamic, field: String, expected: Bool) {
  let decoder = {
    use actual <- decode.field(field, decode.bool)
    decode.success(actual)
  }
  let assert Ok(actual) = decode.run(payload, decoder)
  actual |> should.equal(expected)
}

fn dynamic_field(payload: dynamic.Dynamic, field: String) -> dynamic.Dynamic {
  let decoder = {
    use value <- decode.field(field, decode.dynamic)
    decode.success(value)
  }
  let assert Ok(value) = decode.run(payload, decoder)
  value
}

fn assert_reply(
  serializer: Serializer,
  raw: String,
  join_ref: Option(String),
  ref: String,
  topic: String,
) -> Frame {
  let assert Ok(frame) = serializer.decode(raw)
  frame.join_ref |> should.equal(join_ref)
  frame.ref |> should.equal(Some(ref))
  frame.topic |> should.equal(topic)
  frame.event |> should.equal("phx_reply")
  assert_json_string(frame.payload, "status", "ok")
  frame
}

fn sent_text_messages(ws) -> List(String) {
  process.sleep(25)
  simulate.websocket_sent_text_messages(ws)
}

fn latest_text_message(ws) -> String {
  let messages = sent_text_messages(ws)
  let assert Ok(message) = list.last(messages)
  message
}

fn drain_text_messages(ws) {
  let _ = simulate.reset_websocket(ws)
  Nil
}

fn contract_channel(
  channels: beryl.Channels,
  terminated: process.Subject(channel.StopReason),
) -> channel.Channel(Nil) {
  channel.new(fn(_topic, _payload, client_socket) {
    channel.JoinOk(
      reply: Some(json.object([#("joined", json.bool(True))])),
      socket: client_socket,
    )
  })
  |> channel.with_handle_in(fn(event, payload, client_socket) {
    case event {
      "ping" ->
        channel.Reply(
          "ping",
          json.object([#("pong", json.bool(True))]),
          client_socket,
        )
      "push_me" ->
        channel.Push(
          "pushed",
          json.object([#("from", json.string("server"))]),
          client_socket,
        )
      "broadcast_from_me" -> {
        beryl.broadcast_from(
          channels,
          socket.id(client_socket),
          "room:lobby",
          "broadcasted",
          payload,
        )
        channel.NoReply(client_socket)
      }
      _ -> channel.NoReply(client_socket)
    }
  })
  |> channel.with_terminate(fn(reason, _socket) {
    process.send(terminated, reason)
  })
}

fn connect_client(channels: beryl.Channels) {
  let request = simulate.websocket_request(http.Get, "/socket/websocket")
  let response =
    websocket.upgrade(
      request,
      channels.coordinator,
      websocket.default_config("/socket/websocket"),
      fn() { wisp.not_found() },
    )

  let assert wisp.WebSocket(upgrade) = response.body
  let handler = wisp.recover(upgrade)
  let assert Ok(client) = simulate.create_websocket(handler)
  client
}

fn join_client(serializer: Serializer, client) {
  let assert Ok(client) =
    simulate.send_websocket_text(
      client,
      serializer.join(
        "join-ref",
        "join-1",
        "room:lobby",
        json.object([#("user", json.string("alice"))]),
      ),
    )

  let reply = latest_text_message(client)
  let frame =
    assert_reply(serializer, reply, Some("join-ref"), "join-1", "room:lobby")
  let response = dynamic_field(frame.payload, "response")
  assert_json_bool(response, "joined", True)
  client
}

pub fn json_contract_join_custom_broadcast_heartbeat_leave_test() {
  let serializer = json_serializer()
  let assert Ok(channels) = beryl.start(beryl.default_config())
  let terminated = process.new_subject()
  beryl.register(channels, "room:*", contract_channel(channels, terminated))
  |> should.equal(Ok(Nil))

  let client = connect_client(channels)
  let other_client = connect_client(channels)

  let client = join_client(serializer, client)
  let other_client = join_client(serializer, other_client)
  drain_text_messages(client)
  drain_text_messages(other_client)

  let assert Ok(client) =
    simulate.send_websocket_text(
      client,
      serializer.event(
        "join-ref",
        "event-1",
        "room:lobby",
        "ping",
        json.object([]),
      ),
    )
  let reply = latest_text_message(client)
  let frame = assert_reply(serializer, reply, None, "event-1", "room:lobby")
  let response = dynamic_field(frame.payload, "response")
  assert_json_bool(response, "pong", True)

  let assert Ok(client) =
    simulate.send_websocket_text(
      client,
      serializer.event(
        "join-ref",
        "event-2",
        "room:lobby",
        "push_me",
        json.object([]),
      ),
    )
  let pushed = latest_text_message(client)
  let assert Ok(push_frame) = serializer.decode(pushed)
  push_frame.join_ref |> should.equal(None)
  push_frame.ref |> should.equal(None)
  push_frame.topic |> should.equal("room:lobby")
  push_frame.event |> should.equal("pushed")
  assert_json_string(push_frame.payload, "from", "server")

  drain_text_messages(client)
  drain_text_messages(other_client)
  beryl.broadcast(
    channels,
    "room:lobby",
    "announcement",
    json.object([#("body", json.string("hello"))]),
  )
  let broadcast = latest_text_message(client)
  let assert Ok(broadcast_frame) = serializer.decode(broadcast)
  broadcast_frame.join_ref |> should.equal(None)
  broadcast_frame.ref |> should.equal(None)
  broadcast_frame.topic |> should.equal("room:lobby")
  broadcast_frame.event |> should.equal("announcement")
  assert_json_string(broadcast_frame.payload, "body", "hello")

  drain_text_messages(client)
  let assert Ok(client) =
    simulate.send_websocket_text(client, serializer.heartbeat("heartbeat-1"))
  let heartbeat = latest_text_message(client)
  let _ = assert_reply(serializer, heartbeat, None, "heartbeat-1", "phoenix")

  drain_text_messages(client)
  drain_text_messages(other_client)
  let assert Ok(client) =
    simulate.send_websocket_text(
      client,
      serializer.event(
        "join-ref",
        "event-3",
        "room:lobby",
        "broadcast_from_me",
        json.object([#("body", json.string("from sender"))]),
      ),
    )
  process.sleep(25)
  simulate.websocket_sent_text_messages(client)
  |> should.equal([])
  let from_sender = latest_text_message(other_client)
  let assert Ok(from_sender_frame) = serializer.decode(from_sender)
  from_sender_frame.event |> should.equal("broadcasted")
  assert_json_string(from_sender_frame.payload, "body", "from sender")

  drain_text_messages(client)
  let assert Ok(client) =
    simulate.send_websocket_text(
      client,
      serializer.leave("join-ref", "leave-1", "room:lobby", json.object([])),
    )
  let leave = latest_text_message(client)
  let _ = assert_reply(serializer, leave, None, "leave-1", "room:lobby")
  let assert Ok(reason) = process.receive(terminated, 200)
  reason |> should.equal(channel.Normal)

  drain_text_messages(client)
  beryl.broadcast(
    channels,
    "room:lobby",
    "after_leave",
    json.object([#("body", json.string("ignored"))]),
  )
  process.sleep(25)
  simulate.websocket_sent_text_messages(client)
  |> should.equal([])
}
