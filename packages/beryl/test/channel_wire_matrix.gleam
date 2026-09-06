//// One Phoenix wire-contract harness, run against two dispatch systems.
////
//// The point of this module is that there is exactly **one** copy of every
//// moving part a contract scenario needs — the public transport SPI, the
//// wire codec, the frame builders, the frame decoder — and exactly **two**
//// ways to build the system under test:
////
////   * `beryl.child_spec` with a hand-written `update`, and
////   * `channel.child_spec` with a handler table.
////
//// Both implement the same application contract (see "The contract app"
//// below), both are driven through `beryl/transport`, and both are
//// configured with the same `beryl.Config`.
//// [`compare`](#compare) runs one scenario body against both and fails if
//// the two systems are observably different, so no scenario has to be
//// written twice.
////
//// Nothing here imports a beryl internal module or re-implements the
//// runtime or codec. The same public SPI used by transport packages admits
//// sockets, routes decoded frames, and captures encoded outbound frames.

import beryl
import beryl/channel
import beryl/presence
import beryl/socket
import beryl/topic
import beryl/transport
import beryl/wire
import beryl/wire/codec
import gleam/bit_array
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleeunit/should
import phoenix_channel_fixtures/frame as fixtures

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
// ---------------------------------------------------------------------------

/// The hand-written `update` half of the matrix.
pub fn raw_update() -> fn(Nil, socket.Input(Nil)) -> socket.Next(Nil) {
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
    socket.Message(name, "shout", payload, _ref) -> {
      let assert Ok(shout_json) = wire.dynamic_to_json(payload)
      [socket.BroadcastFrom(name, shouted_event, shout_json)]
    }
    socket.Message(name, "track", _payload, _ref) -> [
      socket.PresenceTrack(name, presence_key, presence_meta()),
      socket.BroadcastPresence(name, presence_event, encode_presence),
    ]
    socket.Message(name, "blob", payload, _ref) -> [
      socket.Push(name, binary_event, binary_payload("decoded", payload)),
    ]
    socket.Message(..)
    | socket.Binary(..)
    | socket.Closed(..)
    | socket.Info(..) -> []
  }
}

fn raw_join(
  pattern: topic.TopicPattern,
  name: String,
  payload: dynamic.Dynamic,
  ref: socket.JoinRef,
) -> List(socket.Effect) {
  use <- guard_reject(topic.matches(pattern, name), ref, unmatched_payload())
  use <- guard_reject(!denied(payload), ref, denied_payload())
  [socket.AcceptJoin(ref, Some(join_reply(name)))]
}

fn guard_reject(
  allowed: Bool,
  ref: socket.JoinRef,
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
    channel.handler(room_pattern, fn(context) {
      case denied(context.payload) {
        True -> channel.reject(denied_payload())
        False ->
          contract_channel(Nil)
          |> channel.with_reply(join_reply(context.topic))
      }
    }),
  ]
}

fn contract_channel(state: Nil) -> channel.JoinResult(Nil, Nil) {
  channel.accept(state)
  |> channel.on_message(fn(state, message) {
    channel.next(state, message_actions(message))
  })
}

fn message_actions(
  message: channel.Message,
) -> List(channel.Action(channel.Active)) {
  case message.event {
    "ping" -> [channel.reply_ok(message.reply, pong_payload())]
    "boom" -> [channel.reply_error(message.reply, boom_payload())]
    "push_me" -> [channel.push(pushed_event, pushed_payload())]
    "shout" -> {
      let assert Ok(shout_json) = wire.dynamic_to_json(message.payload)
      [channel.broadcast_from(shouted_event, shout_json)]
    }
    "track" -> [
      channel.presence_track(presence_key, presence_meta()),
      channel.broadcast_presence(presence_event, encode_presence),
    ]
    "blob" -> [
      channel.push(binary_event, binary_payload("decoded", message.payload)),
    ]
    _ -> []
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

/// A started system driven through the public transport SPI.
pub type System {
  System(
    variant: String,
    sockets: beryl.Sockets,
    next_client_id: process.Subject(Int),
  )
}

/// The two systems every scenario is run against.
pub fn variants() -> List(Variant) {
  [
    Variant(name: "beryl.child_spec", start: fn(config) {
      let assert Ok(#(sockets, child_specification)) =
        beryl.child_spec(
          config,
          init: fn(_info: socket.ConnectInfo(Nil)) { #(Nil, []) },
          update: raw_update(),
        )
        as "the raw contract system builds"
      let assert Ok(_) =
        static_supervisor.new(static_supervisor.OneForOne)
        |> static_supervisor.add(child_specification)
        |> static_supervisor.start()
        as "the raw contract supervision tree starts"
      sockets
    }),
    Variant(name: "channel.child_spec", start: fn(config) {
      let assert Ok(#(sockets, child_specification)) =
        channel.child_spec(config, handlers: handlers())
        as "the channel contract system builds"
      let assert Ok(_) =
        static_supervisor.new(static_supervisor.OneForOne)
        |> static_supervisor.add(child_specification)
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
  setup setup: fn() -> #(beryl.Config, context),
  scenario scenario: fn(System, context) -> observation,
) -> observation {
  let observations =
    list.map(variants(), fn(variant) {
      let #(config, context) = setup()
      let sockets = variant.start(config)
      let next_client_id = process.new_subject()
      process.send(next_client_id, 0)
      let observed =
        scenario(System(variant.name, sockets, next_client_id), context)
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

// ---------------------------------------------------------------------------
// In-memory transport client
// ---------------------------------------------------------------------------

/// A socket admitted through the public transport SPI.
pub opaque type Client {
  Client(
    sockets: beryl.Sockets,
    socket_id: String,
    frames: process.Subject(String),
  )
}

/// Connect a client to a running system.
pub fn connect(system: System) -> Client {
  let assert Ok(client_id) = process.receive(system.next_client_id, 0)
    as "the client id counter is available"
  process.send(system.next_client_id, client_id + 1)
  let socket_id = system.variant <> "-" <> int.to_string(client_id)
  let frames = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(system.sockets)
  transport.admit_socket(
    sockets: system.sockets,
    owner: owner,
    socket_id: socket_id,
    send: fn(frame) {
      process.send(frames, frame)
      Ok(Nil)
    },
    send_binary: fn(_frame) { Ok(Nil) },
    codec: None,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
  |> should.equal(Ok(Nil))
  Client(sockets: system.sockets, socket_id: socket_id, frames: frames)
}

/// Send a raw text frame.
pub fn send(client: Client, raw: String) -> Nil {
  let assert Ok(decoded) =
    codec.decode_text(transport.active_codec(client.sockets))(raw)
    as "the text frame is valid"
  transport.route_decoded(client.sockets, client.socket_id, decoded)
}

/// Send a raw binary frame.
pub fn send_binary(client: Client, data: BitArray) -> Nil {
  transport.route_binary(client.sockets, client.socket_id, data)
}

/// Receive and decode the next server frame, failing if none arrives.
pub fn next(client: Client) -> Frame {
  let assert Ok(raw) = process.receive(client.frames, 500)
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
  process.receive(client.frames, 100) |> should.be_error
  Nil
}

/// Close a client connection.
pub fn close(client: Client) -> Nil {
  transport.socket_disconnected(client.sockets, client.socket_id)
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
    let assert Ok(payload_json) = wire.dynamic_to_json(payload)
    decode.success(Frame(
      join_ref: join_ref,
      ref: ref,
      topic: name,
      event: event,
      payload: json.to_string(payload_json),
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
