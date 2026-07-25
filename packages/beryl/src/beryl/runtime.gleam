//// Runtime actor for app-side dispatch systems started with `beryl.start`.
////
//// One runtime actor serves every socket started through
//// `beryl.start`. It is generic over the app's `model` and `msg`
//// types: per-socket models live in the actor state, typed `Info`
//// messages arrive through the actor's own mailbox, and no value is ever
//// type-erased. Transports reach the runtime through monomorphic closures
//// captured by `beryl.start`, so the frame-level transport SPI stays
//// unparameterized.
////
//// The runtime owns inbound decoding and validation, rate limiting,
//// heartbeat eviction, topic subscriptions, and broadcast fan-out. It
//// also interprets effects: each `update` returns a list of `Effect`s that
//// are applied strictly in order within a single actor turn, so effect
//// list order is wire order.

import beryl/internal
import beryl/log.{type Logger}
import beryl/presence
import beryl/presence/wire as presence_wire
import beryl/pubsub.{type PubSub}
import beryl/rate_limit.{type RateLimitConfig}
import beryl/socket.{
  type ConnectInfo, type ConnectSeed, type Effect, type Input, type Next,
  type Ref, type StopReason,
} as sock
import beryl/topic.{type TopicPattern}
import beryl/wire/codec.{type Codec}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// Configuration for the runtime actor. Built by `beryl.start` from a
/// `beryl.Config`; the fields cover per-topic-pattern rate limits and the
/// optional presence handle used by the presence effects.
pub type Config {
  Config(
    codec: Codec,
    heartbeat_check_interval_ms: Int,
    heartbeat_timeout_ms: Int,
    message_limits: Option(RateLimitConfig),
    join_limits: Option(RateLimitConfig),
    channel_limits: Option(RateLimitConfig),
    channel_limiter_max_keys_per_socket: Int,
    /// Per-topic-pattern message rate limits. The first matching pattern
    /// wins; topics matching no pattern fall back to `channel_limits`.
    topic_rates: List(#(TopicPattern, RateLimitConfig)),
    max_topic_length: Int,
    max_event_length: Int,
    max_joined_topics_per_socket: Int,
    logging: internal.LoggingConfig,
    /// Presence handle used by `PresenceTrack`/`PresenceUntrack` effects.
    presence: Option(presence.Presence),
  )
}

/// Errors when starting the runtime.
pub type StartError {
  InvalidHeartbeatTimeout
  ActorStartFailed(actor.StartError)
}

/// Messages the runtime actor handles.
pub type Msg(msg) {
  SocketConnected(
    socket_id: String,
    send: fn(String) -> Result(Nil, Nil),
    send_binary: fn(BitArray) -> Result(Nil, Nil),
    seed: ConnectSeed,
  )
  SocketDisconnected(socket_id: String)
  RegisterCloser(socket_id: String, close: fn() -> Nil)
  RouteDecoded(socket_id: String, msg: codec.Inbound)
  HandleBinary(socket_id: String, data: BitArray)
  /// A typed server-side message for one socket, sent through its
  /// `Sender`. Delivered to `update` as `Info(message)`.
  AppInfo(socket_id: String, message: msg)
  /// Local broadcast fan-out. PubSub forwarding is the sender's concern
  /// (the `beryl` broadcast helpers and the effect interpreter forward
  /// before/while sending this).
  Broadcast(topic: String, event: String, payload: Json, except: Option(String))
  RemoteBroadcast(pubsub.Message(Json))
  CheckHeartbeats
  Stop(reply: Subject(Nil))
}

/// Erlang monotonic time in milliseconds
@external(erlang, "beryl_ffi", "monotonic_time_ms")
fn monotonic_time_ms() -> Int

type State(model, msg) {
  State(
    sockets: Dict(String, SocketState(model, msg)),
    /// Topic -> set of subscribed socket ids.
    topics: Dict(String, Set(String)),
    config: Config,
    pubsub: Option(PubSub(Json)),
    /// Typed PubSub subscription owned by this runtime actor, present
    /// whenever `pubsub` is. Joins/leaves topics and folds broadcast
    /// delivery into the actor's selector.
    subscriber: Option(pubsub.Subscriber(Json)),
    logger: Logger,
    self_subject: Subject(Msg(msg)),
    init: fn(ConnectInfo(msg)) -> #(model, List(Effect)),
    update: fn(model, Input(msg)) -> Next(model, msg),
    message_buckets: Dict(String, rate_limit.Bucket),
    join_buckets: Dict(String, rate_limit.Bucket),
    channel_buckets: Dict(String, Dict(String, rate_limit.Bucket)),
  )
}

type SocketState(model, msg) {
  SocketState(
    id: String,
    send: fn(String) -> Result(Nil, Nil),
    send_binary: fn(BitArray) -> Result(Nil, Nil),
    close: fn() -> Nil,
    /// The app's per-socket model, threaded through `update`.
    model: model,
    /// Per-topic join_ref from the accepted join, echoed in replies and
    /// terminal frames and used to drop stale-instance messages. The key
    /// set is the socket's joined topics.
    join_refs: Dict(String, Option(String)),
    /// Presence refs tracked via `PresenceTrack`:
    /// topic -> key -> #(ref, meta). Auto-untracked when the topic closes.
    presence_refs: Dict(String, Dict(String, #(String, Json))),
    /// Message reply refs still awaiting a reply. A ref is added when its
    /// `Message` is delivered, removed when answered (so a reply is
    /// single-use), and pruned when its topic closes (so a stale ref stored
    /// across a leave/rejoin is not replied to).
    pending_reply_refs: Set(Ref),
    last_heartbeat: Int,
  )
}

/// A join delivered to `update` that has not been answered yet.
type Pending {
  Pending(topic: String, join_ref: Option(String), msg_ref: Option(String))
}

/// Where an event delivered to `update` came from, for crash attribution.
type Source {
  JoinSource(pending: Pending)
  MessageSource(topic: String)
  BinarySource(topic: String)
  InfoSource
  ClosedSource
}

/// The result of delivering one event (or closing one topic): the next
/// state plus kick/stop follow-ups to be driven by `drive`.
type Outcome(model, msg) {
  Outcome(
    state: State(model, msg),
    kicks: List(String),
    stop: Option(StopReason),
  )
}

/// Start the runtime actor registered under `name`.
///
/// There is deliberately no unsupervised start: `beryl.start` runs
/// the runtime under a supervisor, and a crash restarts it with dispatch
/// intact because the `init`/`update` closures live in the child
/// specification. The registered name keeps transport and broadcast
/// handles valid across restarts (per-socket state is dropped on restart).
pub fn start_named(
  config: Config,
  name name: process.Name(Msg(msg)),
  pubsub ps: Option(PubSub(Json)),
  init init: fn(ConnectInfo(msg)) -> #(model, List(Effect)),
  update update: fn(model, Input(msg)) -> Next(model, msg),
) -> Result(actor.Started(Subject(Msg(msg))), StartError) {
  use <- bool.guard(
    when: config.heartbeat_check_interval_ms > 0
      && config.heartbeat_timeout_ms <= 0,
    return: Error(InvalidHeartbeatTimeout),
  )
  internal.configure(config.logging)

  actor.new_with_initialiser(5000, fn(subject) {
    let base =
      State(
        sockets: dict.new(),
        topics: dict.new(),
        config: config,
        pubsub: ps,
        subscriber: None,
        logger: internal.logger_with_config("beryl.runtime", config.logging),
        self_subject: subject,
        init: init,
        update: update,
        message_buckets: dict.new(),
        join_buckets: dict.new(),
        channel_buckets: dict.new(),
      )
    schedule_heartbeat_check(subject, config)
    case ps {
      Some(pubsub_instance) -> {
        let sub = pubsub.subscriber(pubsub_instance)
        let state = State(..base, subscriber: Some(sub))
        let selector =
          process.new_selector()
          |> process.select(subject)
          |> pubsub.selecting(sub, RemoteBroadcast)
        actor.initialised(state)
        |> actor.returning(subject)
        |> actor.selecting(selector)
        |> Ok
      }
      None ->
        actor.initialised(base)
        |> actor.returning(subject)
        |> Ok
    }
  })
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
  |> result.map_error(ActorStartFailed)
}

fn schedule_heartbeat_check(subject: Subject(Msg(msg)), config: Config) -> Nil {
  use <- bool.guard(when: config.heartbeat_check_interval_ms <= 0, return: Nil)
  let _timer =
    process.send_after(
      subject,
      config.heartbeat_check_interval_ms,
      CheckHeartbeats,
    )
  Nil
}

fn handle_message(
  state: State(model, msg),
  message: Msg(msg),
) -> actor.Next(State(model, msg), Msg(msg)) {
  case message {
    SocketConnected(socket_id, send, send_binary, seed) ->
      handle_socket_connected(state, socket_id, send, send_binary, seed)
    SocketDisconnected(socket_id) ->
      handle_socket_disconnected(state, socket_id)
    RegisterCloser(socket_id, close) ->
      handle_register_closer(state, socket_id, close)
    RouteDecoded(socket_id, msg) -> dispatch_inbound(state, socket_id, msg)
    HandleBinary(socket_id, data) -> handle_binary_in(state, socket_id, data)
    AppInfo(socket_id, app_message) ->
      handle_app_info(state, socket_id, app_message)
    Broadcast(topic_name, event_name, payload, except) -> {
      local_broadcast(state, topic_name, event_name, payload, except)
      actor.continue(state)
    }
    RemoteBroadcast(pubsub_msg) ->
      // Delivered through the typed subscriber subject, but the payload's
      // own shape is a frozen wire contract across nodes; a malformed frame
      // from a mismatched peer must not crash the runtime.
      case
        internal.rescue(fn() { handle_remote_broadcast(state, pubsub_msg) })
      {
        Ok(next) -> next
        Error(crash) -> {
          state.logger
          |> log.error("Remote broadcast dropped: malformed message", [
            #("crash", crash),
          ])
          actor.continue(state)
        }
      }
    CheckHeartbeats -> handle_check_heartbeats(state)
    Stop(reply) -> handle_stop(state, reply)
  }
}

// ── Socket lifecycle ────────────────────────────────────────────────────────

fn handle_socket_connected(
  state: State(model, msg),
  socket_id: String,
  send: fn(String) -> Result(Nil, Nil),
  send_binary: fn(BitArray) -> Result(Nil, Nil),
  seed: ConnectSeed,
) -> actor.Next(State(model, msg), Msg(msg)) {
  let sender = make_socket_sender(state, socket_id)
  let info = sock.ConnectInfo(socket_id: socket_id, seed: seed, self: sender)
  let init = state.init
  case internal.rescue(fn() { init(info) }) {
    Error(crash) -> {
      state.logger
      |> log.error("Socket init crashed; socket not registered", [
        #("socket_id", socket_id),
        #("crash", crash),
      ])
      actor.continue(state)
    }
    Ok(#(model, effects)) -> {
      let socket =
        SocketState(
          id: socket_id,
          send: send,
          send_binary: send_binary,
          close: fn() { Nil },
          model: model,
          join_refs: dict.new(),
          presence_refs: dict.new(),
          pending_reply_refs: set.new(),
          last_heartbeat: monotonic_time_ms(),
        )
      state.logger |> log.info("Socket connected", [#("socket_id", socket_id)])
      let state =
        State(..state, sockets: dict.insert(state.sockets, socket_id, socket))
      // Nothing is joined yet, so kicks cannot arise and pushes to
      // unjoined topics are dropped by the interpreter.
      let #(state, _pending, _kicks) =
        apply_effects(state, socket_id, effects, None)
      actor.continue(state)
    }
  }
}

/// Build the typed `Sender` for a socket. The closure sends through the
/// runtime's own mailbox — an ordinary typed send, usable from any process.
fn make_socket_sender(
  state: State(model, msg),
  socket_id: String,
) -> sock.Sender(msg) {
  let subject = state.self_subject
  sock.make_sender(fn(message) {
    process.send(subject, AppInfo(socket_id, message))
  })
}

fn handle_register_closer(
  state: State(model, msg),
  socket_id: String,
  close: fn() -> Nil,
) -> actor.Next(State(model, msg), Msg(msg)) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> actor.continue(state)
    Ok(socket) ->
      actor.continue(store_socket(state, SocketState(..socket, close: close)))
  }
}

fn handle_socket_disconnected(
  state: State(model, msg),
  socket_id: String,
) -> actor.Next(State(model, msg), Msg(msg)) {
  let metadata = case dict.get(state.sockets, socket_id) {
    Ok(socket) ->
      list.append([#("socket_id", socket_id)], joined_topics_metadata(socket))
    Error(Nil) -> [#("socket_id", socket_id)]
  }
  state.logger |> log.info("Socket disconnected", metadata)
  actor.continue(teardown_socket(state, socket_id, sock.Normal))
}

fn handle_stop(
  state: State(model, msg),
  reply: Subject(Nil),
) -> actor.Next(State(model, msg), Msg(msg)) {
  state.logger
  |> log.info("Runtime stopping", [
    #("socket_count", int.to_string(dict.size(state.sockets))),
  ])
  dict.keys(state.sockets)
  |> list.fold(state, fn(st, socket_id) {
    teardown_socket(st, socket_id, sock.Shutdown)
  })
  process.send(reply, Nil)
  actor.stop()
}

// ── Heartbeats ──────────────────────────────────────────────────────────────

fn handle_heartbeat(
  state: State(model, msg),
  socket_id: String,
  ref: Option(String),
) -> actor.Next(State(model, msg), Msg(msg)) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> actor.continue(state)
    Ok(socket) -> {
      let state =
        store_socket(
          state,
          SocketState(..socket, last_heartbeat: monotonic_time_ms()),
        )
      let reply = codec.encode_heartbeat_reply(state.config.codec)(ref)
      let _send_result =
        send_frame_logged(state, socket, "__heartbeat__", reply)
      state.logger
      |> log.debug("Heartbeat handled", [
        #("socket_id", socket_id),
        #("ref", optional_string(ref)),
      ])
      actor.continue(state)
    }
  }
}

fn handle_check_heartbeats(
  state: State(model, msg),
) -> actor.Next(State(model, msg), Msg(msg)) {
  let now = monotonic_time_ms()
  let timeout_ms = state.config.heartbeat_timeout_ms
  let stale_socket_ids =
    dict.fold(state.sockets, [], fn(acc, socket_id, socket) {
      case now - socket.last_heartbeat > timeout_ms {
        True -> [socket_id, ..acc]
        False -> acc
      }
    })
  list.each(stale_socket_ids, fn(socket_id) {
    state.logger
    |> log.warn("Evicting socket due to heartbeat timeout", [
      #("socket_id", socket_id),
      #("timeout_ms", int.to_string(timeout_ms)),
    ])
  })
  let state =
    list.fold(stale_socket_ids, state, fn(st, socket_id) {
      teardown_socket(st, socket_id, sock.HeartbeatTimeout)
    })
  schedule_heartbeat_check(state.self_subject, state.config)
  actor.continue(state)
}

// ── Inbound decoding and dispatch ───────────────────────────────────────────

fn dispatch_inbound(
  state: State(model, msg),
  socket_id: String,
  msg: codec.Inbound,
) -> actor.Next(State(model, msg), Msg(msg)) {
  let msg_topic = codec.inbound_topic(msg)
  let msg_ref = codec.inbound_ref(msg)
  case codec.inbound_kind(msg) {
    codec.Join ->
      case
        is_valid_topic(msg_topic, state.config) && !is_reserved_topic(msg_topic)
      {
        True ->
          handle_join(
            state,
            socket_id,
            msg_topic,
            codec.inbound_payload(msg),
            codec.inbound_join_ref(msg),
            msg_ref,
          )
        False -> reject_invalid_join(state, socket_id, msg)
      }
    codec.Leave -> {
      use state <- with_message_rate_limit(state, socket_id, [
        #("kind", "leave"),
      ])
      case is_valid_topic(msg_topic, state.config) {
        False -> {
          state.logger
          |> log.warn("Leave dropped: invalid topic", [
            #("socket_id", socket_id),
            #("topic", topic.sanitize_for_log(msg_topic)),
          ])
          actor.continue(state)
        }
        True ->
          handle_leave(
            state,
            socket_id,
            msg_topic,
            codec.inbound_join_ref(msg),
            msg_ref,
          )
      }
    }
    codec.Heartbeat -> {
      use state <- with_message_rate_limit(state, socket_id, [
        #("kind", "heartbeat"),
      ])
      handle_heartbeat(state, socket_id, msg_ref)
    }
    codec.Event(event_name) -> {
      let resolved = resolve_event_topic(state, socket_id, msg_topic)
      case
        is_valid_topic(resolved, state.config),
        is_valid_event(event_name, state.config)
      {
        True, True ->
          handle_in(
            state,
            socket_id,
            resolved,
            event_name,
            codec.inbound_payload(msg),
            codec.inbound_join_ref(msg),
            msg_ref,
          )
        False, _ -> {
          state.logger
          |> log.warn("Event dropped: invalid topic", [
            #("socket_id", socket_id),
            #("topic", topic.sanitize_for_log(msg_topic)),
            #("event", topic.sanitize_for_log(event_name)),
          ])
          actor.continue(state)
        }
        True, False -> {
          state.logger
          |> log.warn("Event dropped: invalid event", [
            #("socket_id", socket_id),
            #("topic", msg_topic),
            #("event", topic.sanitize_for_log(event_name)),
          ])
          actor.continue(state)
        }
      }
    }
  }
}

/// Resolve the topic for an inbound Event when the codec opted into
/// topicless events (see `codec.with_topicless_events`).
fn resolve_event_topic(
  state: State(model, msg),
  socket_id: String,
  requested: String,
) -> String {
  case requested {
    "" ->
      case dict.get(state.sockets, socket_id) {
        Ok(socket) ->
          case
            codec.topicless_events(state.config.codec),
            dict.keys(socket.join_refs)
          {
            True, [only] -> only
            _, _ -> requested
          }
        Error(Nil) -> requested
      }
    _ -> requested
  }
}

fn is_valid_topic(topic_name: String, config: Config) -> Bool {
  string.byte_size(topic_name) <= config.max_topic_length
  && result.is_ok(topic.validate(topic_name))
}

/// Topics under the `beryl:` prefix are reserved for internal machinery.
fn is_reserved_topic(topic_name: String) -> Bool {
  string.starts_with(topic_name, "beryl:")
}

/// Event names under the `phx_` prefix are reserved by the protocol.
fn is_valid_event(event_name: String, config: Config) -> Bool {
  string.byte_size(event_name) <= config.max_event_length
  && !string.starts_with(event_name, "phx_")
  && result.is_ok(topic.validate_event(event_name))
}

/// Apply the per-socket message limiter, dropping the frame with a warning
/// when the socket is over rate. `metadata` is appended to the warning's
/// `socket_id` entry.
fn with_message_rate_limit(
  state: State(model, msg),
  socket_id: String,
  metadata: List(#(String, String)),
  next: fn(State(model, msg)) -> actor.Next(State(model, msg), Msg(msg)),
) -> actor.Next(State(model, msg), Msg(msg)) {
  let #(state, allowed) = check_message_rate(state, socket_id)
  case allowed {
    False -> {
      state.logger
      |> log.warn("Message rate limited", [
        #("socket_id", socket_id),
        ..metadata
      ])
      actor.continue(state)
    }
    True -> next(state)
  }
}

fn reject_invalid_join(
  state: State(model, msg),
  socket_id: String,
  msg: codec.Inbound,
) -> actor.Next(State(model, msg), Msg(msg)) {
  let safe_topic = topic.sanitize_for_log(codec.inbound_topic(msg))
  state.logger
  |> log.warn("Join rejected: invalid topic", [
    #("socket_id", socket_id),
    #("topic", safe_topic),
  ])
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> actor.continue(state)
    Ok(socket) -> {
      let reply =
        codec.encode_reply(state.config.codec)(
          codec.inbound_join_ref(msg),
          codec.inbound_ref(msg),
          codec.inbound_topic(msg),
          codec.StatusError,
          json.object([#("reason", json.string("invalid_topic"))]),
        )
      let _send_result = send_frame_logged(state, socket, safe_topic, reply)
      actor.continue(state)
    }
  }
}

// ── Joins ───────────────────────────────────────────────────────────────────

fn handle_join(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
) -> actor.Next(State(model, msg), Msg(msg)) {
  let #(state, join_allowed) = check_join_rate(state, socket_id)
  case join_allowed {
    False -> {
      state.logger
      |> log.warn("Join rate limited", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      send_error_reply(
        state,
        socket_id,
        topic_name,
        join_ref,
        ref,
        json.object([#("reason", json.string("rate_limited"))]),
      )
      actor.continue(state)
    }
    True ->
      handle_join_inner(state, socket_id, topic_name, payload, join_ref, ref)
  }
}

fn handle_join_inner(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
) -> actor.Next(State(model, msg), Msg(msg)) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      state.logger
      |> log.debug("Join ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("reason", "socket_not_found"),
      ])
      actor.continue(state)
    }
    Ok(socket) ->
      case can_join_topic(socket, topic_name, state.config) {
        False -> {
          state.logger
          |> log.warn("Join rejected: topic cap exceeded", [
            #("socket_id", socket_id),
            #("topic", topic_name),
          ])
          send_error_reply(
            state,
            socket_id,
            topic_name,
            join_ref,
            ref,
            json.object([#("reason", json.string("too_many_topics"))]),
          )
          actor.continue(state)
        }
        True -> {
          // Phoenix duplicate-join semantics: a join for an already-joined
          // topic replaces the previous instance. Close it first (the app
          // receives `Closed(topic, Normal)`) so cleanup keyed off closing
          // is never silently skipped by a rejoin.
          let state = case dict.has_key(socket.join_refs, topic_name) {
            True ->
              drive(
                close_topic(state, socket_id, topic_name, sock.Normal),
                socket_id,
              )
            False -> state
          }
          deliver_join(state, socket_id, topic_name, payload, join_ref, ref)
        }
      }
  }
}

fn deliver_join(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
) -> actor.Next(State(model, msg), Msg(msg)) {
  // The Closed delivered for a duplicate join may have stopped the socket.
  use <- bool.guard(
    when: !dict.has_key(state.sockets, socket_id),
    return: actor.continue(state),
  )
  state.logger
  |> log.debug("Join delivered", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("ref", optional_string(ref)),
    #("join_ref", optional_string(join_ref)),
  ])
  let join_event =
    sock.Join(
      topic: topic_name,
      payload: payload,
      ref: sock.make_join_ref(
        topic: topic_name,
        join_ref: join_ref,
        msg_ref: ref,
      ),
    )
  let outcome =
    update_once(
      state,
      socket_id,
      join_event,
      JoinSource(Pending(topic_name, join_ref, ref)),
    )
  actor.continue(drive(outcome, socket_id))
}

fn can_join_topic(
  socket: SocketState(model, msg),
  topic_name: String,
  config: Config,
) -> Bool {
  config.max_joined_topics_per_socket <= 0
  || dict.has_key(socket.join_refs, topic_name)
  || dict.size(socket.join_refs) < config.max_joined_topics_per_socket
}

// ── Leaves ──────────────────────────────────────────────────────────────────

fn handle_leave(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  msg_join_ref: Option(String),
  ref: Option(String),
) -> actor.Next(State(model, msg), Msg(msg)) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> actor.continue(state)
    Ok(socket) -> {
      use <- bool.lazy_guard(
        when: is_stale_join_ref(socket, topic_name, msg_join_ref),
        return: fn() {
          state.logger
          |> log.debug("Leave dropped: stale join_ref", [
            #("socket_id", socket_id),
            #("topic", topic_name),
          ])
          actor.continue(state)
        },
      )

      // Acknowledge the leave before closing, so the client sees the reply
      // to its own ref first and the terminal frame second — matching
      // Phoenix.
      case ref {
        Some(r) -> {
          let reply =
            codec.encode_reply(state.config.codec)(
              joined_ref(socket, topic_name),
              Some(r),
              topic_name,
              codec.StatusOk,
              json.object([]),
            )
          let _send_result = send_frame_logged(state, socket, topic_name, reply)
          Nil
        }
        None -> Nil
      }

      actor.continue(drive(
        close_topic(state, socket_id, topic_name, sock.Normal),
        socket_id,
      ))
    }
  }
}

/// A message is stale when it carries a join_ref from a previous channel
/// instance on this topic (the client rejoined since sending it).
fn is_stale_join_ref(
  socket: SocketState(model, msg),
  topic_name: String,
  msg_join_ref: Option(String),
) -> Bool {
  case msg_join_ref, joined_ref(socket, topic_name) {
    Some(sent), Some(current) -> sent != current
    _, _ -> False
  }
}

fn joined_ref(
  socket: SocketState(model, msg),
  topic_name: String,
) -> Option(String) {
  dict.get(socket.join_refs, topic_name)
  |> result.unwrap(None)
}

// ── Client messages ─────────────────────────────────────────────────────────

fn handle_in(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  msg_join_ref: Option(String),
  ref: Option(String),
) -> actor.Next(State(model, msg), Msg(msg)) {
  use state <- with_message_rate_limit(state, socket_id, [
    #("topic", topic_name),
  ])
  handle_in_subscribed(
    state,
    socket_id,
    topic_name,
    event_name,
    payload,
    msg_join_ref,
    ref,
  )
}

fn handle_in_subscribed(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  msg_join_ref: Option(String),
  ref: Option(String),
) -> actor.Next(State(model, msg), Msg(msg)) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      state.logger
      |> log.debug("Inbound message ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event_name),
        #("reason", "socket_not_found"),
      ])
      actor.continue(state)
    }
    Ok(socket) ->
      case dict.has_key(socket.join_refs, topic_name) {
        False ->
          reject_unjoined_event(
            state,
            socket,
            socket_id,
            topic_name,
            event_name,
            ref,
          )
        True ->
          case is_stale_join_ref(socket, topic_name, msg_join_ref) {
            True -> {
              state.logger
              |> log.debug("Inbound message dropped: stale join_ref", [
                #("socket_id", socket_id),
                #("topic", topic_name),
                #("event", event_name),
              ])
              actor.continue(state)
            }
            False ->
              handle_in_rate_limited(
                state,
                socket,
                socket_id,
                topic_name,
                event_name,
                payload,
                ref,
              )
          }
      }
  }
}

/// Reject an event pushed to a topic the socket has not joined, replying
/// with Phoenix's `unmatched topic` error when a ref is present.
fn reject_unjoined_event(
  state: State(model, msg),
  socket: SocketState(model, msg),
  socket_id: String,
  topic_name: String,
  event_name: String,
  ref: Option(String),
) -> actor.Next(State(model, msg), Msg(msg)) {
  state.logger
  |> log.debug("Inbound message rejected", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("event", event_name),
    #("reason", "topic_not_joined"),
  ])
  case ref {
    Some(r) -> {
      let reply =
        codec.encode_reply(state.config.codec)(
          None,
          Some(r),
          topic_name,
          codec.StatusError,
          json.object([#("reason", json.string("unmatched topic"))]),
        )
      let _send_result = send_frame_logged(state, socket, topic_name, reply)
      Nil
    }
    None -> Nil
  }
  actor.continue(state)
}

fn handle_in_rate_limited(
  state: State(model, msg),
  socket: SocketState(model, msg),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  ref: Option(String),
) -> actor.Next(State(model, msg), Msg(msg)) {
  let #(state, allowed) = check_channel_rate(state, socket_id, topic_name)
  case allowed {
    False -> {
      state.logger
      |> log.warn("Channel rate limited", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      actor.continue(state)
    }
    True -> {
      state.logger
      |> log.debug("Inbound message routed", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event_name),
        #("ref", optional_string(ref)),
      ])
      let message_ref =
        option.map(ref, fn(r) {
          sock.make_message_ref(
            topic: topic_name,
            join_ref: joined_ref(socket, topic_name),
            msg_ref: Some(r),
          )
        })
      // Track the reply ref as outstanding so `apply_reply` can enforce
      // single-use and drop replies to refs whose topic later closes.
      let state = case message_ref {
        Some(r) -> register_reply_ref(state, socket_id, r)
        None -> state
      }
      let outcome =
        update_once(
          state,
          socket_id,
          sock.Message(
            topic: topic_name,
            event: event_name,
            payload: payload,
            ref: message_ref,
          ),
          MessageSource(topic_name),
        )
      actor.continue(drive(outcome, socket_id))
    }
  }
}

// ── Binary frames ───────────────────────────────────────────────────────────

fn handle_binary_in(
  state: State(model, msg),
  socket_id: String,
  data: BitArray,
) -> actor.Next(State(model, msg), Msg(msg)) {
  case codec.decode_binary(state.config.codec) {
    Some(decode_binary) ->
      case decode_binary(data) {
        Error(err) -> {
          state.logger
          |> log.warn("Failed to decode binary wire protocol message", [
            #("socket_id", socket_id),
            #("error", codec.format_decode_error(err)),
          ])
          actor.continue(state)
        }
        Ok(msg) -> dispatch_inbound(state, socket_id, msg)
      }
    None -> handle_undecoded_binary_in(state, socket_id, data)
  }
}

/// Deliver a binary frame the codec cannot decode: rate-limit it per socket,
/// then hand the raw bytes to every topic the socket has joined.
fn handle_undecoded_binary_in(
  state: State(model, msg),
  socket_id: String,
  data: BitArray,
) -> actor.Next(State(model, msg), Msg(msg)) {
  let #(state, allowed) = check_message_rate(state, socket_id)
  case allowed, dict.get(state.sockets, socket_id) {
    False, _ -> {
      state.logger
      |> log.warn("Binary message rate limited", [#("socket_id", socket_id)])
      actor.continue(state)
    }
    True, Error(Nil) -> {
      state.logger
      |> log.debug("Binary message ignored", [
        #("socket_id", socket_id),
        #("reason", "socket_not_found"),
      ])
      actor.continue(state)
    }
    True, Ok(socket) -> {
      // Fan the raw frame out to every joined topic, in sorted order for
      // determinism.
      let topics =
        dict.keys(socket.join_refs)
        |> list.sort(string.compare)
      actor.continue(fan_out_binary(state, socket_id, topics, data))
    }
  }
}

fn fan_out_binary(
  state: State(model, msg),
  socket_id: String,
  topics: List(String),
  data: BitArray,
) -> State(model, msg) {
  case topics {
    [] -> state
    [topic_name, ..rest] -> {
      // Re-check per topic: an earlier delivery may have closed it or
      // stopped the socket.
      let state = case socket_subscribed(state, socket_id, topic_name) {
        False -> state
        True ->
          drive(
            update_once(
              state,
              socket_id,
              sock.Binary(topic: topic_name, data: data),
              BinarySource(topic_name),
            ),
            socket_id,
          )
      }
      fan_out_binary(state, socket_id, rest, data)
    }
  }
}

// ── Server-side info ────────────────────────────────────────────────────────

fn handle_app_info(
  state: State(model, msg),
  socket_id: String,
  message: msg,
) -> actor.Next(State(model, msg), Msg(msg)) {
  case dict.has_key(state.sockets, socket_id) {
    False -> {
      state.logger
      |> log.debug("Info dropped", [
        #("socket_id", socket_id),
        #("reason", "socket_not_found"),
      ])
      actor.continue(state)
    }
    True ->
      actor.continue(drive(
        update_once(state, socket_id, sock.Info(message), InfoSource),
        socket_id,
      ))
  }
}

// ── The update engine ───────────────────────────────────────────────────────

/// Deliver one event to the app's `update`, store the new model, and apply
/// the returned effects. Kick and stop follow-ups are returned in the
/// `Outcome` for `drive` to process — they are never applied mid-fold.
fn update_once(
  state: State(model, msg),
  socket_id: String,
  ev: Input(msg),
  source: Source,
) -> Outcome(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Outcome(state, [], None)
    Ok(socket) -> {
      let update = state.update
      let model = socket.model
      case internal.rescue(fn() { update(model, ev) }) {
        Error(crash) -> handle_update_crash(state, socket_id, source, crash)
        Ok(sock.Stop(reason)) -> {
          state.logger
          |> log.debug("Update stopped socket", [
            #("socket_id", socket_id),
            #("reason", stop_reason_string(reason)),
          ])
          // A join answered with Stop is still unanswered on the wire:
          // fail it closed before the teardown frames.
          reject_unanswered_join(state, socket_id, source)
          Outcome(state, [], Some(reason))
        }
        Ok(sock.Next(new_model, effects)) ->
          apply_update_next(state, socket_id, source, new_model, effects)
      }
    }
  }
}

/// Store the model an update returned and apply its effects. A join whose
/// effects never answered the wire is rejected here, so no join is left
/// unanswered.
fn apply_update_next(
  state: State(model, msg),
  socket_id: String,
  source: Source,
  new_model: model,
  effects: List(Effect),
) -> Outcome(model, msg) {
  let state = store_model(state, socket_id, new_model)
  let pending = case source {
    JoinSource(p) -> Some(p)
    _ -> None
  }
  let #(state, pending, kicks) =
    apply_effects(state, socket_id, effects, pending)
  case pending {
    Some(p) -> {
      state.logger
      |> log.warn("Join not acknowledged by update; rejecting", [
        #("socket_id", socket_id),
        #("topic", p.topic),
      ])
      send_error_reply(
        state,
        socket_id,
        p.topic,
        p.join_ref,
        p.msg_ref,
        json.object([#("reason", json.string("join not acknowledged"))]),
      )
    }
    None -> Nil
  }
  Outcome(state, kicks, None)
}

/// Crash policy: joins are rejected and the socket survives; topic-scoped
/// events close just that topic; `Info` (no topic to attribute) tears down
/// the socket; a crash while handling `Closed` is logged and teardown
/// continues with the last good model.
fn handle_update_crash(
  state: State(model, msg),
  socket_id: String,
  source: Source,
  crash: String,
) -> Outcome(model, msg) {
  case source {
    JoinSource(p) -> {
      state.logger
      |> log.error("Update crashed handling join", [
        #("socket_id", socket_id),
        #("topic", p.topic),
        #("crash", crash),
      ])
      send_error_reply(
        state,
        socket_id,
        p.topic,
        p.join_ref,
        p.msg_ref,
        json.object([#("reason", json.string("join crashed"))]),
      )
      Outcome(state, [], None)
    }
    MessageSource(topic_name) | BinarySource(topic_name) -> {
      state.logger
      |> log.error("Update crashed; closing topic", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("crash", crash),
      ])
      close_topic(state, socket_id, topic_name, sock.Errored(crash))
    }
    InfoSource -> {
      state.logger
      |> log.error("Update crashed handling info; closing socket", [
        #("socket_id", socket_id),
        #("crash", crash),
      ])
      Outcome(teardown_socket(state, socket_id, sock.Errored(crash)), [], None)
    }
    ClosedSource -> {
      state.logger
      |> log.error("Update crashed handling closed", [
        #("socket_id", socket_id),
        #("crash", crash),
      ])
      Outcome(state, [], None)
    }
  }
}

/// Fail-closed reply for a join the update never answered (used for both
/// the missing-`AcceptJoin` case and `Stop` returned from a join).
fn reject_unanswered_join(
  state: State(model, msg),
  socket_id: String,
  source: Source,
) -> Nil {
  case source {
    JoinSource(p) ->
      send_error_reply(
        state,
        socket_id,
        p.topic,
        p.join_ref,
        p.msg_ref,
        json.object([#("reason", json.string("join not acknowledged"))]),
      )
    _ -> Nil
  }
}

/// Process an outcome's follow-ups: tear the socket down if an update
/// returned `Stop`, otherwise close kicked topics one at a time (each
/// `Closed` delivery may add further kicks). Terminates because every kick
/// closes a joined topic and closed topics cannot be re-kicked.
fn drive(outcome: Outcome(model, msg), socket_id: String) -> State(model, msg) {
  case outcome.stop {
    Some(reason) -> teardown_socket(outcome.state, socket_id, reason)
    None ->
      case outcome.kicks {
        [] -> outcome.state
        [topic_name, ..rest] ->
          drive(
            close_kicked_topic(outcome.state, socket_id, topic_name, rest),
            socket_id,
          )
      }
  }
}

/// Close the first kicked topic and append the kicks its `Closed` delivery
/// produced to the remaining queue. A topic that is no longer joined is
/// dropped from the queue without a close.
fn close_kicked_topic(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  rest: List(String),
) -> Outcome(model, msg) {
  use <- bool.guard(
    when: !socket_subscribed(state, socket_id, topic_name),
    return: Outcome(state, rest, None),
  )
  let closed = close_topic(state, socket_id, topic_name, sock.Shutdown)
  Outcome(closed.state, list.append(rest, closed.kicks), closed.stop)
}

/// Close one topic subscription: remove the subscription state, deliver
/// `Closed` to the app, auto-untrack leftover presence, and send the
/// terminal frame. Subscription state is removed *before* the `Closed`
/// delivery, so pushes to the closing topic drop while broadcasts still
/// reach the topic's remaining subscribers.
fn close_topic(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  reason: StopReason,
) -> Outcome(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Outcome(state, [], None)
    Ok(socket) ->
      case dict.has_key(socket.join_refs, topic_name) {
        False -> Outcome(state, [], None)
        True -> {
          state.logger
          |> log.debug("Topic closed", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("reason", stop_reason_string(reason)),
          ])
          let close_join_ref = joined_ref(socket, topic_name)
          let socket =
            SocketState(
              ..socket,
              join_refs: dict.delete(socket.join_refs, topic_name),
              pending_reply_refs: set.filter(socket.pending_reply_refs, fn(ref) {
                sock.ref_topic(ref) != topic_name
              }),
            )
          let state = store_socket(state, socket)
          let state = remove_channel_bucket(state, socket_id, topic_name)
          let state = remove_topic_subscriber(state, socket_id, topic_name)

          let out =
            update_once(
              state,
              socket_id,
              sock.Closed(topic: topic_name, reason: reason),
              ClosedSource,
            )
          let state = untrack_topic_presence(out.state, socket_id, topic_name)
          send_terminal_frame(
            state,
            socket_id,
            topic_name,
            close_join_ref,
            reason,
          )
          Outcome(state, out.kicks, out.stop)
        }
      }
  }
}

/// Remove a socket from a topic's subscriber set, unsubscribing from
/// PubSub and dropping the topic entry when it was the last subscriber.
fn remove_topic_subscriber(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
) -> State(model, msg) {
  let subscribers =
    dict.get(state.topics, topic_name)
    |> result.unwrap(set.new())
    |> set.delete(socket_id)
  case set.is_empty(subscribers) {
    True -> {
      case state.subscriber {
        Some(sub) -> pubsub.leave(sub, topic_name)
        None -> Nil
      }
      State(..state, topics: dict.delete(state.topics, topic_name))
    }
    False ->
      State(..state, topics: dict.insert(state.topics, topic_name, subscribers))
  }
}

/// Notify the client that its topic ended. Phoenix clients rely on
/// `phx_close`/`phx_error` to leave the joined state (and, for errors,
/// schedule a rejoin). Codecs without close/error encoders skip this.
fn send_terminal_frame(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  close_join_ref: Option(String),
  reason: StopReason,
) -> Nil {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Nil
    Ok(socket) -> {
      let encoder = case reason {
        sock.Errored(_) -> codec.encode_error(state.config.codec)
        sock.Normal | sock.Shutdown | sock.HeartbeatTimeout ->
          codec.encode_close(state.config.codec)
      }
      case encoder {
        Some(encode) -> {
          let _send_result =
            send_frame_logged(
              state,
              socket,
              topic_name,
              encode(close_join_ref, topic_name),
            )
          Nil
        }
        None -> Nil
      }
    }
  }
}

/// Tear down a whole socket: close every joined topic (delivering
/// `Closed`), then close the transport connection and drop socket state.
fn teardown_socket(
  state: State(model, msg),
  socket_id: String,
  reason: StopReason,
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) -> {
      state.logger
      |> log.debug(
        "Socket teardown",
        list.append(
          [#("socket_id", socket_id), #("reason", stop_reason_string(reason))],
          joined_topics_metadata(socket),
        ),
      )
      let state = close_all_topics(state, socket_id, reason)
      let state = remove_socket_rate_limits(state, socket_id)
      // Actively close the transport connection after the terminal frames
      // above have been queued, so evicted sockets do not linger as
      // zombies. A no-op when the transport already closed or never
      // registered a closer.
      case dict.get(state.sockets, socket_id) {
        Ok(socket) -> socket.close()
        Error(Nil) -> Nil
      }
      State(..state, sockets: dict.delete(state.sockets, socket_id))
    }
  }
}

/// Close every joined topic in sorted order. Nested stop requests are
/// ignored (the socket is already tearing down), and a topic already
/// closed by a nested kick is skipped by `close_topic`'s own joined
/// check. No topic can be joined during teardown, so the list taken up
/// front covers every close.
fn close_all_topics(
  state: State(model, msg),
  socket_id: String,
  reason: StopReason,
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) ->
      dict.keys(socket.join_refs)
      |> list.sort(string.compare)
      |> list.fold(state, fn(st, topic_name) {
        close_topic(st, socket_id, topic_name, reason).state
      })
  }
}

fn socket_subscribed(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
) -> Bool {
  case dict.get(state.sockets, socket_id) {
    Ok(socket) -> dict.has_key(socket.join_refs, topic_name)
    Error(Nil) -> False
  }
}

// ── Effect interpreter ──────────────────────────────────────────────────────

/// Apply an update's effects strictly in list order. Frames are written as
/// each effect is applied and all writes go through this single actor, so
/// list order is wire order. `Push` validity is evaluated against the
/// subscription state *as of that point in the list*, so a `Push` ordered
/// after its topic's `AcceptJoin` is valid.
///
/// Returns the next state, the still-unanswered pending join (if any), and
/// kicked topics for `drive` to close after the fold.
fn apply_effects(
  state: State(model, msg),
  socket_id: String,
  effects: List(Effect),
  pending: Option(Pending),
) -> #(State(model, msg), Option(Pending), List(String)) {
  list.fold(effects, #(state, pending, []), fn(acc, effect) {
    let #(state, pending, kicks) = acc
    case effect {
      sock.AcceptJoin(ref, reply) ->
        apply_accept_join(state, socket_id, ref, reply, pending, kicks)
      sock.RejectJoin(ref, reason) ->
        apply_reject_join(state, socket_id, ref, reason, pending, kicks)
      sock.ReplyOk(ref, payload) -> {
        let state = apply_reply(state, socket_id, ref, codec.StatusOk, payload)
        #(state, pending, kicks)
      }
      sock.ReplyError(ref, payload) -> {
        let state =
          apply_reply(state, socket_id, ref, codec.StatusError, payload)
        #(state, pending, kicks)
      }
      sock.Push(topic_name, event_name, payload) -> {
        apply_push(state, socket_id, topic_name, event_name, payload)
        #(state, pending, kicks)
      }
      sock.Broadcast(topic_name, event_name, payload) -> {
        broadcast_with_pubsub(state, topic_name, event_name, payload, None)
        #(state, pending, kicks)
      }
      sock.BroadcastFrom(topic_name, event_name, payload) -> {
        broadcast_with_pubsub(
          state,
          topic_name,
          event_name,
          payload,
          Some(socket_id),
        )
        #(state, pending, kicks)
      }
      sock.PresenceTrack(topic_name, key, meta) -> #(
        apply_presence_track(state, socket_id, topic_name, key, meta),
        pending,
        kicks,
      )
      sock.PresenceUntrack(topic_name, key) -> #(
        apply_presence_untrack(state, socket_id, topic_name, key),
        pending,
        kicks,
      )
      sock.PushPresence(topic_name, event_name, encode) -> {
        case presence_snapshot(state, socket_id, topic_name, encode) {
          Ok(payload) ->
            apply_push(state, socket_id, topic_name, event_name, payload)
          Error(Nil) -> Nil
        }
        #(state, pending, kicks)
      }
      sock.BroadcastPresence(topic_name, event_name, encode) -> {
        case presence_snapshot(state, socket_id, topic_name, encode) {
          Ok(payload) ->
            broadcast_with_pubsub(state, topic_name, event_name, payload, None)
          Error(Nil) -> Nil
        }
        #(state, pending, kicks)
      }
      sock.KickTopic(topic_name) ->
        case
          socket_subscribed(state, socket_id, topic_name)
          && !list.contains(kicks, topic_name)
        {
          True -> #(state, pending, list.append(kicks, [topic_name]))
          False -> {
            state.logger
            |> log.warn("KickTopic ignored: topic not joined", [
              #("socket_id", socket_id),
              #("topic", topic_name),
            ])
            #(state, pending, kicks)
          }
        }
    }
  })
}

fn apply_accept_join(
  state: State(model, msg),
  socket_id: String,
  ref: Ref,
  reply: Option(Json),
  pending: Option(Pending),
  kicks: List(String),
) -> #(State(model, msg), Option(Pending), List(String)) {
  use p <- with_matching_pending_join(
    state,
    socket_id,
    ref,
    pending,
    kicks,
    "AcceptJoin",
  )
  let state = subscribe_socket(state, socket_id, p)
  case dict.get(state.sockets, socket_id) {
    Ok(socket) -> {
      let response = option.unwrap(reply, json.object([]))
      let frame =
        codec.encode_reply(state.config.codec)(
          p.join_ref,
          p.msg_ref,
          p.topic,
          codec.StatusOk,
          response,
        )
      let _send_result = send_frame_logged(state, socket, p.topic, frame)
      Nil
    }
    Error(Nil) -> Nil
  }
  state.logger
  |> log.debug("Join accepted", [
    #("socket_id", socket_id),
    #("topic", p.topic),
  ])
  state
}

fn apply_reject_join(
  state: State(model, msg),
  socket_id: String,
  ref: Ref,
  reason: Json,
  pending: Option(Pending),
  kicks: List(String),
) -> #(State(model, msg), Option(Pending), List(String)) {
  use p <- with_matching_pending_join(
    state,
    socket_id,
    ref,
    pending,
    kicks,
    "RejectJoin",
  )
  state.logger
  |> log.debug("Join rejected", [
    #("socket_id", socket_id),
    #("topic", p.topic),
  ])
  send_error_reply(state, socket_id, p.topic, p.join_ref, p.msg_ref, reason)
  state
}

/// Run `answer` when `ref` matches the pending join, consuming it;
/// otherwise warn that the effect had no matching pending join and leave
/// the fold accumulator unchanged.
fn with_matching_pending_join(
  state: State(model, msg),
  socket_id: String,
  ref: Ref,
  pending: Option(Pending),
  kicks: List(String),
  effect_name: String,
  answer: fn(Pending) -> State(model, msg),
) -> #(State(model, msg), Option(Pending), List(String)) {
  case pending {
    Some(p) ->
      case sock.ref_is_join(ref) && sock.ref_topic(ref) == p.topic {
        True -> #(answer(p), None, kicks)
        False -> {
          warn_unmatched_join_answer(state, socket_id, ref, effect_name)
          #(state, pending, kicks)
        }
      }
    None -> {
      warn_unmatched_join_answer(state, socket_id, ref, effect_name)
      #(state, pending, kicks)
    }
  }
}

fn warn_unmatched_join_answer(
  state: State(model, msg),
  socket_id: String,
  ref: Ref,
  effect_name: String,
) -> Nil {
  state.logger
  |> log.warn(effect_name <> " ignored: no matching pending join", [
    #("socket_id", socket_id),
    #("topic", sock.ref_topic(ref)),
  ])
}

/// Commit an accepted join: record the subscription and join_ref, add the
/// socket to the topic's subscriber set, and subscribe the runtime to
/// PubSub when it is the topic's first local subscriber.
fn subscribe_socket(
  state: State(model, msg),
  socket_id: String,
  p: Pending,
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) -> {
      let socket =
        SocketState(
          ..socket,
          join_refs: dict.insert(socket.join_refs, p.topic, p.join_ref),
        )
      let state = store_socket(state, socket)
      let existing =
        dict.get(state.topics, p.topic)
        |> result.unwrap(set.new())
      case state.subscriber, set.is_empty(existing) {
        Some(sub), True -> pubsub.join(sub, p.topic)
        _, _ -> Nil
      }
      State(
        ..state,
        topics: dict.insert(
          state.topics,
          p.topic,
          set.insert(existing, socket_id),
        ),
      )
    }
  }
}

/// Send a reply for a stored `Ref`. Join refs must be answered with
/// `AcceptJoin`/`RejectJoin`, so replies against them are dropped. Message
/// refs are single-use and only valid while their topic is open: a ref that
/// was already answered, or whose topic has since closed (including across a
/// leave/rejoin), is dropped rather than sent as a stale/duplicate reply.
fn apply_reply(
  state: State(model, msg),
  socket_id: String,
  ref: Ref,
  status: codec.ReplyStatus,
  payload: Json,
) -> State(model, msg) {
  case sock.ref_is_join(ref) {
    True -> {
      state.logger
      |> log.warn("Reply ignored: join refs require AcceptJoin/RejectJoin", [
        #("socket_id", socket_id),
        #("topic", sock.ref_topic(ref)),
      ])
      state
    }
    False ->
      case dict.get(state.sockets, socket_id) {
        Error(Nil) -> state
        Ok(socket) ->
          case set.contains(socket.pending_reply_refs, ref) {
            False -> {
              state.logger
              |> log.warn("Reply ignored: unknown or already-answered ref", [
                #("socket_id", socket_id),
                #("topic", sock.ref_topic(ref)),
              ])
              state
            }
            True -> {
              let frame =
                codec.encode_reply(state.config.codec)(
                  sock.ref_join_ref(ref),
                  sock.ref_msg_ref(ref),
                  sock.ref_topic(ref),
                  status,
                  payload,
                )
              let _send_result =
                send_frame_logged(state, socket, sock.ref_topic(ref), frame)
              store_socket(
                state,
                SocketState(
                  ..socket,
                  pending_reply_refs: set.delete(socket.pending_reply_refs, ref),
                ),
              )
            }
          }
      }
  }
}

/// Record a message reply ref as outstanding for a socket.
fn register_reply_ref(
  state: State(model, msg),
  socket_id: String,
  ref: Ref,
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) ->
      store_socket(
        state,
        SocketState(
          ..socket,
          pending_reply_refs: set.insert(socket.pending_reply_refs, ref),
        ),
      )
  }
}

/// Push to this socket on a joined topic; pushes to unjoined topics are
/// dropped with a warning (order pushes after their topic's `AcceptJoin`).
fn apply_push(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Json,
) -> Nil {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Nil
    Ok(socket) ->
      case dict.has_key(socket.join_refs, topic_name) {
        False ->
          state.logger
          |> log.warn("Push dropped: topic not joined", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("event", event_name),
          ])
        True -> {
          let frame =
            codec.encode_push(state.config.codec)(
              topic_name,
              event_name,
              payload,
            )
          let _send_result = send_frame_logged(state, socket, topic_name, frame)
          Nil
        }
      }
  }
}

// ── Presence effects ────────────────────────────────────────────────────────

fn apply_presence_track(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  key: String,
  meta: Json,
) -> State(model, msg) {
  case state.config.presence, dict.get(state.sockets, socket_id) {
    None, _ -> {
      state.logger
      |> log.warn("PresenceTrack dropped: no presence handle configured", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      state
    }
    Some(_), Error(Nil) -> state
    Some(p), Ok(socket) ->
      track_socket_presence(state, socket, p, socket_id, topic_name, key, meta)
  }
}

/// Track one key for a socket and broadcast the resulting diff. Tracking a key
/// that is already tracked replaces it: the previous meta is broadcast as a
/// leave alongside the new join. A crash in the presence actor drops the
/// tracking with an error log and leaves the socket's refs unchanged.
fn track_socket_presence(
  state: State(model, msg),
  socket: SocketState(model, msg),
  p: presence.Presence,
  socket_id: String,
  topic_name: String,
  key: String,
  meta: Json,
) -> State(model, msg) {
  let topic_refs =
    dict.get(socket.presence_refs, topic_name)
    |> result.unwrap(dict.new())
  let leaves = untrack_replaced_key(p, topic_refs, socket_id, key)
  case
    internal.rescue(fn() { presence.track(p, topic_name, key, socket_id, meta) })
  {
    Error(crash) -> {
      state.logger
      |> log.error("PresenceTrack failed", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("crash", crash),
      ])
      state
    }
    Ok(ref) -> {
      let socket =
        SocketState(
          ..socket,
          presence_refs: dict.insert(
            socket.presence_refs,
            topic_name,
            dict.insert(topic_refs, key, #(ref, meta)),
          ),
        )
      let state = store_socket(state, socket)
      broadcast_presence_diff(
        state,
        topic_name,
        [presence.PresenceEntry(session_id: socket_id, key: key, meta: meta)],
        leaves,
      )
      state
    }
  }
}

/// Untrack a key that this topic already holds, returning it as a leave so the
/// replacement broadcasts as a leave plus a join. No leave when the key is new.
fn untrack_replaced_key(
  p: presence.Presence,
  topic_refs: Dict(String, #(String, Json)),
  socket_id: String,
  key: String,
) -> List(presence.PresenceEntry) {
  case dict.get(topic_refs, key) {
    Ok(#(old_ref, old_meta)) -> {
      let _untracked = internal.rescue(fn() { presence.untrack(p, old_ref) })
      [presence.PresenceEntry(session_id: socket_id, key: key, meta: old_meta)]
    }
    Error(Nil) -> []
  }
}

fn apply_presence_untrack(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  key: String,
) -> State(model, msg) {
  case state.config.presence, dict.get(state.sockets, socket_id) {
    Some(p), Ok(socket) ->
      untrack_socket_key(state, socket, p, socket_id, topic_name, key)
    None, Ok(_) -> {
      state.logger
      |> log.warn("PresenceUntrack dropped: no presence handle configured", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      state
    }
    _, Error(Nil) -> state
  }
}

/// Untrack one key a socket holds in a topic and broadcast the leave. A key the
/// socket does not hold is ignored with a debug log.
fn untrack_socket_key(
  state: State(model, msg),
  socket: SocketState(model, msg),
  p: presence.Presence,
  socket_id: String,
  topic_name: String,
  key: String,
) -> State(model, msg) {
  let topic_refs =
    dict.get(socket.presence_refs, topic_name)
    |> result.unwrap(dict.new())
  case dict.get(topic_refs, key) {
    Error(Nil) -> {
      state.logger
      |> log.debug("PresenceUntrack ignored: key not tracked", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      state
    }
    Ok(#(ref, meta)) -> {
      let _untracked = internal.rescue(fn() { presence.untrack(p, ref) })
      let socket =
        SocketState(
          ..socket,
          presence_refs: dict.insert(
            socket.presence_refs,
            topic_name,
            dict.delete(topic_refs, key),
          ),
        )
      let state = store_socket(state, socket)
      broadcast_presence_diff(state, topic_name, [], [
        presence.PresenceEntry(session_id: socket_id, key: key, meta: meta),
      ])
      state
    }
  }
}

/// Read the topic's presence entries and run the app's encoder, both at
/// effect-application time so earlier presence effects in the same list
/// are already reflected. The encoder is app code and runs rescued: a
/// crash drops the snapshot with an error log instead of taking down the
/// runtime.
fn presence_snapshot(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  encode: fn(List(presence.PresenceEntry)) -> Json,
) -> Result(Json, Nil) {
  case state.config.presence {
    None -> {
      state.logger
      |> log.warn("Presence snapshot dropped: no presence handle configured", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      Error(Nil)
    }
    Some(p) ->
      case internal.rescue(fn() { encode(presence.list(p, topic_name)) }) {
        Ok(payload) -> Ok(payload)
        Error(crash) -> {
          state.logger
          |> log.error("Presence snapshot failed", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("crash", crash),
          ])
          Error(Nil)
        }
      }
  }
}

/// Untrack every presence the runtime still holds for a closing
/// socket/topic pair and broadcast the corresponding leaves — the
/// Phoenix-style safety net for apps that do not untrack explicitly from
/// their `Closed` handling. Keys already untracked by the app are gone
/// from the map and produce no duplicate diff.
fn untrack_topic_presence(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
) -> State(model, msg) {
  case state.config.presence, dict.get(state.sockets, socket_id) {
    Some(p), Ok(socket) ->
      case dict.get(socket.presence_refs, topic_name) {
        Error(Nil) -> state
        Ok(topic_refs) ->
          untrack_topic_keys(
            state,
            socket,
            p,
            socket_id,
            topic_name,
            topic_refs,
          )
      }
    _, _ -> state
  }
}

/// Untrack every key the socket still holds in a topic, drop the topic from its
/// refs, and broadcast the leaves as one diff. No broadcast when nothing was
/// still tracked.
fn untrack_topic_keys(
  state: State(model, msg),
  socket: SocketState(model, msg),
  p: presence.Presence,
  socket_id: String,
  topic_name: String,
  topic_refs: Dict(String, #(String, Json)),
) -> State(model, msg) {
  let leaves =
    dict.fold(topic_refs, [], fn(acc, key, entry) {
      let #(ref, meta) = entry
      let _untracked = internal.rescue(fn() { presence.untrack(p, ref) })
      [
        presence.PresenceEntry(session_id: socket_id, key: key, meta: meta),
        ..acc
      ]
    })
  let socket =
    SocketState(
      ..socket,
      presence_refs: dict.delete(socket.presence_refs, topic_name),
    )
  let state = store_socket(state, socket)
  case leaves {
    [] -> Nil
    _ -> broadcast_presence_diff(state, topic_name, [], leaves)
  }
  state
}

fn broadcast_presence_diff(
  state: State(model, msg),
  topic_name: String,
  joins: List(presence.PresenceEntry),
  leaves: List(presence.PresenceEntry),
) -> Nil {
  let diff =
    presence.diff(joins: [#(topic_name, joins)], leaves: [#(topic_name, leaves)])
  broadcast_with_pubsub(
    state,
    topic_name,
    "presence_diff",
    presence_wire.encode_diff(diff, topic_name),
    None,
  )
}

// ── Broadcasts ──────────────────────────────────────────────────────────────

/// Fan a message out to the topic's local subscribers. Every socket shares
/// the configured codec, so the frame is encoded once and sent to each
/// recipient.
fn local_broadcast(
  state: State(model, msg),
  topic_name: String,
  event_name: String,
  payload: Json,
  except: Option(String),
) -> Nil {
  let subscriber_set =
    dict.get(state.topics, topic_name)
    |> result.unwrap(set.new())
  let subscriber_set = case except {
    None -> subscriber_set
    Some(except_id) -> set.delete(subscriber_set, except_id)
  }
  state.logger
  |> log.debug("Broadcast dispatched", [
    #("topic", topic_name),
    #("event", event_name),
    #("recipient_count", int.to_string(set.size(subscriber_set))),
    #("except", optional_string(except)),
  ])
  let frame =
    codec.encode_push(state.config.codec)(topic_name, event_name, payload)
  set.to_list(subscriber_set)
  |> list.each(fn(socket_id) {
    case dict.get(state.sockets, socket_id) {
      Ok(socket) -> {
        let _send_result = send_frame_logged(state, socket, topic_name, frame)
        Nil
      }
      Error(Nil) -> Nil
    }
  })
}

/// Local fan-out plus distributed forwarding when PubSub is configured.
/// Used by the effect interpreter, which runs inside the runtime actor —
/// the actor's own pid is the PubSub sender, so the runtime does not echo
/// the message back to itself.
fn broadcast_with_pubsub(
  state: State(model, msg),
  topic_name: String,
  event_name: String,
  payload: Json,
  except: Option(String),
) -> Nil {
  local_broadcast(state, topic_name, event_name, payload, except)
  case state.pubsub {
    Some(ps) ->
      forward_to_pubsub(
        ps,
        process.self(),
        topic_name,
        event_name,
        payload,
        except,
      )
    None -> Nil
  }
}

/// Forward a broadcast to PubSub for the other nodes' runtimes,
/// attributed to `from` so the runtime at that pid does not echo the
/// message back to itself. Runs in the calling process.
pub fn forward_to_pubsub(
  ps: PubSub(Json),
  from: process.Pid,
  topic_name: String,
  event_name: String,
  payload: Json,
  except: Option(String),
) -> Nil {
  case except {
    None -> pubsub.broadcast_from(ps, from, topic_name, event_name, payload)
    Some(socket_id) ->
      pubsub.broadcast_from_socket(
        ps,
        from,
        socket_id,
        topic_name,
        event_name,
        payload,
      )
  }
}

fn handle_remote_broadcast(
  state: State(model, msg),
  pubsub_msg: pubsub.Message(Json),
) -> actor.Next(State(model, msg), Msg(msg)) {
  let except = case pubsub_msg.from {
    pubsub.FromSocket(_, socket_id) -> Some(socket_id)
    pubsub.System | pubsub.FromPid(_) -> None
  }
  local_broadcast(
    state,
    pubsub_msg.topic,
    pubsub_msg.event,
    pubsub_msg.payload,
    except,
  )
  actor.continue(state)
}

// ── Rate limiting ───────────────────────────────────────────────────────────

fn check_message_rate(
  state: State(model, msg),
  socket_id: String,
) -> #(State(model, msg), Bool) {
  case state.config.message_limits {
    None -> #(state, True)
    Some(limits) -> {
      let #(buckets, allowed) =
        take_from(state.message_buckets, socket_id, limits)
      #(State(..state, message_buckets: buckets), allowed)
    }
  }
}

fn check_join_rate(
  state: State(model, msg),
  socket_id: String,
) -> #(State(model, msg), Bool) {
  case state.config.join_limits {
    None -> #(state, True)
    Some(limits) -> {
      let #(buckets, allowed) = take_from(state.join_buckets, socket_id, limits)
      #(State(..state, join_buckets: buckets), allowed)
    }
  }
}

/// Take one token from `key`'s bucket, creating the bucket from `limits`
/// on first use. Returns the updated bucket dict and whether the token
/// was granted.
fn take_from(
  buckets: Dict(String, rate_limit.Bucket),
  key: String,
  limits: RateLimitConfig,
) -> #(Dict(String, rate_limit.Bucket), Bool) {
  let bucket =
    dict.get(buckets, key)
    |> result.lazy_unwrap(fn() { rate_limit.new_bucket(limits) })
  let #(bucket, taken) = rate_limit.take(bucket)
  #(dict.insert(buckets, key, bucket), result.is_ok(taken))
}

/// Per-topic message rate limits: the first matching topic pattern wins,
/// falling back to the global channel limits.
fn resolve_channel_limits(
  config: Config,
  topic_name: String,
) -> Option(RateLimitConfig) {
  let matched =
    list.find(config.topic_rates, fn(entry) {
      let #(pattern, _limits) = entry
      topic.matches(pattern, topic_name)
    })
  case matched {
    Ok(#(_pattern, limits)) -> Some(limits)
    Error(Nil) -> config.channel_limits
  }
}

/// The topic's existing bucket refills from its stored config, so the
/// per-topic-pattern scan runs only on the first message for a topic —
/// when the bucket has to be created.
fn check_channel_rate(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
) -> #(State(model, msg), Bool) {
  let socket_buckets =
    dict.get(state.channel_buckets, socket_id)
    |> result.unwrap(dict.new())
  case dict.get(socket_buckets, topic_name) {
    Ok(bucket) ->
      take_channel_token(state, socket_id, socket_buckets, topic_name, bucket)
    Error(Nil) ->
      case resolve_channel_limits(state.config, topic_name) {
        None -> #(state, True)
        Some(limits) -> {
          let cap = state.config.channel_limiter_max_keys_per_socket
          use <- bool.guard(
            when: cap > 0 && dict.size(socket_buckets) >= cap,
            return: #(state, False),
          )
          take_channel_token(
            state,
            socket_id,
            socket_buckets,
            topic_name,
            rate_limit.new_bucket(limits),
          )
        }
      }
  }
}

fn take_channel_token(
  state: State(model, msg),
  socket_id: String,
  socket_buckets: Dict(String, rate_limit.Bucket),
  topic_name: String,
  bucket: rate_limit.Bucket,
) -> #(State(model, msg), Bool) {
  let #(bucket, taken) = rate_limit.take(bucket)
  let socket_buckets = dict.insert(socket_buckets, topic_name, bucket)
  #(
    State(
      ..state,
      channel_buckets: dict.insert(
        state.channel_buckets,
        socket_id,
        socket_buckets,
      ),
    ),
    result.is_ok(taken),
  )
}

fn remove_channel_bucket(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
) -> State(model, msg) {
  case dict.get(state.channel_buckets, socket_id) {
    Error(Nil) -> state
    Ok(socket_buckets) ->
      State(
        ..state,
        channel_buckets: dict.insert(
          state.channel_buckets,
          socket_id,
          dict.delete(socket_buckets, topic_name),
        ),
      )
  }
}

fn remove_socket_rate_limits(
  state: State(model, msg),
  socket_id: String,
) -> State(model, msg) {
  State(
    ..state,
    message_buckets: dict.delete(state.message_buckets, socket_id),
    join_buckets: dict.delete(state.join_buckets, socket_id),
    channel_buckets: dict.delete(state.channel_buckets, socket_id),
  )
}

// ── Small helpers ───────────────────────────────────────────────────────────

fn store_socket(
  state: State(model, msg),
  socket: SocketState(model, msg),
) -> State(model, msg) {
  State(..state, sockets: dict.insert(state.sockets, socket.id, socket))
}

fn store_model(
  state: State(model, msg),
  socket_id: String,
  model: model,
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) -> store_socket(state, SocketState(..socket, model: model))
  }
}

/// Send a `phx_reply` error to a socket (join rejections, rate limits).
fn send_error_reply(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  join_ref: Option(String),
  msg_ref: Option(String),
  reason: Json,
) -> Nil {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Nil
    Ok(socket) -> {
      let frame =
        codec.encode_reply(state.config.codec)(
          join_ref,
          msg_ref,
          topic_name,
          codec.StatusError,
          reason,
        )
      let _send_result = send_frame_logged(state, socket, topic_name, frame)
      Nil
    }
  }
}

fn send_frame(
  socket: SocketState(model, msg),
  frame: codec.Frame,
) -> Result(Nil, Nil) {
  case frame {
    codec.TextFrame(text) -> socket.send(text)
    codec.BinaryFrame(data) -> socket.send_binary(data)
  }
}

fn frame_kind(frame: codec.Frame) -> String {
  case frame {
    codec.TextFrame(_) -> "text"
    codec.BinaryFrame(_) -> "binary"
  }
}

fn send_frame_logged(
  state: State(model, msg),
  socket: SocketState(model, msg),
  topic_name: String,
  frame: codec.Frame,
) -> Result(Nil, Nil) {
  let send_result = send_frame(socket, frame)
  case send_result {
    Ok(Nil) ->
      state.logger
      |> log.debug("Outbound frame sent", [
        #("socket_id", socket.id),
        #("topic", topic_name),
        #("frame_kind", frame_kind(frame)),
      ])
    Error(Nil) ->
      state.logger
      |> log.warn("Outbound frame failed", [
        #("socket_id", socket.id),
        #("topic", topic_name),
        #("frame_kind", frame_kind(frame)),
      ])
  }
  send_result
}

fn stop_reason_string(reason: StopReason) -> String {
  case reason {
    sock.Normal -> "normal"
    sock.Shutdown -> "shutdown"
    sock.HeartbeatTimeout -> "heartbeat_timeout"
    sock.Errored(message) -> message
  }
}

fn optional_string(value: Option(String)) -> String {
  value
  |> option.unwrap("")
  |> topic.sanitize_for_log
}

fn joined_topics_metadata(
  socket: SocketState(model, msg),
) -> List(#(String, String)) {
  [
    #("joined_topic_count", int.to_string(dict.size(socket.join_refs))),
    #("joined_topics", string.join(dict.keys(socket.join_refs), ",")),
  ]
}
