//// Frame-rate vs. message-rate accounting at the transport edge.
////
//// `beryl/transport/server` carries the inbound frame pipeline (size caps,
//// frame-rate limiting, decode, routing) that a real transport such as
//// `beryl_mist`/`beryl_ewe` drives from a live socket. These tests drive
//// that same pipeline directly — `server.init_connection` plus
//// `server.handle_text_frame` — without a network round trip, so the edge
//// admission logic is exercised exactly as a transport would use it.
////
//// `with_frame_rate` governs the edge bucket here (every complete frame,
//// pre-decode); `with_message_rate` governs the runtime's post-decode
//// bucket (see `app_abuse_test.gleam`). The two are independent: this file
//// proves neither setting alone does the other's job, and that configuring
//// both makes valid traffic pay both costs.

import app_test_helper
import beryl
import beryl/internal
import beryl/socket
import beryl/transport
import beryl/transport/server
import beryl/wire
import gleam/erlang/process
import gleam/option
import gleam/string
import gleeunit/should
import test_helper

/// Palabres's level is a global, singleton setting (see
/// `beryl/internal.configure`); restore it to beryl's own default so a
/// `DebugLevel` test doesn't leak verbosity into tests that run after it.
fn restore_default_logging_level() -> Nil {
  internal.configure(internal.LoggingConfig(
    level: internal.Info,
    include_payloads: False,
    payload_preview_bytes: 200,
  ))
}

fn start_system(config: beryl.Config) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      config,
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )
  channels
}

type Conn {
  Conn(
    state: server.ConnectionState,
    selector: process.Selector(server.SendRequest),
  )
}

fn connect(channels: beryl.Sockets, ip: String) -> Conn {
  let assert Ok(permit) = transport.acquire_connection_slot(channels, ip)
  let #(state, selector) =
    server.init_connection(
      sockets: channels,
      seed: socket.empty_seed(),
      connection_permit: permit,
      base_selector: process.new_selector(),
      logger_name: "transport_server_rate_test",
      telemetry: transport.telemetry(channels, transport.Mist),
      codec: option.None,
    )
  Conn(state, selector)
}

/// Feed one text frame through the edge pipeline, returning the updated
/// connection (state carries the frame limiter's bucket forward).
fn send_text(conn: Conn, text: String) -> Conn {
  case server.handle_text_frame(conn.state, text) {
    server.Continue(state) -> Conn(..conn, state: state)
    server.Stop -> conn
  }
}

fn heartbeat(ref: String) -> String {
  "[null,\"" <> ref <> "\",\"phoenix\",\"heartbeat\",{}]"
}

/// Receive the next frame the runtime/edge sent back, `Error(Nil)` if none
/// arrives within the timeout.
fn recv(conn: Conn) -> Result(String, Nil) {
  case process.selector_receive(from: conn.selector, within: 300) {
    Ok(server.SendText(text)) -> Ok(text)
    Ok(server.SendBinary(_)) -> Error(Nil)
    Ok(server.Close) -> Error(Nil)
    Error(Nil) -> Error(Nil)
  }
}

fn flood_heartbeats(conn: Conn, remaining: Int) -> Conn {
  case remaining <= 0 {
    True -> conn
    False -> {
      let conn = send_text(conn, heartbeat("flood"))
      process.sleep(5)
      flood_heartbeats(conn, remaining - 1)
    }
  }
}

// ── Frame-only ───────────────────────────────────────────────────────────

pub fn frame_rate_alone_sheds_flood_before_decode_test() -> Nil {
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_frame_rate(per_second: 1, burst: 1)
  let channels = start_system(config)
  let conn = connect(channels, "10.10.10.1")

  let conn = send_text(conn, heartbeat("hb-1"))
  let assert Ok(reply) = recv(conn)
  reply |> string.contains("hb-1") |> should.be_true

  let conn = send_text(conn, heartbeat("hb-2"))
  recv(conn) |> should.equal(Error(Nil))
}

pub fn frame_rate_counts_malformed_frames_test() -> Nil {
  // A malformed frame consumes a frame-rate token exactly like a
  // well-formed one — it never reaches decode, but it still counts.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_frame_rate(per_second: 1, burst: 1)
  let channels = start_system(config)
  let conn = connect(channels, "10.10.10.2")

  let conn = send_text(conn, "not-valid-json")
  let conn = send_text(conn, heartbeat("hb-1"))

  // The single frame token was spent on the malformed frame, so the
  // following valid heartbeat is shed at the edge with no reply.
  recv(conn) |> should.equal(Error(Nil))
}

pub fn frame_rate_limited_heartbeats_lead_to_eviction_test() -> Nil {
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_heartbeat(timeout_ms: 40)
    |> beryl.with_frame_rate(per_second: 1, burst: 1)
  let channels = start_system(config)
  let conn = connect(channels, "10.10.10.6")

  // Spend the only burst token on a heartbeat, then keep sending heartbeats
  // faster than the edge bucket can refill. None of the shed frames reach the
  // runtime, so the normal timeout path asks the transport to close.
  let conn = send_text(conn, heartbeat("hb-1"))
  let assert Ok(reply) = recv(conn)
  reply |> string.contains("hb-1") |> should.be_true
  let conn = flood_heartbeats(conn, 20)

  process.selector_receive(from: conn.selector, within: 1000)
  |> should.equal(Ok(server.Close))
}

// ── Message-only ─────────────────────────────────────────────────────────

pub fn message_rate_alone_does_not_shed_at_the_edge_test() -> Nil {
  // With no frame_rate configured, every frame reaches decode and routing;
  // the runtime's message-rate bucket is what sheds the flood. A dropped
  // reply alone would be identical to edge-level shedding, so this test
  // additionally observes the runtime's own "Message rate limited" debug
  // log — it only fires once the decoded envelope has reached the runtime
  // and been rejected there, which an edge-level shed (no decode, no
  // runtime dispatch at all) could never produce.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 1, burst: 1)
    |> beryl.with_logging(beryl.logging_config(
      level: beryl.DebugLevel,
      include_payloads: False,
    ))
  let channels = start_system(config)
  let conn = connect(channels, "10.10.10.3")
  let selector = test_helper.begin_capture()

  let conn = send_text(conn, heartbeat("hb-1"))
  let assert Ok(reply) = recv(conn)
  reply |> string.contains("hb-1") |> should.be_true

  let conn = send_text(conn, heartbeat("hb-2"))
  recv(conn) |> should.equal(Error(Nil))

  // The second heartbeat's envelope reached the runtime and was rejected
  // by the message-rate gate there — proof the edge itself admitted the
  // frame and did no shedding of its own.
  test_helper.receive_log(selector, "Message rate limited", 10) |> should.be_ok

  let _conn = conn
  test_helper.stop_capture()
  restore_default_logging_level()
}

// ── Combined accounting ──────────────────────────────────────────────────

pub fn combined_rates_both_gate_valid_traffic_test() -> Nil {
  // frame_rate's burst (3) is generous; message_rate's burst (1) is the
  // binding constraint. Every heartbeat reaches decode/routing (frame
  // gate clears), but only the first gets a reply (message gate binds).
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_frame_rate(per_second: 1, burst: 3)
    |> beryl.with_message_rate(per_second: 1, burst: 1)
  let channels = start_system(config)
  let conn = connect(channels, "10.10.10.4")

  let conn = send_text(conn, heartbeat("hb-1"))
  let assert Ok(reply) = recv(conn)
  reply |> string.contains("hb-1") |> should.be_true

  let conn = send_text(conn, heartbeat("hb-2"))
  recv(conn) |> should.equal(Error(Nil))

  let conn = send_text(conn, heartbeat("hb-3"))
  recv(conn) |> should.equal(Error(Nil))

  let _conn = conn
  Nil
}

pub fn combined_rates_frame_gate_binds_first_test() -> Nil {
  // Reversed: frame_rate's burst (1) is the binding constraint here, even
  // though message_rate would allow more. Proves the frame gate runs
  // before decode regardless of how generous the message gate is.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_frame_rate(per_second: 1, burst: 1)
    |> beryl.with_message_rate(per_second: 1, burst: 3)
  let channels = start_system(config)
  let conn = connect(channels, "10.10.10.5")

  let conn = send_text(conn, heartbeat("hb-1"))
  let assert Ok(reply) = recv(conn)
  reply |> string.contains("hb-1") |> should.be_true

  let conn = send_text(conn, heartbeat("hb-2"))
  recv(conn) |> should.equal(Error(Nil))

  let _conn = conn
  Nil
}
