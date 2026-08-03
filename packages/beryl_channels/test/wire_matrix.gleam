//// One Phoenix wire-contract harness, run against two systems.
////
//// The point of this module is that there is exactly **one** copy of every
//// moving part a contract scenario needs — the transport server, the wire
//// codec, the WebSocket client, the frame builders, the frame decoder —
//// and exactly **two** ways to build the system under test:
////
////   * `beryl.child_spec` with a hand-written `update`, and
////   * `beryl_channels.child_spec` with a handler table.
////
//// Both implement the same application contract (see "The contract app"
//// below), both are served by the same `beryl_mist` transport over a real
//// WebSocket, and both are configured with the same `beryl.Config`.
//// [`compare`](#compare) runs one scenario body against both and fails if
//// the two systems are observably different, so no scenario has to be
//// written twice.
////
//// Nothing here imports a beryl internal module or re-implements any part
//// of the transport or the codec: the frames on the wire are produced and
//// consumed by `beryl`, `beryl_mist` and `gluegun`.

import beryl
import beryl/presence
import beryl/socket
import beryl/topic
import beryl/transport/server
import beryl/wire
import beryl/wire/codec
import beryl_channels
import beryl_channels/channel
import beryl_mist
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleeunit/should
import gluegun/connection
import gluegun/message
import gluegun/websocket
import mist
import phoenix_channel_fixtures/frame as fixtures

/// The path both systems are served on.
pub const socket_path = "/socket/websocket"

/// The only topic pattern the contract app answers to.
pub const room_pattern = "room:*"

// ---------------------------------------------------------------------------
// The contract app
//
// Two implementations of one observable behaviour:
//
//   join            accept with `{joined: true, topic: <topic>}`, unless the
//                   join payload carries `{"deny": true}`, which is refused
//                   with `{reason: "denied"}`
//   join elsewhere  refused with `{reason: "unmatched topic"}`
//   "ping"          reply ok `{pong: true}`
//   "boom"          reply error `{reason: "nope"}`
//   "push_me"       push `pushed` to the calling socket only
//   "shout"         broadcast_from `shouted`, echoing the client payload
//   "track"         presence-track "alice", then broadcast a snapshot
//   "blob"          a codec-decoded binary payload: push its byte size
//   raw binary      an undecoded binary frame: push its byte size
// ---------------------------------------------------------------------------

/// The hand-written `update` half of the matrix.
pub fn raw_update() -> fn(Nil, socket.Input(Nil)) -> socket.Next(Nil, Nil) {
  let pattern = topic.parse_pattern(room_pattern)
  fn(model, input) { socket.Next(model, raw_effects(pattern, input)) }
}

fn raw_effects(
  pattern: topic.TopicPattern,
  input: socket.Input(Nil),
) -> List(socket.Effect) {
  case input {
    socket.Join(name, payload, ref) -> raw_join(pattern, name, payload, ref)
    socket.Message(_name, "ping", _payload, Some(ref)) -> [
      socket.ReplyOk(ref, pong_payload()),
    ]
    socket.Message(_name, "boom", _payload, Some(ref)) -> [
      socket.ReplyError(ref, boom_payload()),
    ]
    socket.Message(name, "push_me", _payload, _ref) -> [
      socket.Push(name, pushed_event, pushed_payload()),
    ]
    socket.Message(name, "shout", payload, _ref) -> [
      socket.BroadcastFrom(name, shouted_event, wire.dynamic_to_json(payload)),
    ]
    socket.Message(name, "track", _payload, _ref) -> [
      socket.PresenceTrack(name, presence_key, presence_meta()),
      socket.BroadcastPresence(name, presence_event, encode_presence),
    ]
    socket.Message(name, "blob", payload, _ref) -> [
      socket.Push(name, binary_event, binary_payload("decoded", payload)),
    ]
    socket.Binary(name, data) -> [
      socket.Push(
        name,
        binary_event,
        binary_size_payload("raw", bit_array.byte_size(data)),
      ),
    ]
    _ -> []
  }
}

fn raw_join(
  pattern: topic.TopicPattern,
  name: String,
  payload: dynamic.Dynamic,
  ref: socket.Ref,
) -> List(socket.Effect) {
  use <- guard_reject(topic.matches(pattern, name), ref, unmatched_payload())
  use <- guard_reject(!denied(payload), ref, denied_payload())
  [socket.AcceptJoin(ref, Some(join_reply(name)))]
}

fn guard_reject(
  allowed: Bool,
  ref: socket.Ref,
  reason: json.Json,
  otherwise: fn() -> List(socket.Effect),
) -> List(socket.Effect) {
  case allowed {
    True -> otherwise()
    False -> [socket.RejectJoin(ref, reason)]
  }
}

/// The handler-table half of the matrix.
pub fn handlers() -> List(channel.Handler) {
  [
    channel.handler(room_pattern, fn(_info, name, payload) {
      case denied(payload) {
        True -> channel.reject(denied_payload())
        False ->
          channel.accept_with(
            channel.joined(Nil, contract_callbacks()),
            join_reply(name),
          )
      }
    }),
  ]
}

fn contract_callbacks() -> channel.Callbacks(Nil, Nil) {
  channel.callbacks()
  |> channel.on_message(fn(state, msg) {
    channel.continue_with(state, message_actions(msg))
  })
  |> channel.on_binary(fn(state, data) {
    channel.continue_with(
      state,
      channel.actions()
        |> channel.push(
          binary_event,
          binary_size_payload("raw", bit_array.byte_size(data)),
        ),
    )
  })
}

fn message_actions(msg: channel.Message) -> channel.Actions {
  let actions = channel.actions()
  case msg.event, msg.reply {
    "ping", Some(ref) -> channel.reply_ok(actions, ref, pong_payload())
    "boom", Some(ref) -> channel.reply_error(actions, ref, boom_payload())
    "push_me", _ -> channel.push(actions, pushed_event, pushed_payload())
    "shout", _ ->
      channel.broadcast_from(
        actions,
        shouted_event,
        wire.dynamic_to_json(msg.payload),
      )
    "track", _ ->
      actions
      |> channel.presence_track(presence_key, presence_meta())
      |> channel.broadcast_presence(presence_event, encode_presence)
    "blob", _ ->
      channel.push(
        actions,
        binary_event,
        binary_payload("decoded", msg.payload),
      )
    _, _ -> actions
  }
}

// --- Shared payloads, so neither half can drift from the other ------------

const pushed_event = "pushed"

const shouted_event = "shouted"

const binary_event = "binary_in"

const presence_event = "presence_list"

const presence_key = "alice"

fn join_reply(name: String) -> json.Json {
  json.object([#("joined", json.bool(True)), #("topic", json.string(name))])
}

fn denied_payload() -> json.Json {
  json.object([#("reason", json.string("denied"))])
}

fn unmatched_payload() -> json.Json {
  json.object([#("reason", json.string("unmatched topic"))])
}

fn pong_payload() -> json.Json {
  json.object([#("pong", json.bool(True))])
}

fn boom_payload() -> json.Json {
  json.object([#("reason", json.string("nope"))])
}

fn pushed_payload() -> json.Json {
  json.object([#("from", json.string("server"))])
}

fn presence_meta() -> json.Json {
  json.object([#("status", json.string("online"))])
}

fn binary_payload(kind: String, payload: dynamic.Dynamic) -> json.Json {
  let size =
    decode.run(payload, decode.bit_array)
    |> result_size
  binary_size_payload(kind, size)
}

fn result_size(decoded: Result(BitArray, a)) -> Int {
  case decoded {
    Ok(data) -> bit_array.byte_size(data)
    Error(_) -> -1
  }
}

fn binary_size_payload(kind: String, size: Int) -> json.Json {
  json.object([#("kind", json.string(kind)), #("bytes", json.int(size))])
}

/// Presence snapshots are encoded as the tracked keys alone.
///
/// A snapshot that echoed `entry.meta` could not be compared across the
/// two systems: beryl stamps every tracked entry with a random `phx_ref`,
/// so the two runs would differ on a value neither dispatch layer
/// controls. The metadata round-trip is still observed — the
/// `presence_diff` the core broadcasts carries it verbatim.
fn encode_presence(entries: List(presence.PresenceEntry)) -> json.Json {
  json.preprocessed_array(
    list.map(entries, fn(entry) { json.string(entry.key) }),
  )
}

fn denied(payload: dynamic.Dynamic) -> Bool {
  let decoder = {
    use deny <- decode.optional_field("deny", False, decode.bool)
    decode.success(deny)
  }
  case decode.run(payload, decoder) {
    Ok(deny) -> deny
    Error(_) -> False
  }
}

// ---------------------------------------------------------------------------
// System factory
// ---------------------------------------------------------------------------

/// One way of building a system that implements the contract app.
pub type Variant {
  Variant(name: String, start: fn(beryl.Config) -> beryl.Sockets)
}

/// A started system, served over a real WebSocket on `port`.
pub type System {
  System(variant: String, sockets: beryl.Sockets, port: Int)
}

/// The two systems every scenario is run against.
pub fn variants() -> List(Variant) {
  [
    Variant(name: "beryl.child_spec", start: fn(config) {
      let assert Ok(#(sockets, spec)) =
        beryl.child_spec(
          config,
          init: fn(_info: socket.ConnectInfo(Nil)) { #(Nil, []) },
          update: raw_update(),
        )
        as "the raw contract system builds"
      let assert Ok(_) =
        static_supervisor.new(static_supervisor.OneForOne)
        |> static_supervisor.add(spec)
        |> static_supervisor.start()
        as "the raw contract supervision tree starts"
      sockets
    }),
    Variant(name: "beryl_channels.child_spec", start: fn(config) {
      let assert Ok(#(sockets, spec)) =
        beryl_channels.child_spec(config, handlers: handlers())
        as "the channel contract system builds"
      let assert Ok(_) =
        static_supervisor.new(static_supervisor.OneForOne)
        |> static_supervisor.add(spec)
        |> static_supervisor.start()
        as "the channel contract supervision tree starts"
      sockets
    }),
  ]
}

/// The default config both variants share: the stock Phoenix codec, which
/// decodes binary frames into ordinary events.
pub fn default_config() -> beryl.Config {
  beryl.config(wire.phoenix_codec())
}

/// The Phoenix framing *without* its binary decoder, so raw binary frames
/// reach the app undecoded instead of arriving as events.
pub fn text_only_config() -> beryl.Config {
  beryl.config(
    codec.new(
      decode_text: wire.decode_message,
      encode_reply: wire.reply_json,
      encode_push: wire.push,
      encode_heartbeat_reply: wire.heartbeat_reply,
    )
    |> codec.with_close_encoder(wire.channel_close)
    |> codec.with_error_encoder(wire.channel_error),
  )
}

/// Run one scenario against both variants and require them to observe the
/// same thing.
///
/// `setup` is called once per variant, so each run gets its own config and
/// its own context value (a fresh presence actor, for example). The
/// scenario's return value is the observation that is compared across the
/// two systems; it is also returned, so a scenario can additionally assert
/// what that shared observation must *be* rather than only that the two
/// agree.
pub fn compare(
  setup setup: fn() -> #(beryl.Config, ctx),
  scenario scenario: fn(System, ctx) -> observation,
) -> observation {
  let observations =
    list.map(variants(), fn(variant) {
      let #(config, context) = setup()
      let sockets = variant.start(config)
      let #(port, supervisor) = start_transport(sockets)
      let observed = scenario(System(variant.name, sockets, port), context)
      stop_transport(supervisor)
      let assert Ok(Nil) = beryl.stop(sockets) as "the system stops cleanly"
      observed
    })

  let assert [raw, layered] = observations
    as "the matrix runs exactly two variants"
  raw |> should.equal(layered)
  raw
}

/// `compare` for scenarios that need no extra context.
pub fn compare_with(
  config config: fn() -> beryl.Config,
  scenario scenario: fn(System) -> observation,
) -> observation {
  compare(setup: fn() { #(config(), Nil) }, scenario: fn(system, _context) {
    scenario(system)
  })
}

fn start_transport(sockets: beryl.Sockets) -> #(Int, process.Pid) {
  let ports = process.new_subject()
  let handler = fn(request) {
    beryl_mist.upgrade(
      request,
      sockets,
      server.default_config(socket_path),
      fn() {
        response.new(404)
        |> response.set_body(mist.Bytes(bytes_tree.new()))
      },
    )
  }

  let assert Ok(started) =
    handler
    |> mist.new
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _scheme, _ip) { process.send(ports, port) })
    |> mist.start
    as "the mist server starts on a free port"
  let assert Ok(port) = process.receive(ports, 1000)
    as "the mist server reports its port"
  #(port, started.pid)
}

fn stop_transport(supervisor: process.Pid) -> Nil {
  // Unlink first: the test process started this supervisor, so an exit
  // signal to a linked process would take the test down with it. `shutdown`
  // (not `kill`) lets the supervisor terminate its acceptors gracefully
  // instead of dumping a crash report for every one of them.
  process.unlink(supervisor)
  let watch = process.monitor(supervisor)
  process.send_abnormal_exit(supervisor, atom.create("shutdown"))
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })
  let assert Ok(Nil) = process.selector_receive(selector, 5000)
    as "the transport server terminates"
  Nil
}

// ---------------------------------------------------------------------------
// WebSocket client
// ---------------------------------------------------------------------------

/// A connected WebSocket client.
pub type Client =
  websocket.Socket

/// Connect a client to a running system.
pub fn connect(system: System) -> Client {
  let assert Ok(client) =
    websocket.connect(
      host: "127.0.0.1",
      port: system.port,
      path: socket_path,
      options: websocket.options()
        |> websocket.with_timeout(connection.Milliseconds(500)),
    )
    as "the websocket client connects"
  client
}

/// Send a raw text frame.
pub fn send(client: Client, raw: String) -> Nil {
  let assert Ok(Nil) = websocket.send_text(client, raw)
    as "the text frame is sent"
  Nil
}

/// Send a raw binary frame.
pub fn send_binary(client: Client, data: BitArray) -> Nil {
  let assert Ok(Nil) = websocket.send_binary(client, data)
    as "the binary frame is sent"
  Nil
}

/// Receive and decode the next server frame, failing if none arrives.
pub fn next(client: Client) -> Frame {
  let assert Ok(message.Text(raw)) = websocket.receive_app_frame(client)
    as "a server text frame arrives"
  decode_frame(raw)
}

/// Receive and decode exactly `count` server frames, in order.
pub fn take(client: Client, count: Int) -> List(Frame) {
  case count {
    0 -> []
    _ -> {
      let frame = next(client)
      [frame, ..take(client, count - 1)]
    }
  }
}

/// Receive exactly `count` frames and prove the server sent no more.
///
/// The proof is a fence rather than a timeout: a heartbeat travels the same
/// path as the frames just read — one client connection into one runtime
/// actor — so anything the server had already queued for this socket
/// arrives *before* the heartbeat reply. An extra frame therefore fails
/// the fence and is printed, instead of being silently discarded when the
/// scenario ends. Absence that has to outlast a *different* path (a
/// PubSub broadcast, say) still needs [`expect_silence`](#expect_silence).
pub fn take_exactly(client: Client, count: Int) -> List(Frame) {
  let frames = take(client, count)
  fence(client)
  frames
}

/// Assert that nothing is queued for this socket. See
/// [`take_exactly`](#take_exactly).
pub fn fence(client: Client) -> Nil {
  send(client, heartbeat_frame(fence_ref))
  next(client)
  |> should.equal(Frame(
    join_ref: None,
    ref: Some(fence_ref),
    topic: fixtures.heartbeat_topic,
    event: fixtures.reply_event,
    payload: "{\"response\":{},\"status\":\"ok\"}",
  ))
}

const fence_ref = "fence"

/// Assert the server sends nothing more.
pub fn expect_silence(client: Client) -> Nil {
  websocket.receive_app_frame(client) |> should.be_error
  Nil
}

/// Close a client connection.
pub fn close(client: Client) -> Nil {
  let assert Ok(Nil) = websocket.close(client) as "the client closes"
  Nil
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

/// A decoded server frame, with its payload canonicalised to JSON text so
/// that two systems' observations compare structurally.
pub type Frame {
  Frame(
    join_ref: Option(String),
    ref: Option(String),
    topic: String,
    event: String,
    payload: String,
  )
}

/// A `phx_join` frame carrying `payload`.
pub fn join_frame(
  join_ref: String,
  ref: String,
  name: String,
  payload: json.Json,
) -> String {
  encode_frame(Some(join_ref), Some(ref), name, fixtures.join_event, payload)
}

/// A `phx_leave` frame.
pub fn leave_frame(join_ref: String, ref: String, name: String) -> String {
  encode_frame(
    Some(join_ref),
    Some(ref),
    name,
    fixtures.leave_event,
    json.object([]),
  )
}

/// An application event frame that asks for a reply.
pub fn event_frame(
  join_ref: String,
  ref: String,
  name: String,
  event: String,
  payload: json.Json,
) -> String {
  encode_frame(Some(join_ref), Some(ref), name, event, payload)
}

/// An application event frame with no reply ref.
pub fn unrefed_event_frame(
  join_ref: String,
  name: String,
  event: String,
  payload: json.Json,
) -> String {
  encode_frame(Some(join_ref), None, name, event, payload)
}

/// A client heartbeat on the reserved `phoenix` topic.
pub fn heartbeat_frame(ref: String) -> String {
  encode_frame(
    None,
    Some(ref),
    fixtures.heartbeat_topic,
    fixtures.heartbeat_event,
    json.object([]),
  )
}

/// A Phoenix V2 binary frame: `push` tag, then ref/topic/event lengths,
/// then the bytes.
pub fn binary_frame(
  join_ref: String,
  ref: String,
  name: String,
  event: String,
  data: BitArray,
) -> BitArray {
  <<
    0,
    bit_array.byte_size(<<join_ref:utf8>>),
    bit_array.byte_size(<<ref:utf8>>),
    bit_array.byte_size(<<name:utf8>>),
    bit_array.byte_size(<<event:utf8>>),
    join_ref:utf8,
    ref:utf8,
    name:utf8,
    event:utf8,
    data:bits,
  >>
}

fn encode_frame(
  join_ref: Option(String),
  ref: Option(String),
  name: String,
  event: String,
  payload: json.Json,
) -> String {
  json.to_string(
    json.preprocessed_array([
      optional_json(join_ref),
      optional_json(ref),
      json.string(name),
      json.string(event),
      payload,
    ]),
  )
}

fn optional_json(value: Option(String)) -> json.Json {
  case value {
    Some(inner) -> json.string(inner)
    None -> json.null()
  }
}

fn decode_frame(raw: String) -> Frame {
  let decoder = {
    use join_ref <- decode.subfield([0], decode.optional(decode.string))
    use ref <- decode.subfield([1], decode.optional(decode.string))
    use name <- decode.subfield([2], decode.string)
    use event <- decode.subfield([3], decode.string)
    use payload <- decode.subfield([4], decode.dynamic)
    decode.success(Frame(
      join_ref: join_ref,
      ref: ref,
      topic: name,
      event: event,
      payload: json.to_string(wire.dynamic_to_json(payload)),
    ))
  }

  let assert Ok(frame) = json.parse(from: raw, using: decoder)
    as "the server frame is valid phoenix wire format"
  frame
}

/// The `phx_reply` event name, from the shared Phoenix fixtures.
pub fn reply_event() -> String {
  fixtures.reply_event
}
