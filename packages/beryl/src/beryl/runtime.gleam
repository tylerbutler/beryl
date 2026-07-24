//// Runtime actor for supervised app-side dispatch systems.
////
//// One runtime actor serves every socket started through
//// `beryl.child_spec`. It is generic over the app's `model` and `msg`
//// types: per-socket models live in the actor state, typed `Info`
//// messages arrive through the actor's own mailbox, and no value is ever
//// type-erased. Transports reach the runtime through monomorphic closures
//// captured by `beryl.child_spec`, so the frame-level transport SPI stays
//// unparameterized.
////
//// The runtime owns inbound decoding and validation, rate limiting,
//// heartbeat eviction, topic subscriptions, and broadcast fan-out. It
//// also interprets effects: each `update` returns a list of `Effect`s that
//// are applied strictly in order within a single actor turn, so effect
//// list order is wire order.

import beryl/event.{
  type ConnectInfo, type ConnectSeed, type Effect, type Input, type Next,
  type Ref, type StopReason,
}
import beryl/internal
import beryl/log.{type Logger}
import beryl/pubsub.{type PubSub}
import beryl/rate_limit.{type RateLimitConfig}
import beryl/telemetry
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

/// Configuration for the runtime actor. Built by `beryl.child_spec` from a
/// `beryl.Config`; the fields cover per-topic-pattern rate limits.
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
    telemetry: Bool,
    logging: internal.LoggingConfig,
  )
}

/// Errors when starting the runtime.
pub type StartError {
  InvalidHeartbeatTimeout
  ActorStartFailed(actor.StartError)
}

pub type AdmissionToken

@external(erlang, "beryl_ffi", "admission_token_new")
pub fn new_admission_token() -> AdmissionToken

@external(erlang, "beryl_ffi", "admission_token_cancel")
pub fn cancel_admission(token: AdmissionToken) -> Bool

@external(erlang, "beryl_ffi", "admission_token_pending")
fn admission_pending(token: AdmissionToken) -> Bool

@external(erlang, "beryl_ffi", "admission_token_claim")
fn claim_admission(token: AdmissionToken) -> Bool

fn admission_is_pending(admission: Option(AdmissionToken)) -> Bool {
  case admission {
    Some(token) -> admission_pending(token)
    None -> True
  }
}

fn claim_pending_admission(admission: Option(AdmissionToken)) -> Bool {
  case admission {
    Some(token) -> claim_admission(token)
    None -> True
  }
}

/// Messages the runtime actor handles.
pub type Msg(msg) {
  AdmitSocket(
    owner: process.Pid,
    socket_id: String,
    send: fn(String) -> Result(Nil, Nil),
    send_binary: fn(BitArray) -> Result(Nil, Nil),
    codec: Option(Codec),
    seed: ConnectSeed,
    close: fn() -> Nil,
    admission: AdmissionToken,
    reply: Subject(Bool),
  )
  SocketDisconnected(socket_id: String)
  RouteText(socket_id: String, raw_text: String)
  RouteDecoded(socket_id: String, msg: codec.Inbound)
  RouteDecodedBinary(socket_id: String, msg: codec.Inbound)
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
  GetStats(reply: Subject(StatsSnapshot))
  Stop(reply: Subject(Nil))
}

pub type StatsSnapshot {
  StatsSnapshot(
    connected_sockets: Int,
    joined_socket_topic_pairs: Int,
    active_topics: Int,
    runtime_mailbox_length: Int,
  )
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
    self_subject: Option(Subject(Msg(msg))),
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
    codec: Codec,
    /// The app's per-socket model, threaded through `update`.
    model: model,
    subscribed_topics: Set(String),
    /// Per-topic join_ref from the accepted join, echoed in replies and
    /// terminal frames and used to drop stale-instance messages.
    join_refs: Dict(String, Option(String)),
    /// Message reply refs still awaiting a reply. A ref is added when its
    /// `Message` is delivered, removed when answered (so a reply is
    /// single-use), and pruned when its topic closes (so a stale ref stored
    /// across a leave/rejoin is not replied to).
    pending_reply_refs: Set(Ref),
    last_heartbeat: Int,
    /// Native monotonic timestamp captured when the socket was accepted.
    connected_at: Int,
  )
}

/// A join delivered to `update` that has not been answered yet.
type Pending {
  Pending(
    topic: String,
    join_ref: Option(String),
    msg_ref: Option(String),
    ref: Ref,
  )
}

/// Where an event delivered to `update` came from, for crash attribution.
type Source {
  JoinSource(
    topic: String,
    join_ref: Option(String),
    msg_ref: Option(String),
    ref: Ref,
    started_at: Int,
  )
  MessageSource(topic: String, kind: telemetry.MessageKind, started_at: Int)
  InfoSource(started_at: Int)
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

/// Start runtime telemetry without touching the VM clock when disabled.
fn telemetry_start(state: State(model, msg)) -> Int {
  use <- bool.guard(when: !state.config.telemetry, return: 0)
  telemetry.start_time()
}

fn emit_join_stop(
  state: State(model, msg),
  started_at: Int,
  outcome: telemetry.JoinOutcome,
) -> Nil {
  use <- bool.guard(when: !state.config.telemetry, return: Nil)
  telemetry.emit(
    True,
    telemetry.ChannelJoinStop(
      duration: telemetry.duration_since(started_at),
      outcome: outcome,
    ),
  )
}

fn emit_message_stop(
  state: State(model, msg),
  started_at: Int,
  kind: telemetry.MessageKind,
  outcome: telemetry.MessageOutcome,
  callback_result: telemetry.CallbackResult,
) -> Nil {
  use <- bool.guard(when: !state.config.telemetry, return: Nil)
  telemetry.emit(
    True,
    telemetry.ChannelMessageStop(
      duration: telemetry.duration_since(started_at),
      kind: kind,
      outcome: outcome,
      callback_result: callback_result,
    ),
  )
}

fn disconnect_reason_telemetry(
  reason: StopReason,
) -> telemetry.DisconnectReason {
  case reason {
    event.Normal -> telemetry.NormalDisconnect
    event.Shutdown -> telemetry.ShutdownDisconnect
    event.HeartbeatTimeout -> telemetry.HeartbeatTimeout
    event.Errored(_) -> telemetry.CallbackDisconnect
  }
}

/// Start the runtime actor registered under `name`.
///
/// There is deliberately no unsupervised start: `beryl.child_spec` runs
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
  let initial_state =
    State(
      sockets: dict.new(),
      topics: dict.new(),
      config: config,
      pubsub: ps,
      subscriber: None,
      logger: internal.logger_with_config("beryl.runtime", config.logging),
      self_subject: None,
      init: init,
      update: update,
      message_buckets: dict.new(),
      join_buckets: dict.new(),
      channel_buckets: dict.new(),
    )

  actor.new_with_initialiser(5000, fn(subject) {
    let base = State(..initial_state, self_subject: Some(subject))
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
    AdmitSocket(
      owner,
      socket_id,
      send,
      send_binary,
      socket_codec,
      seed,
      close,
      admission,
      reply,
    ) ->
      handle_admit_socket(
        state,
        owner,
        socket_id,
        send,
        send_binary,
        socket_codec,
        seed,
        close,
        admission,
        reply,
      )
    SocketDisconnected(socket_id) ->
      handle_socket_disconnected(state, socket_id)
    RouteText(socket_id, raw_text) ->
      handle_route_text(state, socket_id, raw_text)
    RouteDecoded(socket_id, msg) ->
      dispatch_inbound(state, socket_id, msg, telemetry.TextMessage)
    RouteDecodedBinary(socket_id, msg) ->
      dispatch_inbound(state, socket_id, msg, telemetry.BinaryMessage)
    HandleBinary(socket_id, data) -> handle_binary_in(state, socket_id, data)
    AppInfo(socket_id, app_message) ->
      handle_app_info(state, socket_id, app_message)
    Broadcast(topic_name, event_name, payload, except) -> {
      emit_broadcast(
        state,
        topic_name,
        event_name,
        payload,
        except,
        telemetry.Local,
      )
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
    GetStats(reply) -> {
      process.send(
        reply,
        StatsSnapshot(
          connected_sockets: dict.size(state.sockets),
          joined_socket_topic_pairs: state.sockets
            |> dict.values
            |> list.fold(0, fn(total, socket) {
              total + set.size(socket.subscribed_topics)
            }),
          active_topics: dict.size(state.topics),
          runtime_mailbox_length: telemetry.mailbox_length(),
        ),
      )
      actor.continue(state)
    }
    Stop(reply) -> handle_stop(state, reply)
  }
}

// ── Socket lifecycle ────────────────────────────────────────────────────────

fn handle_admit_socket(
  state: State(model, msg),
  owner: process.Pid,
  socket_id: String,
  send: fn(String) -> Result(Nil, Nil),
  send_binary: fn(BitArray) -> Result(Nil, Nil),
  socket_codec: Option(Codec),
  seed: ConnectSeed,
  close: fn() -> Nil,
  admission: AdmissionToken,
  reply: Subject(Bool),
) -> actor.Next(State(model, msg), Msg(msg)) {
  case process.self() == owner && admission_pending(admission) {
    False -> {
      process.send(reply, False)
      actor.continue(state)
    }
    True -> {
      let #(state, admitted) =
        register_socket(
          state,
          socket_id,
          send,
          send_binary,
          socket_codec,
          seed,
          close,
          Some(admission),
        )
      process.send(reply, admitted)
      actor.continue(state)
    }
  }
}

fn register_socket(
  state: State(model, msg),
  socket_id: String,
  send: fn(String) -> Result(Nil, Nil),
  send_binary: fn(BitArray) -> Result(Nil, Nil),
  socket_codec: Option(Codec),
  seed: ConnectSeed,
  close: fn() -> Nil,
  admission: Option(AdmissionToken),
) -> #(State(model, msg), Bool) {
  use <- bool.guard(when: !admission_is_pending(admission), return: #(
    state,
    False,
  ))
  let sender = make_socket_sender(state, socket_id)
  let info = event.ConnectInfo(socket_id: socket_id, seed: seed, self: sender)
  let init = state.init
  case internal.rescue(fn() { init(info) }) {
    Error(crash) -> {
      state.logger
      |> log.error("Socket init crashed; socket not registered", [
        #("socket_id", socket_id),
        #("crash", crash),
      ])
      #(state, False)
    }
    Ok(#(model, effects)) -> {
      use <- bool.guard(when: !claim_pending_admission(admission), return: #(
        state,
        False,
      ))
      let socket =
        SocketState(
          id: socket_id,
          send: send,
          send_binary: send_binary,
          close: close,
          codec: option.unwrap(socket_codec, state.config.codec),
          model: model,
          subscribed_topics: set.new(),
          join_refs: dict.new(),
          pending_reply_refs: set.new(),
          last_heartbeat: monotonic_time_ms(),
          connected_at: telemetry_start(state),
        )
      state.logger |> log.info("Socket connected", [#("socket_id", socket_id)])
      let state =
        State(..state, sockets: dict.insert(state.sockets, socket_id, socket))
      telemetry.emit(state.config.telemetry, telemetry.SocketConnected)
      // Nothing is joined yet, so kicks cannot arise and pushes to
      // unjoined topics are dropped by the interpreter.
      let #(state, _pending, _kicks) =
        apply_effects(state, socket_id, effects, None)
      #(state, True)
    }
  }
}

/// Build the typed `Sender` for a socket. The closure sends through the
/// runtime's own mailbox — an ordinary typed send, usable from any process.
fn make_socket_sender(
  state: State(model, msg),
  socket_id: String,
) -> event.Sender(msg) {
  case state.self_subject {
    Some(subject) ->
      event.make_sender(fn(message) {
        process.send(subject, AppInfo(socket_id, message))
      })
    None -> event.make_sender(fn(_message) { Nil })
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
  actor.continue(teardown_socket(state, socket_id, event.Normal))
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
    teardown_socket(st, socket_id, event.Shutdown)
  })
  process.send(reply, Nil)
  actor.stop()
}

// ── Heartbeats ──────────────────────────────────────────────────────────────

fn handle_heartbeat(
  state: State(model, msg),
  socket_id: String,
  ref: Option(String),
  started_at: Int,
) -> actor.Next(State(model, msg), Msg(msg)) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      emit_message_stop(
        state,
        started_at,
        telemetry.HeartbeatMessage,
        telemetry.MessageSocketMissing,
        telemetry.NotApplicable,
      )
      actor.continue(state)
    }
    Ok(socket) -> {
      let state =
        store_socket(
          state,
          SocketState(..socket, last_heartbeat: monotonic_time_ms()),
        )
      let reply = codec.encode_heartbeat_reply(socket.codec)(ref)
      let _send_result =
        send_frame_logged(state, socket, "__heartbeat__", reply)
      state.logger
      |> log.debug("Heartbeat handled", [
        #("socket_id", socket_id),
        #("ref", optional_string(ref)),
      ])
      emit_message_stop(
        state,
        started_at,
        telemetry.HeartbeatMessage,
        telemetry.MessageHandled,
        telemetry.NotApplicable,
      )
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
      teardown_socket(st, socket_id, event.HeartbeatTimeout)
    })
  case state.self_subject {
    Some(subject) -> schedule_heartbeat_check(subject, state.config)
    None -> Nil
  }
  actor.continue(state)
}

// ── Inbound decoding and dispatch ───────────────────────────────────────────

fn handle_route_text(
  state: State(model, msg),
  socket_id: String,
  raw_text: String,
) -> actor.Next(State(model, msg), Msg(msg)) {
  let active_codec = case dict.get(state.sockets, socket_id) {
    Ok(socket) -> socket.codec
    Error(Nil) -> state.config.codec
  }
  let logging = state.config.logging
  case codec.decode_text(active_codec)(raw_text) {
    Error(err) -> {
      state.logger
      |> log.warn(
        "Failed to decode wire protocol message",
        list.append(
          [
            #("socket_id", socket_id),
            #("error", codec.format_decode_error(err)),
          ],
          internal.preview_metadata("frame_preview", raw_text, logging),
        ),
      )
      actor.continue(state)
    }
    Ok(msg) -> dispatch_inbound(state, socket_id, msg, telemetry.TextMessage)
  }
}

fn dispatch_inbound(
  state: State(model, msg),
  socket_id: String,
  msg: codec.Inbound,
  message_kind: telemetry.MessageKind,
) -> actor.Next(State(model, msg), Msg(msg)) {
  let msg_topic = codec.inbound_topic(msg)
  let msg_ref = codec.inbound_ref(msg)
  case codec.inbound_kind(msg) {
    codec.Join -> {
      let started_at = telemetry_start(state)
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
            started_at,
          )
        False -> reject_invalid_join(state, socket_id, msg, started_at)
      }
    }
    codec.Leave -> {
      use state <- with_message_rate_limit(state, socket_id, "leave")
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
      let started_at = telemetry_start(state)
      let #(state, allowed) = check_message_rate(state, socket_id)
      case allowed {
        False -> {
          state.logger
          |> log.warn("Message rate limited", [
            #("socket_id", socket_id),
            #("kind", "heartbeat"),
          ])
          emit_message_stop(
            state,
            started_at,
            telemetry.HeartbeatMessage,
            telemetry.MessageRateLimited,
            telemetry.NotApplicable,
          )
          actor.continue(state)
        }
        True -> handle_heartbeat(state, socket_id, msg_ref, started_at)
      }
    }
    codec.Event(event_name) -> {
      let started_at = telemetry_start(state)
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
            started_at,
            message_kind,
          )
        False, _ -> {
          state.logger
          |> log.warn("Event dropped: invalid topic", [
            #("socket_id", socket_id),
            #("topic", topic.sanitize_for_log(msg_topic)),
            #("event", topic.sanitize_for_log(event_name)),
          ])
          emit_message_stop(
            state,
            started_at,
            message_kind,
            telemetry.MessageInvalid,
            telemetry.NotApplicable,
          )
          actor.continue(state)
        }
        True, False -> {
          state.logger
          |> log.warn("Event dropped: invalid event", [
            #("socket_id", socket_id),
            #("topic", msg_topic),
            #("event", topic.sanitize_for_log(event_name)),
          ])
          emit_message_stop(
            state,
            started_at,
            message_kind,
            telemetry.MessageInvalid,
            telemetry.NotApplicable,
          )
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
            codec.topicless_events(socket.codec),
            set.to_list(socket.subscribed_topics)
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

/// Apply the per-socket message limiter to protocol frames (heartbeat,
/// leave) so flooding them cannot bypass `with_message_rate`.
fn with_message_rate_limit(
  state: State(model, msg),
  socket_id: String,
  kind: String,
  next: fn(State(model, msg)) -> actor.Next(State(model, msg), Msg(msg)),
) -> actor.Next(State(model, msg), Msg(msg)) {
  let #(state, allowed) = check_message_rate(state, socket_id)
  case allowed {
    False -> {
      state.logger
      |> log.warn("Message rate limited", [
        #("socket_id", socket_id),
        #("kind", kind),
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
  started_at: Int,
) -> actor.Next(State(model, msg), Msg(msg)) {
  let safe_topic = topic.sanitize_for_log(codec.inbound_topic(msg))
  state.logger
  |> log.warn("Join rejected: invalid topic", [
    #("socket_id", socket_id),
    #("topic", safe_topic),
  ])
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      emit_join_stop(state, started_at, telemetry.JoinSocketMissing)
      actor.continue(state)
    }
    Ok(socket) -> {
      let reply =
        codec.encode_reply(socket.codec)(
          codec.inbound_join_ref(msg),
          codec.inbound_ref(msg),
          codec.inbound_topic(msg),
          codec.StatusError,
          json.object([#("reason", json.string("invalid_topic"))]),
        )
      let _send_result = send_frame_logged(state, socket, safe_topic, reply)
      emit_join_stop(state, started_at, telemetry.JoinInvalidTopic)
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
  started_at: Int,
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
      emit_join_stop(state, started_at, telemetry.JoinRateLimited)
      actor.continue(state)
    }
    True ->
      handle_join_inner(
        state,
        socket_id,
        topic_name,
        payload,
        join_ref,
        ref,
        started_at,
      )
  }
}

fn handle_join_inner(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
) -> actor.Next(State(model, msg), Msg(msg)) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      state.logger
      |> log.debug("Join ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("reason", "socket_not_found"),
      ])
      emit_join_stop(state, started_at, telemetry.JoinSocketMissing)
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
          emit_join_stop(state, started_at, telemetry.JoinTopicLimit)
          actor.continue(state)
        }
        True -> {
          // Phoenix duplicate-join semantics: a join for an already-joined
          // topic replaces the previous instance. Close it first (the app
          // receives `Closed(topic, Normal)`) so cleanup keyed off closing
          // is never silently skipped by a rejoin.
          let state = case set.contains(socket.subscribed_topics, topic_name) {
            True ->
              drive(
                close_topic(state, socket_id, topic_name, event.Normal),
                socket_id,
              )
            False -> state
          }
          deliver_join(
            state,
            socket_id,
            topic_name,
            payload,
            join_ref,
            ref,
            started_at,
          )
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
  started_at: Int,
) -> actor.Next(State(model, msg), Msg(msg)) {
  // The Closed delivered for a duplicate join may have stopped the socket.
  use <- bool.lazy_guard(
    when: !dict.has_key(state.sockets, socket_id),
    return: fn() {
      emit_join_stop(state, started_at, telemetry.JoinSocketMissing)
      actor.continue(state)
    },
  )
  state.logger
  |> log.debug("Join delivered", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("ref", optional_string(ref)),
    #("join_ref", optional_string(join_ref)),
  ])
  let pending_ref =
    event.make_join_ref(topic: topic_name, join_ref: join_ref, msg_ref: ref)
  let join_event =
    event.Join(topic: topic_name, payload: payload, ref: pending_ref)
  let outcome =
    update_once(
      state,
      socket_id,
      join_event,
      JoinSource(topic_name, join_ref, ref, pending_ref, started_at),
    )
  actor.continue(drive(outcome, socket_id))
}

fn can_join_topic(
  socket: SocketState(model, msg),
  topic_name: String,
  config: Config,
) -> Bool {
  config.max_joined_topics_per_socket <= 0
  || set.contains(socket.subscribed_topics, topic_name)
  || set.size(socket.subscribed_topics) < config.max_joined_topics_per_socket
}

// ── Leaves ──────────────────────────────────────────────────────────────────

fn handle_leave(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  msg_join_ref: Option(String),
  ref: Option(String),
) -> actor.Next(State(model, msg), Msg(msg)) {
  let stale = case dict.get(state.sockets, socket_id) {
    Ok(socket) -> is_stale_join_ref(socket, topic_name, msg_join_ref)
    Error(Nil) -> False
  }
  use <- bool.lazy_guard(when: stale, return: fn() {
    state.logger
    |> log.debug("Leave dropped: stale join_ref", [
      #("socket_id", socket_id),
      #("topic", topic_name),
    ])
    actor.continue(state)
  })

  // Acknowledge the leave before closing, so the client sees the reply to
  // its own ref first and the terminal frame second — matching Phoenix.
  case ref, dict.get(state.sockets, socket_id) {
    Some(r), Ok(socket) -> {
      let reply =
        codec.encode_reply(socket.codec)(
          joined_ref(socket, topic_name),
          Some(r),
          topic_name,
          codec.StatusOk,
          json.object([]),
        )
      let _send_result = send_frame_logged(state, socket, topic_name, reply)
      Nil
    }
    _, _ -> Nil
  }

  actor.continue(drive(
    close_topic(state, socket_id, topic_name, event.Normal),
    socket_id,
  ))
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
  started_at: Int,
  kind: telemetry.MessageKind,
) -> actor.Next(State(model, msg), Msg(msg)) {
  let #(state, allowed) = check_message_rate(state, socket_id)
  case allowed {
    False -> {
      state.logger
      |> log.warn("Message rate limited", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageRateLimited,
        telemetry.NotApplicable,
      )
      actor.continue(state)
    }
    True ->
      handle_in_subscribed(
        state,
        socket_id,
        topic_name,
        event_name,
        payload,
        msg_join_ref,
        ref,
        started_at,
        kind,
      )
  }
}

fn handle_in_subscribed(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  msg_join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
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
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageSocketMissing,
        telemetry.NotApplicable,
      )
      actor.continue(state)
    }
    Ok(socket) ->
      case set.contains(socket.subscribed_topics, topic_name) {
        False ->
          reject_unjoined_event(
            state,
            socket,
            socket_id,
            topic_name,
            event_name,
            ref,
            started_at,
            kind,
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
              emit_message_stop(
                state,
                started_at,
                kind,
                telemetry.MessageStale,
                telemetry.NotApplicable,
              )
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
                started_at,
                kind,
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
  started_at: Int,
  kind: telemetry.MessageKind,
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
        codec.encode_reply(socket.codec)(
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
  emit_message_stop(
    state,
    started_at,
    kind,
    telemetry.MessageUnjoined,
    telemetry.NotApplicable,
  )
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
  started_at: Int,
  kind: telemetry.MessageKind,
) -> actor.Next(State(model, msg), Msg(msg)) {
  let #(state, allowed) = check_channel_rate(state, socket_id, topic_name)
  case allowed {
    False -> {
      state.logger
      |> log.warn("Channel rate limited", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageRateLimited,
        telemetry.NotApplicable,
      )
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
          event.make_message_ref(
            topic: topic_name,
            join_ref: joined_ref(socket, topic_name),
            msg_ref: Some(r),
          )
        })
      case message_ref {
        Some(message_ref) ->
          case set.contains(socket.pending_reply_refs, message_ref) {
            True -> {
              state.logger
              |> log.warn(
                "Inbound message rejected: reply ref already outstanding",
                [
                  #("socket_id", socket_id),
                  #("topic", topic_name),
                  #("event", event_name),
                ],
              )
              send_error_reply(
                state,
                socket_id,
                topic_name,
                event.ref_join_ref(message_ref),
                event.ref_msg_ref(message_ref),
                json.object([#("reason", json.string("duplicate_ref"))]),
              )
              emit_message_stop(
                state,
                started_at,
                kind,
                telemetry.MessageInvalid,
                telemetry.NotApplicable,
              )
              actor.continue(state)
            }
            False ->
              deliver_client_message(
                state,
                socket_id,
                topic_name,
                event_name,
                payload,
                Some(message_ref),
                started_at,
                kind,
              )
          }
        None ->
          deliver_client_message(
            state,
            socket_id,
            topic_name,
            event_name,
            payload,
            None,
            started_at,
            kind,
          )
      }
    }
  }
}

fn deliver_client_message(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  message_ref: Option(Ref),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> actor.Next(State(model, msg), Msg(msg)) {
  // Track the reply ref as outstanding so `apply_reply` can enforce
  // single-use, reject overlapping reuse, and drop replies to refs whose
  // topic later closes.
  let state = case message_ref {
    Some(message_ref) -> register_reply_ref(state, socket_id, message_ref)
    None -> state
  }
  let outcome =
    update_once(
      state,
      socket_id,
      event.Message(
        topic: topic_name,
        event: event_name,
        payload: payload,
        ref: message_ref,
      ),
      MessageSource(topic_name, kind, started_at),
    )
  actor.continue(drive(outcome, socket_id))
}

// ── Binary frames ───────────────────────────────────────────────────────────

fn handle_binary_in(
  state: State(model, msg),
  socket_id: String,
  data: BitArray,
) -> actor.Next(State(model, msg), Msg(msg)) {
  let active_codec = case dict.get(state.sockets, socket_id) {
    Ok(socket) -> socket.codec
    Error(Nil) -> state.config.codec
  }
  case codec.decode_binary(active_codec) {
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
        Ok(msg) ->
          dispatch_inbound(state, socket_id, msg, telemetry.BinaryMessage)
      }
    None -> {
      let started_at = telemetry_start(state)
      let #(state, allowed) = check_message_rate(state, socket_id)
      case allowed {
        False -> {
          state.logger
          |> log.warn("Binary message rate limited", [
            #("socket_id", socket_id),
          ])
          emit_message_stop(
            state,
            started_at,
            telemetry.BinaryMessage,
            telemetry.MessageRateLimited,
            telemetry.NotApplicable,
          )
          actor.continue(state)
        }
        True ->
          case dict.get(state.sockets, socket_id) {
            Error(Nil) -> {
              state.logger
              |> log.debug("Binary message ignored", [
                #("socket_id", socket_id),
                #("reason", "socket_not_found"),
              ])
              emit_message_stop(
                state,
                started_at,
                telemetry.BinaryMessage,
                telemetry.MessageSocketMissing,
                telemetry.NotApplicable,
              )
              actor.continue(state)
            }
            Ok(socket) -> {
              // Fan the raw frame out to every joined topic, in sorted
              // order for determinism.
              let topics =
                set.to_list(socket.subscribed_topics)
                |> list.sort(string.compare)
              case topics {
                [] -> {
                  emit_message_stop(
                    state,
                    started_at,
                    telemetry.BinaryMessage,
                    telemetry.MessageUnjoined,
                    telemetry.NotApplicable,
                  )
                  actor.continue(state)
                }
                _ ->
                  actor.continue(fan_out_binary(
                    state,
                    socket_id,
                    topics,
                    data,
                    started_at,
                  ))
              }
            }
          }
      }
    }
  }
}

fn fan_out_binary(
  state: State(model, msg),
  socket_id: String,
  topics: List(String),
  data: BitArray,
  started_at: Int,
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
              event.Binary(topic: topic_name, data: data),
              MessageSource(topic_name, telemetry.BinaryMessage, started_at),
            ),
            socket_id,
          )
      }
      fan_out_binary(state, socket_id, rest, data, started_at)
    }
  }
}

// ── Server-side info ────────────────────────────────────────────────────────

fn handle_app_info(
  state: State(model, msg),
  socket_id: String,
  message: msg,
) -> actor.Next(State(model, msg), Msg(msg)) {
  let started_at = telemetry_start(state)
  case dict.has_key(state.sockets, socket_id) {
    False -> {
      state.logger
      |> log.debug("Info dropped", [
        #("socket_id", socket_id),
        #("reason", "socket_not_found"),
      ])
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageSocketMissing,
        telemetry.NotApplicable,
      )
      actor.continue(state)
    }
    True ->
      actor.continue(drive(
        update_once(
          state,
          socket_id,
          event.Info(message),
          InfoSource(started_at),
        ),
        socket_id,
      ))
  }
}

// ── The update engine ───────────────────────────────────────────────────────

fn effects_callback_result(effects: List(Effect)) -> telemetry.CallbackResult {
  case effects {
    [] -> telemetry.NoReply
    [effect, ..rest] ->
      case effect {
        event.ReplyOk(_, _) -> telemetry.Reply
        event.ReplyError(_, _) -> telemetry.ReplyError
        event.Push(_, _, _)
        | event.Broadcast(_, _, _)
        | event.BroadcastFrom(_, _, _) -> telemetry.Push
        _ -> effects_callback_result(rest)
      }
  }
}

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
    Error(Nil) -> {
      case source {
        JoinSource(_, _, _, _, started_at) ->
          emit_join_stop(state, started_at, telemetry.JoinSocketMissing)
        MessageSource(_, kind, started_at) ->
          emit_message_stop(
            state,
            started_at,
            kind,
            telemetry.MessageSocketMissing,
            telemetry.NotApplicable,
          )
        InfoSource(started_at) ->
          emit_message_stop(
            state,
            started_at,
            telemetry.InfoMessage,
            telemetry.MessageSocketMissing,
            telemetry.NotApplicable,
          )
        ClosedSource -> Nil
      }
      Outcome(state, [], None)
    }
    Ok(socket) -> {
      let update = state.update
      let model = socket.model
      case internal.rescue(fn() { update(model, ev) }) {
        Error(crash) -> handle_update_crash(state, socket_id, source, crash)
        Ok(event.Stop(reason)) -> {
          state.logger
          |> log.debug("Update stopped socket", [
            #("socket_id", socket_id),
            #("reason", stop_reason_string(reason)),
          ])
          // A join answered with Stop is still unanswered on the wire:
          // fail it closed before the teardown frames.
          reject_unanswered_join(state, socket_id, source)
          case source {
            JoinSource(_, _, _, _, started_at) ->
              emit_join_stop(state, started_at, telemetry.JoinHandlerRejected)
            MessageSource(_, kind, started_at) ->
              emit_message_stop(
                state,
                started_at,
                kind,
                telemetry.MessageHandled,
                telemetry.Stop,
              )
            InfoSource(started_at) ->
              emit_message_stop(
                state,
                started_at,
                telemetry.InfoMessage,
                telemetry.MessageHandled,
                telemetry.Stop,
              )
            ClosedSource -> Nil
          }
          Outcome(state, [], Some(reason))
        }
        Ok(event.Next(new_model, effects)) -> {
          let state = store_model(state, socket_id, new_model)
          let pending = case source {
            JoinSource(topic_name, join_ref, msg_ref, ref, _) ->
              Some(Pending(topic_name, join_ref, msg_ref, ref))
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
                json.object([
                  #("reason", json.string("join not acknowledged")),
                ]),
              )
              Nil
            }
            None -> Nil
          }
          case source {
            JoinSource(topic_name, _, _, _, started_at) -> {
              let join_outcome = case
                pending,
                socket_subscribed(state, socket_id, topic_name)
              {
                None, True -> telemetry.JoinAccepted
                _, _ -> telemetry.JoinHandlerRejected
              }
              emit_join_stop(state, started_at, join_outcome)
            }
            MessageSource(_, kind, started_at) ->
              emit_message_stop(
                state,
                started_at,
                kind,
                telemetry.MessageHandled,
                effects_callback_result(effects),
              )
            InfoSource(started_at) ->
              emit_message_stop(
                state,
                started_at,
                telemetry.InfoMessage,
                telemetry.MessageHandled,
                effects_callback_result(effects),
              )
            ClosedSource -> Nil
          }
          Outcome(state, kicks, None)
        }
      }
    }
  }
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
    JoinSource(topic_name, join_ref, msg_ref, _, started_at) -> {
      state.logger
      |> log.error("Update crashed handling join", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("crash", crash),
      ])
      send_error_reply(
        state,
        socket_id,
        topic_name,
        join_ref,
        msg_ref,
        json.object([#("reason", json.string("join crashed"))]),
      )
      emit_join_stop(state, started_at, telemetry.JoinCallbackFailed)
      Outcome(state, [], None)
    }
    MessageSource(topic_name, kind, started_at) -> {
      state.logger
      |> log.error("Update crashed; closing topic", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("crash", crash),
      ])
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageCallbackFailed,
        telemetry.CallbackFailed,
      )
      close_topic(state, socket_id, topic_name, event.Errored(crash))
    }
    InfoSource(started_at) -> {
      state.logger
      |> log.error("Update crashed handling info; closing socket", [
        #("socket_id", socket_id),
        #("crash", crash),
      ])
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageCallbackFailed,
        telemetry.CallbackFailed,
      )
      Outcome(teardown_socket(state, socket_id, event.Errored(crash)), [], None)
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
    JoinSource(topic_name, join_ref, msg_ref, _, _) ->
      send_error_reply(
        state,
        socket_id,
        topic_name,
        join_ref,
        msg_ref,
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
        [topic_name, ..rest] -> {
          let next = case
            socket_subscribed(outcome.state, socket_id, topic_name)
          {
            False -> Outcome(outcome.state, rest, None)
            True -> {
              let closed =
                close_topic(
                  outcome.state,
                  socket_id,
                  topic_name,
                  event.Shutdown,
                )
              Outcome(
                closed.state,
                list.append(rest, closed.kicks),
                closed.stop,
              )
            }
          }
          drive(next, socket_id)
        }
      }
  }
}

/// Close one topic subscription: remove the subscription state, deliver
/// `Closed` to the app, and send the terminal frame. Subscription state is
/// removed *before* the `Closed`
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
      case set.contains(socket.subscribed_topics, topic_name) {
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
              subscribed_topics: set.delete(
                socket.subscribed_topics,
                topic_name,
              ),
              join_refs: dict.delete(socket.join_refs, topic_name),
              pending_reply_refs: set.filter(socket.pending_reply_refs, fn(ref) {
                event.ref_topic(ref) != topic_name
              }),
            )
          let state = store_socket(state, socket)
          let state = remove_channel_bucket(state, socket_id, topic_name)
          let state = remove_topic_subscriber(state, socket_id, topic_name)

          let out =
            update_once(
              state,
              socket_id,
              event.Closed(topic: topic_name, reason: reason),
              ClosedSource,
            )
          send_terminal_frame(
            out.state,
            socket_id,
            topic_name,
            close_join_ref,
            reason,
          )
          Outcome(out.state, out.kicks, out.stop)
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
        event.Errored(_) -> codec.encode_error(socket.codec)
        event.Normal | event.Shutdown | event.HeartbeatTimeout ->
          codec.encode_close(socket.codec)
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
      let new_state =
        State(..state, sockets: dict.delete(state.sockets, socket_id))
      use <- bool.guard(when: !state.config.telemetry, return: new_state)
      telemetry.emit(
        True,
        telemetry.SocketDisconnected(
          duration: telemetry.duration_since(socket.connected_at),
          joined_channels: set.size(socket.subscribed_topics),
          reason: disconnect_reason_telemetry(reason),
        ),
      )
      new_state
    }
  }
}

/// Close every joined topic in sorted order. Each `close_topic` removes
/// one topic from the subscription set, so this terminates; nested stop
/// requests are ignored (the socket is already tearing down) and nested
/// kicks are covered by the loop itself.
fn close_all_topics(
  state: State(model, msg),
  socket_id: String,
  reason: StopReason,
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) ->
      case set.to_list(socket.subscribed_topics) |> list.sort(string.compare) {
        [] -> state
        [topic_name, ..] -> {
          let out = close_topic(state, socket_id, topic_name, reason)
          close_all_topics(out.state, socket_id, reason)
        }
      }
  }
}

fn socket_subscribed(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
) -> Bool {
  case dict.get(state.sockets, socket_id) {
    Ok(socket) -> set.contains(socket.subscribed_topics, topic_name)
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
      event.AcceptJoin(ref, reply) ->
        apply_accept_join(state, socket_id, ref, reply, pending, kicks)
      event.RejectJoin(ref, reason) ->
        apply_reject_join(state, socket_id, ref, reason, pending, kicks)
      event.ReplyOk(ref, payload) -> {
        let state = apply_reply(state, socket_id, ref, codec.StatusOk, payload)
        #(state, pending, kicks)
      }
      event.ReplyError(ref, payload) -> {
        let state =
          apply_reply(state, socket_id, ref, codec.StatusError, payload)
        #(state, pending, kicks)
      }
      event.Push(topic_name, event_name, payload) -> {
        apply_push(state, socket_id, topic_name, event_name, payload)
        #(state, pending, kicks)
      }
      event.Broadcast(topic_name, event_name, payload) -> {
        broadcast_with_pubsub(state, topic_name, event_name, payload, None)
        #(state, pending, kicks)
      }
      event.BroadcastFrom(topic_name, event_name, payload) -> {
        broadcast_with_pubsub(
          state,
          topic_name,
          event_name,
          payload,
          Some(socket_id),
        )
        #(state, pending, kicks)
      }
      event.KickTopic(topic_name) ->
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
  case pending {
    Some(p) ->
      case event.ref_is_join(ref) && event.refs_match(ref, p.ref) {
        True -> {
          let state = subscribe_socket(state, socket_id, p)
          case dict.get(state.sockets, socket_id) {
            Ok(socket) -> {
              let response = option.unwrap(reply, json.object([]))
              let frame =
                codec.encode_reply(socket.codec)(
                  p.join_ref,
                  p.msg_ref,
                  p.topic,
                  codec.StatusOk,
                  response,
                )
              let _send_result =
                send_frame_logged(state, socket, p.topic, frame)
              Nil
            }
            Error(Nil) -> Nil
          }
          state.logger
          |> log.debug("Join accepted", [
            #("socket_id", socket_id),
            #("topic", p.topic),
          ])
          #(state, None, kicks)
        }
        False -> {
          warn_unmatched_join_answer(state, socket_id, ref, "AcceptJoin")
          #(state, pending, kicks)
        }
      }
    None -> {
      warn_unmatched_join_answer(state, socket_id, ref, "AcceptJoin")
      #(state, pending, kicks)
    }
  }
}

fn apply_reject_join(
  state: State(model, msg),
  socket_id: String,
  ref: Ref,
  reason: Json,
  pending: Option(Pending),
  kicks: List(String),
) -> #(State(model, msg), Option(Pending), List(String)) {
  case pending {
    Some(p) ->
      case event.ref_is_join(ref) && event.refs_match(ref, p.ref) {
        True -> {
          state.logger
          |> log.debug("Join rejected", [
            #("socket_id", socket_id),
            #("topic", p.topic),
          ])
          send_error_reply(
            state,
            socket_id,
            p.topic,
            p.join_ref,
            p.msg_ref,
            reason,
          )
          #(state, None, kicks)
        }
        False -> {
          warn_unmatched_join_answer(state, socket_id, ref, "RejectJoin")
          #(state, pending, kicks)
        }
      }
    None -> {
      warn_unmatched_join_answer(state, socket_id, ref, "RejectJoin")
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
    #("topic", event.ref_topic(ref)),
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
          subscribed_topics: set.insert(socket.subscribed_topics, p.topic),
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
  case event.ref_is_join(ref) {
    True -> {
      state.logger
      |> log.warn("Reply ignored: join refs require AcceptJoin/RejectJoin", [
        #("socket_id", socket_id),
        #("topic", event.ref_topic(ref)),
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
                #("topic", event.ref_topic(ref)),
              ])
              state
            }
            True -> {
              let frame =
                codec.encode_reply(socket.codec)(
                  event.ref_join_ref(ref),
                  event.ref_msg_ref(ref),
                  event.ref_topic(ref),
                  status,
                  payload,
                )
              let _send_result =
                send_frame_logged(state, socket, event.ref_topic(ref), frame)
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
      case set.contains(socket.subscribed_topics, topic_name) {
        False ->
          state.logger
          |> log.warn("Push dropped: topic not joined", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("event", event_name),
          ])
        True -> {
          let frame =
            codec.encode_push(socket.codec)(topic_name, event_name, payload)
          let _send_result = send_frame_logged(state, socket, topic_name, frame)
          Nil
        }
      }
  }
}

// ── Broadcasts ──────────────────────────────────────────────────────────────

/// Fan a message out to the topic's local subscribers, encoding per
/// recipient so connections with different codecs each get their own
/// framing.
fn local_broadcast(
  state: State(model, msg),
  topic_name: String,
  event_name: String,
  payload: Json,
  except: Option(String),
) -> #(Int, Int) {
  let subscribers =
    dict.get(state.topics, topic_name)
    |> result.unwrap(set.new())
    |> set.to_list()
  let recipients = case except {
    None -> subscribers
    Some(except_id) -> list.filter(subscribers, fn(id) { id != except_id })
  }
  state.logger
  |> log.debug("Broadcast dispatched", [
    #("topic", topic_name),
    #("event", event_name),
    #("recipient_count", int.to_string(list.length(recipients))),
    #("except", optional_string(except)),
  ])
  list.fold(recipients, #(0, 0), fn(counts, socket_id) {
    case dict.get(state.sockets, socket_id) {
      Ok(socket) -> {
        let frame =
          codec.encode_push(socket.codec)(topic_name, event_name, payload)
        let send_result = send_frame_logged(state, socket, topic_name, frame)
        #(
          counts.0 + 1,
          counts.1
            + case send_result {
            Ok(Nil) -> 0
            Error(Nil) -> 1
          },
        )
      }
      Error(Nil) -> counts
    }
  })
}

fn emit_broadcast(
  state: State(model, msg),
  topic_name: String,
  event_name: String,
  payload: Json,
  except: Option(String),
  origin: telemetry.BroadcastOrigin,
) -> Nil {
  let started_at = telemetry_start(state)
  let #(recipients, send_failures) =
    local_broadcast(state, topic_name, event_name, payload, except)
  use <- bool.guard(when: !state.config.telemetry, return: Nil)
  telemetry.emit(
    True,
    telemetry.BroadcastStop(
      duration: telemetry.duration_since(started_at),
      recipients: recipients,
      send_failures: send_failures,
      origin: origin,
    ),
  )
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
  emit_broadcast(
    state,
    topic_name,
    event_name,
    payload,
    except,
    telemetry.Local,
  )
  case state.pubsub {
    Some(ps) ->
      case except {
        None ->
          pubsub.broadcast_from(
            ps,
            process.self(),
            topic_name,
            event_name,
            payload,
          )
        Some(socket_id) ->
          pubsub.broadcast_from_socket(
            ps,
            process.self(),
            socket_id,
            topic_name,
            event_name,
            payload,
          )
      }
    None -> Nil
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
  emit_broadcast(
    state,
    pubsub_msg.topic,
    pubsub_msg.event,
    pubsub_msg.payload,
    except,
    telemetry.Remote,
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
      let bucket =
        dict.get(state.message_buckets, socket_id)
        |> result.lazy_unwrap(fn() { rate_limit.new_bucket(limits) })
      let #(bucket, taken) = rate_limit.take(bucket)
      #(
        State(
          ..state,
          message_buckets: dict.insert(state.message_buckets, socket_id, bucket),
        ),
        result.is_ok(taken),
      )
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
      let bucket =
        dict.get(state.join_buckets, socket_id)
        |> result.lazy_unwrap(fn() { rate_limit.new_bucket(limits) })
      let #(bucket, taken) = rate_limit.take(bucket)
      #(
        State(
          ..state,
          join_buckets: dict.insert(state.join_buckets, socket_id, bucket),
        ),
        result.is_ok(taken),
      )
    }
  }
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

fn check_channel_rate(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
) -> #(State(model, msg), Bool) {
  case resolve_channel_limits(state.config, topic_name) {
    None -> #(state, True)
    Some(limits) -> take_channel_token(state, socket_id, topic_name, limits)
  }
}

fn take_channel_token(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  limits: RateLimitConfig,
) -> #(State(model, msg), Bool) {
  let socket_buckets =
    dict.get(state.channel_buckets, socket_id)
    |> result.unwrap(dict.new())
  let cap = state.config.channel_limiter_max_keys_per_socket
  let over_cap = case dict.has_key(socket_buckets, topic_name) {
    True -> False
    False -> cap > 0 && dict.size(socket_buckets) >= cap
  }
  use <- bool.guard(when: over_cap, return: #(state, False))
  let bucket =
    dict.get(socket_buckets, topic_name)
    |> result.lazy_unwrap(fn() { rate_limit.new_bucket(limits) })
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
        codec.encode_reply(socket.codec)(
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
    event.Normal -> "normal"
    event.Shutdown -> "shutdown"
    event.HeartbeatTimeout -> "heartbeat_timeout"
    event.Errored(message) -> message
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
  let topics = set.to_list(socket.subscribed_topics)
  [
    #("joined_topic_count", int.to_string(list.length(topics))),
    #("joined_topics", string.join(topics, ",")),
  ]
}
