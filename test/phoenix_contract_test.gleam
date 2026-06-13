import beryl
import beryl/channel
import beryl/socket
import beryl/transport/mist as mist_transport
import beryl/wire
import gleam/bytes_tree
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleeunit
import gleeunit/should
import mist

pub fn main() {
  gleeunit.main()
}

type WebsocketClient

@external(erlang, "beryl_mist_transport_test_ffi", "connect_websocket")
fn connect_websocket(port: Int, path: String) -> Result(WebsocketClient, Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "send_text")
fn send_text(
  client: WebsocketClient,
  text: String,
) -> Result(WebsocketClient, Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "receive_text")
fn receive_text(client: WebsocketClient, timeout: Int) -> Result(String, Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "close")
fn close(client: WebsocketClient) -> Nil

@external(erlang, "beryl_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil

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

fn latest_text_message(client: WebsocketClient) -> String {
  let assert Ok(message) = receive_text(client, 500)
  message
}

fn drain_text_messages(client: WebsocketClient) {
  case receive_text(client, 10) {
    Ok(_) -> drain_text_messages(client)
    Error(_) -> Nil
  }
}

fn assert_no_text_message(client: WebsocketClient) {
  receive_text(client, 50)
  |> should.equal(Error(Nil))
}

fn contract_channel(
  channels: beryl.Channels,
  terminated: process.Subject(channel.StopReason),
) -> channel.Channel(Nil, info) {
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
          wire.dynamic_to_json(payload),
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

fn start_mist_server(channels: beryl.Channels) -> #(Int, process.Pid) {
  let port_subject = process.new_subject()
  let handler = fn(request) {
    mist_transport.upgrade(
      request,
      channels,
      mist_transport.default_config("/socket/websocket"),
      fn() {
        response.new(404)
        |> response.set_body(mist.Bytes(bytes_tree.new()))
      },
    )
  }
  let assert Ok(server) =
    handler
    |> mist.new
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _scheme, _ip_address) {
      process.send(port_subject, port)
    })
    |> mist.start
  let assert Ok(port) = process.receive(port_subject, 1000)
  #(port, server.pid)
}

fn connect_client(port: Int) {
  let assert Ok(client) = connect_websocket(port, "/socket/websocket")
  client
}

fn join_client(serializer: Serializer, client: WebsocketClient) {
  let assert Ok(client) =
    send_text(
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
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let terminated = process.new_subject()
  beryl.register(channels, "room:*", contract_channel(channels, terminated))
  |> should.equal(Ok(Nil))
  let #(port, server_pid) = start_mist_server(channels)

  let client = connect_client(port)
  let other_client = connect_client(port)

  let client = join_client(serializer, client)
  let other_client = join_client(serializer, other_client)
  drain_text_messages(client)
  drain_text_messages(other_client)

  let assert Ok(client) =
    send_text(
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
    send_text(
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
  let assert Ok(client) = send_text(client, serializer.heartbeat("heartbeat-1"))
  let heartbeat = latest_text_message(client)
  let _ = assert_reply(serializer, heartbeat, None, "heartbeat-1", "phoenix")

  drain_text_messages(client)
  drain_text_messages(other_client)
  let assert Ok(client) =
    send_text(
      client,
      serializer.event(
        "join-ref",
        "event-3",
        "room:lobby",
        "broadcast_from_me",
        json.object([#("body", json.string("from sender"))]),
      ),
    )
  assert_no_text_message(client)
  let from_sender = latest_text_message(other_client)
  let assert Ok(from_sender_frame) = serializer.decode(from_sender)
  from_sender_frame.event |> should.equal("broadcasted")
  assert_json_string(from_sender_frame.payload, "body", "from sender")

  drain_text_messages(client)
  let assert Ok(client) =
    send_text(
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
  assert_no_text_message(client)
  close(client)
  close(other_client)
  stop_supervisor(server_pid)
}

// Socket-level connect/auth hook (on_connect) — issue #93

fn auth_query(req, name: String) -> Result(String, Nil) {
  case request.get_query(req) {
    Ok(params) ->
      list.find(params, fn(pair) { pair.0 == name })
      |> result.map(fn(pair) { pair.1 })
    Error(_) -> Error(Nil)
  }
}

fn start_auth_server(
  channels: beryl.Channels,
  config: mist_transport.TransportConfig(a),
) -> #(Int, process.Pid) {
  let port_subject = process.new_subject()
  let handler = fn(request) {
    mist_transport.upgrade(request, channels, config, fn() {
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    })
  }
  let assert Ok(server) =
    handler
    |> mist.new
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _scheme, _ip_address) {
      process.send(port_subject, port)
    })
    |> mist.start
  let assert Ok(port) = process.receive(port_subject, 1000)
  #(port, server.pid)
}

pub fn on_connect_rejects_connection_without_token_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let config =
    mist_transport.default_config("/socket/websocket")
    |> mist_transport.with_on_connect(fn(req) {
      case auth_query(req, "token") {
        Ok("secret") -> Ok(Nil)
        _ -> Error(Nil)
      }
    })
  let #(port, server_pid) = start_auth_server(channels, config)

  // Missing/invalid token -> upgrade rejected (HTTP 403, no 101 switch).
  connect_websocket(port, "/socket/websocket")
  |> should.equal(Error(Nil))

  // Valid token -> upgrade succeeds.
  let assert Ok(client) =
    connect_websocket(port, "/socket/websocket?token=secret")
  close(client)
  stop_supervisor(server_pid)
}

pub fn on_connect_seeds_assigns_visible_at_join_test() {
  let serializer = json_serializer()
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))

  // The channel's assigns is the connect-seeded user id; join echoes it back
  // without re-authenticating.
  let handler =
    channel.new(fn(_topic, _payload, client_socket) {
      let user_id = socket.get_assigns(client_socket)
      channel.JoinOk(
        reply: Some(json.object([#("user", json.string(user_id))])),
        socket: client_socket,
      )
    })
  beryl.register(channels, "room:*", handler)
  |> should.equal(Ok(Nil))

  let config =
    mist_transport.default_config("/socket/websocket")
    |> mist_transport.with_on_connect(fn(req) { auth_query(req, "token") })
  let #(port, server_pid) = start_auth_server(channels, config)

  let assert Ok(client) =
    connect_websocket(port, "/socket/websocket?token=alice")
  let assert Ok(client) =
    send_text(
      client,
      serializer.join("join-ref", "join-1", "room:lobby", json.object([])),
    )
  let reply = latest_text_message(client)
  let frame =
    assert_reply(serializer, reply, Some("join-ref"), "join-1", "room:lobby")
  let response = dynamic_field(frame.payload, "response")
  assert_json_string(response, "user", "alice")
  close(client)
  stop_supervisor(server_pid)
}
