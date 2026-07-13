import beryl
import beryl_demo/config
import beryl_demo/expiry
import beryl_demo/server
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

type WebsocketClient

@external(erlang, "beryl_demo_test_ffi", "connect_websocket")
fn connect_websocket(port: Int, path: String) -> Result(WebsocketClient, Nil)

@external(erlang, "beryl_demo_test_ffi", "websocket_upgrade_status")
fn websocket_upgrade_status(port: Int, path: String) -> Result(Int, Nil)

@external(erlang, "beryl_demo_test_ffi", "websocket_upgrade_status_with_origin")
fn websocket_upgrade_status_with_origin(
  port: Int,
  path: String,
  origin: String,
) -> Result(Int, Nil)

@external(erlang, "beryl_demo_test_ffi", "send_text")
fn send_text(
  client: WebsocketClient,
  text: String,
) -> Result(WebsocketClient, Nil)

@external(erlang, "beryl_demo_test_ffi", "receive_text")
fn receive_text(client: WebsocketClient, timeout: Int) -> Result(String, Nil)

@external(erlang, "beryl_demo_test_ffi", "close")
fn close(client: WebsocketClient) -> Nil

@external(erlang, "beryl_demo_test_ffi", "http_get")
fn http_get(port: Int, path: String) -> Result(Int, Nil)

@external(erlang, "beryl_demo_test_ffi", "stop")
fn stop(pid: process.Pid) -> Nil

// ─────────────────────────────────────────────────────────────────────────────
// Phoenix V2 frame helpers copied verbatim from `test/phoenix_contract_test.gleam:44-169`.
// ─────────────────────────────────────────────────────────────────────────────

type Frame {
  Frame(
    join_ref: Option(String),
    ref: Option(String),
    topic: String,
    event: String,
    payload: dynamic.Dynamic,
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

fn dynamic_field(payload: dynamic.Dynamic, field: String) -> dynamic.Dynamic {
  let decoder = {
    use value <- decode.field(field, decode.dynamic)
    decode.success(value)
  }
  let assert Ok(value) = decode.run(payload, decoder)
  value
}

fn assert_json_int(payload: dynamic.Dynamic, field: String, expected: Int) {
  let decoder = {
    use actual <- decode.field(field, decode.int)
    decode.success(actual)
  }
  let assert Ok(actual) = decode.run(payload, decoder)
  actual |> should.equal(expected)
}

/// Wait for the exact `event` (and optional `ref`) from the socket, discarding
/// intervening frames. Prevents flakiness from arbitrary first messages.
fn receive_frame(
  client: WebsocketClient,
  event: String,
  expected_ref: Option(String),
  remaining: Int,
) -> Frame {
  let assert True = remaining > 0
  let assert Ok(raw) = receive_text(client, 500)
  let assert Ok(frame) = decode_json_frame(raw)
  let reference_matches = case expected_ref {
    None -> True
    Some(reference) -> frame.ref == Some(reference)
  }

  case frame.event == event && reference_matches {
    True -> frame
    False -> receive_frame(client, event, expected_ref, remaining - 1)
  }
}

/// Wait for a `presence_diff` frame whose `section` (either `"joins"` or
/// `"leaves"`) contains the given presence `key`. Discards intervening frames
/// and diffs that do not touch `key`, which prevents false matches on the
/// current socket's own join/leave diff.
fn receive_presence_diff_with_key(
  client: WebsocketClient,
  section: String,
  key: String,
  remaining: Int,
) -> Frame {
  let frame = receive_frame(client, "presence_diff", None, remaining)
  let section_dyn = dynamic_field(frame.payload, section)
  case decode.run(section_dyn, decode.dict(decode.string, decode.dynamic)) {
    Ok(entries) ->
      case dict.has_key(entries, key) {
        True -> frame
        False ->
          receive_presence_diff_with_key(client, section, key, remaining - 1)
      }
    Error(_) ->
      receive_presence_diff_with_key(client, section, key, remaining - 1)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Server lifecycle helpers
// ─────────────────────────────────────────────────────────────────────────────

fn start_test_server(origin_mode: server.OriginMode) -> server.Started {
  let service_config = config.Config(..config.default(), port: 0)
  let assert Ok(started) = server.start(service_config, origin_mode)
  started
}

fn stop_started(started: server.Started) -> Nil {
  expiry.stop(started.expiry)
  beryl.stop(started.channels)
  stop(started.supervisor.pid)
}

fn join_frame(
  reference: String,
  topic: String,
  client_id: String,
  name: String,
  color: String,
) -> String {
  encode_json_frame(
    Some(reference),
    Some(reference),
    topic,
    "phx_join",
    json.object([
      #("client_id", json.string(client_id)),
      #("compatibility_version", json.int(1)),
      #("name", json.string(name)),
      #("color", json.string(color)),
    ]),
  )
}

fn connect_clients(
  port: Int,
  remaining: Int,
  clients: List(WebsocketClient),
) -> List(WebsocketClient) {
  case remaining {
    0 -> clients
    _ -> {
      let assert Ok(client) = connect_websocket(port, config.socket_path)
      connect_clients(port, remaining - 1, [client, ..clients])
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

pub fn status_routes_are_available_test() {
  let started = start_test_server(server.TestOnlyAllowAll)
  http_get(started.port, "/healthz") |> should.equal(Ok(200))
  http_get(started.port, "/v1/status") |> should.equal(Ok(200))
  stop_started(started)
}

pub fn production_origin_policy_rejects_other_sites_test() {
  let service_config =
    config.Config(..config.default(), port: 0, allowed_origins: [
      "https://beryl.tylerbutler.com",
    ])
  let assert Ok(started) =
    server.start(
      service_config,
      server.AllowOrigins(service_config.allowed_origins),
    )

  websocket_upgrade_status_with_origin(
    started.port,
    config.socket_path,
    "https://evil.example",
  )
  |> should.equal(Ok(403))
  websocket_upgrade_status_with_origin(
    started.port,
    config.socket_path,
    "https://beryl.tylerbutler.com",
  )
  |> should.equal(Ok(101))
  stop_started(started)
}

pub fn ninth_same_ip_connection_is_rejected_test() {
  let started = start_test_server(server.TestOnlyAllowAll)
  let clients = connect_clients(started.port, 8, [])
  websocket_upgrade_status(started.port, config.socket_path)
  |> should.equal(Ok(429))
  list.each(clients, close)
  stop_started(started)
}

pub fn oversized_frame_closes_connection_test() {
  let started = start_test_server(server.TestOnlyAllowAll)
  let assert Ok(client) = connect_websocket(started.port, config.socket_path)
  let assert Ok(_) = send_text(client, string.repeat("a", 16 * 1024 + 1))
  receive_text(client, 200) |> should.equal(Error(Nil))
  close(client)
  stop_started(started)
}

pub fn presence_join_broadcasts_diff_to_peers_test() {
  let started = start_test_server(server.TestOnlyAllowAll)
  let topic = "demo:presence:11111111111111111111111111111111"

  let assert Ok(primary) = connect_websocket(started.port, config.socket_path)
  let assert Ok(_) =
    send_text(
      primary,
      join_frame(
        "1",
        topic,
        "11111111-1111-1111-1111-111111111111",
        "Alice",
        "emerald",
      ),
    )
  let reply = receive_frame(primary, "phx_reply", Some("1"), 10)
  assert_json_string(reply.payload, "status", "ok")
  let response = dynamic_field(reply.payload, "response")
  assert_json_int(response, "compatibility_version", 1)
  let presence_state = dynamic_field(response, "presence_state")
  presence_state
  |> decode.run(decode.dict(decode.string, decode.dynamic))
  |> should.be_ok

  let assert Ok(secondary) = connect_websocket(started.port, config.socket_path)
  let assert Ok(_) =
    send_text(
      secondary,
      join_frame(
        "2",
        topic,
        "22222222-2222-2222-2222-222222222222",
        "Bob",
        "magenta",
      ),
    )
  let _secondary_reply = receive_frame(secondary, "phx_reply", Some("2"), 10)

  let bob_key = "22222222-2222-2222-2222-222222222222"
  let join_diff = receive_presence_diff_with_key(primary, "joins", bob_key, 20)
  let joins = dynamic_field(join_diff.payload, "joins")
  let bob = dynamic_field(joins, bob_key)
  let metas = dynamic_field(bob, "metas")
  metas
  |> decode.run(decode.list(decode.dynamic))
  |> should.be_ok

  close(secondary)
  let leave_diff =
    receive_presence_diff_with_key(primary, "leaves", bob_key, 20)
  let leaves = dynamic_field(leave_diff.payload, "leaves")
  let bob_leave = dynamic_field(leaves, bob_key)
  let leave_metas = dynamic_field(bob_leave, "metas")
  leave_metas
  |> decode.run(decode.list(decode.dynamic))
  |> should.be_ok

  close(primary)
  stop_started(started)
}

pub fn expired_scenario_closes_channels_and_rejects_rejoin_test() {
  let service_config =
    config.Config(..config.default(), port: 0, session_ttl_ms: 100)
  let assert Ok(started) = server.start(service_config, server.TestOnlyAllowAll)
  let topic = "demo:presence:33333333333333333333333333333333"

  let assert Ok(primary) = connect_websocket(started.port, config.socket_path)
  let assert Ok(_) =
    send_text(
      primary,
      join_frame(
        "1",
        topic,
        "33333333-3333-3333-3333-333333333333",
        "Alice",
        "emerald",
      ),
    )
  let _reply = receive_frame(primary, "phx_reply", Some("1"), 10)
  let _close_frame = receive_frame(primary, "phx_close", None, 20)
  close(primary)

  let assert Ok(rejoin) = connect_websocket(started.port, config.socket_path)
  let assert Ok(_) =
    send_text(
      rejoin,
      join_frame(
        "2",
        topic,
        "33333333-3333-3333-3333-333333333333",
        "Alice",
        "emerald",
      ),
    )
  let rejected = receive_frame(rejoin, "phx_reply", Some("2"), 10)
  assert_json_string(rejected.payload, "status", "error")
  rejected.payload
  |> dynamic_field("response")
  |> assert_json_int("code", 410)
  close(rejoin)
  stop_started(started)
}

/// Regression for the `untrack_all` presence-cleanup bug: leaving one topic on
/// a socket that has joined two topics must remove only the ref-tracked
/// presence for the topic being left. The other topic's presence must remain
/// intact, which a fresh verifier proves by observing the original client in
/// the second topic's `presence_state`.
pub fn leaving_one_topic_preserves_other_topic_presence_test() {
  let started = start_test_server(server.TestOnlyAllowAll)
  let topic_x = "demo:presence:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let topic_y = "demo:presence:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let alice_key = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

  let assert Ok(alice) = connect_websocket(started.port, config.socket_path)
  let assert Ok(_) =
    send_text(alice, join_frame("1", topic_x, alice_key, "Alice", "emerald"))
  let _reply_x = receive_frame(alice, "phx_reply", Some("1"), 10)
  let assert Ok(_) =
    send_text(alice, join_frame("2", topic_y, alice_key, "Alice", "emerald"))
  let _reply_y = receive_frame(alice, "phx_reply", Some("2"), 10)

  // Leave only topic X. join_ref matches the ref used when joining X so the
  // leave is not treated as a stale rejoin.
  let leave =
    encode_json_frame(
      Some("1"),
      Some("3"),
      topic_x,
      "phx_leave",
      json.object([]),
    )
  let assert Ok(_) = send_text(alice, leave)
  let _leave_reply = receive_frame(alice, "phx_reply", Some("3"), 10)
  let _leave_close = receive_frame(alice, "phx_close", None, 10)

  // Fresh verifier joins topic Y and reads Alice from the presence_state
  // captured at join. If terminate had used `presence.untrack_all(socket_id)`,
  // Alice's Y presence would be gone by now and this assertion would fail.
  let assert Ok(verifier) = connect_websocket(started.port, config.socket_path)
  let verifier_key = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
  let assert Ok(_) =
    send_text(
      verifier,
      join_frame("1", topic_y, verifier_key, "Bob", "magenta"),
    )
  let reply = receive_frame(verifier, "phx_reply", Some("1"), 10)
  assert_json_string(reply.payload, "status", "ok")
  let response = dynamic_field(reply.payload, "response")
  let presence_state = dynamic_field(response, "presence_state")
  let alice_entry = dynamic_field(presence_state, alice_key)
  let alice_metas = dynamic_field(alice_entry, "metas")
  alice_metas
  |> decode.run(decode.list(decode.dynamic))
  |> should.be_ok

  close(alice)
  close(verifier)
  stop_started(started)
}
