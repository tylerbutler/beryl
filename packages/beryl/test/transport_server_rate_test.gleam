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

import beryl
import beryl/socket
import beryl/transport/server
import beryl/wire
import gleam/erlang/process
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn start_system(config: beryl.Config) -> beryl.Sockets {
  let assert Ok(channels) =
    beryl.start(config, init: fn(_info) { #(Nil, []) }, update: fn(model, ev) {
      case ev {
        socket.Join(_, _, ref) ->
          socket.Next(model, [socket.AcceptJoin(ref, option.None)])
        _ -> socket.Next(model, [])
      }
    })
  channels
}

type Conn {
  Conn(
    state: server.ConnectionState,
    selector: process.Selector(server.SendRequest),
  )
}

fn connect(channels: beryl.Sockets, ip: String) -> Conn {
  let assert Ok(permit) = beryl.acquire_connection_slot(channels, ip)
  let #(state, selector) =
    server.init_connection(
      sockets: channels,
      seed: socket.empty_seed(),
      connection_permit: permit,
      base_selector: process.new_selector(),
      logger_name: "transport_server_rate_test",
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

// ── Frame-only ───────────────────────────────────────────────────────────

pub fn frame_rate_alone_sheds_flood_before_decode_test() {
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

pub fn frame_rate_counts_malformed_frames_test() {
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

// ── Message-only ─────────────────────────────────────────────────────────

pub fn message_rate_alone_does_not_shed_at_the_edge_test() {
  // With no frame_rate configured, every frame reaches decode and routing;
  // the runtime's message-rate bucket is what sheds the flood (invisible
  // from this layer as anything other than a dropped reply — the edge
  // itself never rejects the frame).
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 1, burst: 1)
  let channels = start_system(config)
  let conn = connect(channels, "10.10.10.3")

  let conn = send_text(conn, heartbeat("hb-1"))
  let assert Ok(reply) = recv(conn)
  reply |> string.contains("hb-1") |> should.be_true

  let conn = send_text(conn, heartbeat("hb-2"))
  recv(conn) |> should.equal(Error(Nil))
}

// ── Combined accounting ──────────────────────────────────────────────────

pub fn combined_rates_both_gate_valid_traffic_test() {
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

pub fn combined_rates_frame_gate_binds_first_test() {
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
