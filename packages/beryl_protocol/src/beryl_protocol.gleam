//// A deterministic channel protocol. Hosts supply time, decoded messages and
//// application decisions, then execute returned actions in list order.
////
//// Admission and cleanup are barriers: feed their completion back before
//// later external input. `DrainBeforeCleanup` lets committed worker results
//// reply and push until the host reports cleanup complete. Raw callbacks use
//// `InvalidateImmediately` and finish unanswered joins with `CallbackFinished`.
////
//// Connection epochs are trusted host-issued unique strings, not socket IDs
//// or client references. Never reuse an epoch for another connection.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const maximum_integer = 9_007_199_254_740_991

const maximum_snapshot_bytes = 1_048_576

/// Validated resource limits. Payload byte admission remains the host's job.
pub opaque type Config {
  Config(
    max_topic_bytes: Int,
    max_event_bytes: Int,
    max_channels: Int,
    max_pending: Int,
    heartbeat_timeout_ms: Int,
    topicless_events: Bool,
  )
}

/// Trusted connection identity.
pub opaque type Connection {
  Connection(epoch: String)
}

/// One topic instance, independent of all wire references.
pub opaque type Channel {
  Channel(connection: Connection, generation: Int)
}

/// Single-use join, reply, admission or cleanup capability.
pub opaque type Operation {
  Operation(channel: Channel, sequence: Int)
}

/// When the host invalidates a closing channel's pending replies and pushes.
pub type CloseMode {
  InvalidateImmediately
  DrainBeforeCleanup
}

/// Logical channel/connection closure reason.
pub type CloseReason {
  Normal
  Shutdown
  HeartbeatTimeout
  Fault(String)
}

/// Reply status before framing.
pub type Status {
  StatusOk
  StatusError
}

/// Codec-normalized inbound frames. Framing and rate limiting stay in the host.
pub type Decoded {
  Join(
    topic: String,
    payload: Dynamic,
    join_ref: Option(String),
    ref: Option(String),
  )
  Message(
    topic: String,
    event: String,
    payload: Dynamic,
    join_ref: Option(String),
    ref: Option(String),
  )
  Leave(topic: String, join_ref: Option(String), ref: Option(String))
  Heartbeat(ref: Option(String))
}

/// A transition input. Stale capabilities and completions are successful no-ops.
pub type Input {
  Receive(Decoded)
  AcceptJoin(operation: Operation, payload: Json, close_mode: CloseMode)
  RejectJoin(operation: Operation, payload: Json)
  CallbackFinished(operation: Operation)
  AdmissionFinished(operation: Operation, accepted: Bool)
  Reply(operation: Operation, status: Status, payload: Json)
  Discard(operation: Operation)
  Push(channel: Channel, event: String, payload: Json)
  BeginClose(channel: Channel, reason: CloseReason)
  /// Finish committed work and retain its final close outcome for cleanup.
  DrainFinished(operation: Operation, reason: CloseReason)
  CleanupFinished(operation: Operation)
  CheckDeadline
  Disconnect(reason: CloseReason)
}

/// Logical outbound messages, translated through the host's active codec.
pub type Outbound {
  ReplyMessage(
    join_ref: Option(String),
    ref: Option(String),
    topic: String,
    status: Status,
    payload: Json,
  )
  PushMessage(topic: String, event: String, payload: Json)
  TerminalMessage(join_ref: Option(String), topic: String, reason: CloseReason)
  HeartbeatReply(ref: Option(String))
}

/// Execute in order. Never bypass an admission or cleanup barrier on failure.
pub type Action {
  DeliverJoin(
    channel: Channel,
    operation: Operation,
    topic: String,
    payload: Dynamic,
  )
  AdmitJoin(channel: Channel, operation: Operation, topic: String)
  Joined(channel: Channel, topic: String)
  DeliverMessage(
    channel: Channel,
    topic: String,
    event: String,
    payload: Dynamic,
    operation: Option(Operation),
  )
  CloseChannel(
    channel: Channel,
    operation: Operation,
    topic: String,
    reason: CloseReason,
  )
  Send(Outbound)
  CloseConnection(reason: CloseReason)
  Deadline(deadline_ms: Option(Int))
}

/// A rejected transition commits no state or actions.
pub type Error {
  InvalidConfig
  InvalidIdentity
  InvalidClock
  CounterExhausted
  InvalidSnapshot
  UnsupportedVersion(Int)
  SnapshotTooLarge
}

/// Shared validation errors, translated by beryl's existing public helpers.
pub type ValidationError {
  EmptyTopic
  InvalidFormat(String)
}

// nolint: unused_exports -- host API used by BEAM and JavaScript adapters
/// Describe a rejected transition without application data.
pub fn describe_error(error: Error) -> String {
  case error {
    InvalidConfig -> "invalid protocol limits"
    InvalidIdentity -> "invalid connection epoch"
    InvalidClock -> "invalid or backward clock"
    CounterExhausted -> "protocol identity counter exhausted"
    InvalidSnapshot -> "invalid protocol snapshot"
    UnsupportedVersion(version) ->
      "unsupported snapshot version " <> int.to_string(version)
    SnapshotTooLarge -> "protocol snapshot exceeds attachment limit"
  }
}

type Phase {
  Authorizing(operation: Operation, ref: Option(String))
  Admitting(
    operation: Operation,
    ref: Option(String),
    payload: Json,
    close_mode: CloseMode,
  )
  Established(close_mode: CloseMode)
  Closing(
    operation: Operation,
    reason: CloseReason,
    close_mode: CloseMode,
    replacement: Option(Decoded),
  )
}

type Membership {
  Membership(
    channel: Channel,
    topic: String,
    join_ref: Option(String),
    phase: Phase,
  )
}

type PendingReply {
  PendingReply(channel: Channel, ref: String)
}

/// Per-connection protocol state. Contains no host resources or app models.
pub opaque type State {
  State(
    config: Config,
    connection: Connection,
    next_channel: Int,
    next_operation: Int,
    memberships: Dict(String, Membership),
    replies: Dict(Operation, PendingReply),
    last_heartbeat_ms: Int,
    closing: Option(CloseReason),
    closed: Bool,
  )
}

/// Default limits: 256 topic bytes, 64 event bytes, 1000 channels, 1024
/// pending application operations and a 60-second heartbeat timeout.
pub fn config() -> Config {
  Config(256, 64, 1000, 1024, 60_000, False)
}

/// Set finite limits. Pending operations include joins and deferred replies;
/// cleanup barriers are bounded separately by the channel limit.
pub fn with_limits(
  config: Config,
  max_topic_bytes max_topic_bytes: Int,
  max_event_bytes max_event_bytes: Int,
  max_channels max_channels: Int,
  max_pending max_pending: Int,
  heartbeat_timeout_ms heartbeat_timeout_ms: Int,
) -> Result(Config, Error) {
  use <- bool.guard(
    when: max_topic_bytes < 0
      || max_event_bytes < 0
      || max_channels < 1
      || max_pending < 1
      || heartbeat_timeout_ms < 1
      || !safe_integer(max_topic_bytes)
      || !safe_integer(max_event_bytes)
      || !safe_integer(max_channels)
      || !safe_integer(max_pending)
      || heartbeat_timeout_ms >= maximum_integer,
    return: Error(InvalidConfig),
  )
  Ok(
    Config(
      ..config,
      max_topic_bytes: max_topic_bytes,
      max_event_bytes: max_event_bytes,
      max_channels: max_channels,
      max_pending: max_pending,
      heartbeat_timeout_ms: heartbeat_timeout_ms,
    ),
  )
}

/// Enable topicless application events only when exactly one channel is joined.
pub fn with_topicless_events(config: Config, enabled: Bool) -> Config {
  Config(..config, topicless_events: enabled)
}

/// Start a connection. The host must issue a new unique epoch on reconnect.
pub fn new(config: Config, epoch: String, now_ms: Int) -> Result(State, Error) {
  use <- bool.guard(
    when: string.is_empty(epoch) || string.byte_size(epoch) > 256,
    return: Error(InvalidIdentity),
  )
  use <- bool.guard(
    when: !safe_deadline(now_ms, config.heartbeat_timeout_ms),
    return: Error(InvalidClock),
  )
  Ok(State(
    config: config,
    connection: Connection(epoch),
    next_channel: 1,
    next_operation: 1,
    memberships: dict.new(),
    replies: dict.new(),
    last_heartbeat_ms: now_ms,
    closing: None,
    closed: False,
  ))
}

/// Validate the syntax shared with beryl's public topic helper.
pub fn validate_topic(topic: String) -> Result(String, ValidationError) {
  use <- bool.guard(when: string.is_empty(topic), return: Error(EmptyTopic))
  use <- bool.guard(
    when: string.starts_with(topic, ":") || string.ends_with(topic, ":"),
    return: Error(InvalidFormat("topic cannot start or end with ':'")),
  )
  use <- bool.guard(
    when: has_control_characters(topic),
    return: Error(InvalidFormat("topic contains control characters")),
  )
  Ok(topic)
}

/// Validate pattern syntax without adding topic-only restrictions.
pub fn validate_pattern(pattern: String) -> Result(String, ValidationError) {
  use <- bool.guard(when: string.is_empty(pattern), return: Error(EmptyTopic))
  use <- bool.guard(
    when: has_control_characters(pattern),
    return: Error(InvalidFormat("pattern contains control characters")),
  )
  Ok(pattern)
}

/// Validate event syntax without adding protocol-only restrictions.
pub fn validate_event(event: String) -> Result(String, ValidationError) {
  use <- bool.guard(
    when: string.is_empty(event),
    return: Error(InvalidFormat("event name is empty")),
  )
  use <- bool.guard(
    when: has_control_characters(event),
    return: Error(InvalidFormat("event contains control characters")),
  )
  Ok(event)
}

/// Apply inbound topic byte and syntax limits.
pub fn valid_topic(config: Config, topic: String) -> Bool {
  topic_allowed(topic, config.max_topic_bytes)
}

// nolint: unused_exports -- host API used by beryl's existing configuration
/// Shared inbound topic check for hosts with existing configuration types.
pub fn topic_allowed(topic: String, max_bytes: Int) -> Bool {
  string.byte_size(topic) <= max_bytes && result.is_ok(validate_topic(topic))
}

// nolint: unused_exports -- host API used by beryl's decoded dispatch
/// Whether the topic is reserved for beryl's host machinery.
pub fn reserved_topic(topic: String) -> Bool {
  string.starts_with(topic, "beryl:")
}

/// Apply inbound application-event limits, including reserved `phx_` names.
pub fn valid_event(config: Config, event: String) -> Bool {
  event_allowed(event, config.max_event_bytes)
}

// nolint: unused_exports -- host API used by beryl's existing configuration
/// Shared inbound event check for hosts with existing configuration types.
pub fn event_allowed(event: String, max_bytes: Int) -> Bool {
  string.byte_size(event) <= max_bytes
  && !string.starts_with(event, "phx_")
  && result.is_ok(validate_event(event))
}

fn has_control_characters(value: String) -> Bool {
  value
  |> string.to_utf_codepoints
  |> list.any(fn(codepoint) {
    let code = string.utf_codepoint_to_int(codepoint)
    code < 32 || code == 127
  })
}

fn safe_integer(value: Int) -> Bool {
  value >= 0 - maximum_integer && value <= maximum_integer
}

fn safe_deadline(now_ms: Int, timeout_ms: Int) -> Bool {
  safe_integer(now_ms) && now_ms < maximum_integer - timeout_ms
}

// nolint: unused_exports -- host API for connection-scoped indexes
/// The connection identity, for host-owned indexes.
pub fn connection(state: State) -> Connection {
  state.connection
}

// nolint: unused_exports -- host API used by beryl's cleanup interpreter
/// The connection's teardown reason, once teardown begins.
pub fn close_reason(state: State) -> Option(CloseReason) {
  state.closing
}

/// The next required timer instant. Expiry is strictly after the timeout.
pub fn next_deadline(state: State) -> Option(Int) {
  case state.closing, state.closed {
    None, False ->
      Some(state.last_heartbeat_ms + state.config.heartbeat_timeout_ms + 1)
    Some(_), False | None, True | Some(_), True -> None
  }
}

/// Current established channel, excluding channels whose close has begun.
pub fn channel(state: State, topic: String) -> Result(Channel, Nil) {
  use membership <- result.try(dict.get(state.memberships, topic))
  case membership.phase {
    Established(_) -> Ok(membership.channel)
    Authorizing(..) | Admitting(..) | Closing(..) -> Error(Nil)
  }
}

// nolint: unused_exports -- host API for existing join-admission telemetry
/// Whether a new join can fit, accounting for same-topic replacement.
pub fn can_join(state: State, topic: String) -> Bool {
  dict.has_key(state.memberships, topic)
  || dict.size(state.memberships) < state.config.max_channels
}

/// Current channel's wire join reference. Missing references are not identities.
pub fn joined_ref(state: State, topic: String) -> Option(String) {
  case dict.get(state.memberships, topic) {
    Ok(Membership(phase: Established(_), join_ref:, ..)) -> join_ref
    Ok(Membership(phase: Authorizing(..), ..))
    | Ok(Membership(phase: Admitting(..), ..))
    | Ok(Membership(phase: Closing(..), ..))
    | Error(Nil) -> None
  }
}

// nolint: unused_exports -- host API used by beryl's cleanup interpreter
/// Wire reference for an instance, including one awaiting host cleanup.
pub fn instance_ref(state: State, topic: String) -> Option(String) {
  case dict.get(state.memberships, topic) {
    Ok(membership) -> membership.join_ref
    Error(Nil) -> None
  }
}

// nolint: unused_exports -- host API used by beryl's effect interpreter
/// A push-capable instance, including a draining worker.
pub fn push_channel(state: State, topic: String) -> Result(Channel, Nil) {
  use membership <- result.try(dict.get(state.memberships, topic))
  case can_push(state, membership.channel) {
    True -> Ok(membership.channel)
    False -> Error(Nil)
  }
}

/// Sorted established topics, used for host delivery-index reconstruction.
pub fn topics(state: State) -> List(String) {
  state.memberships
  |> dict.to_list
  |> list.filter_map(fn(entry) {
    case entry.1.phase {
      Established(_) -> Ok(entry.0)
      Authorizing(..) | Admitting(..) | Closing(..) -> Error(Nil)
    }
  })
  |> list.sort(string.compare)
}

// nolint: unused_exports -- host API used before per-channel rate admission
/// Resolve an opt-in topicless event without guessing between channels.
pub fn resolve_topic(state: State, requested: String) -> String {
  use <- bool.guard(
    when: requested != "" || !state.config.topicless_events,
    return: requested,
  )
  case topics(state) {
    [only] -> only
    [] | [_, _, ..] -> requested
  }
}

// nolint: unused_exports -- host API used before per-channel rate admission
/// Preserve Phoenix's omitted-reference behavior: only two differing supplied
/// references prove that a frame belongs to an old channel instance.
pub fn stale_join_ref(
  state: State,
  topic: String,
  sent: Option(String),
) -> Bool {
  case sent, joined_ref(state, topic) {
    Some(sent), Some(current) -> sent != current
    Some(_), None | None, Some(_) | None, None -> False
  }
}

// nolint: unused_exports -- host API for draining-worker delivery
/// Whether pushes/committed worker replies can still target this instance.
pub fn can_push(state: State, channel: Channel) -> Bool {
  state.memberships
  |> dict.values
  |> list.any(fn(membership) {
    membership.channel == channel
    && case membership.phase {
      Established(_) | Closing(close_mode: DrainBeforeCleanup, ..) -> True
      Authorizing(..)
      | Admitting(..)
      | Closing(close_mode: InvalidateImmediately, ..) -> False
    }
  })
}

// nolint: unused_exports -- host API used by beryl's callback wrapper
/// Retrieve the outstanding authorization handle for a host callback.
pub fn pending_join(
  state: State,
  topic: String,
) -> Result(#(Channel, Operation), Nil) {
  use membership <- result.try(dict.get(state.memberships, topic))
  case membership.phase {
    Authorizing(operation, _) -> Ok(#(membership.channel, operation))
    Admitting(..) | Established(_) | Closing(..) -> Error(Nil)
  }
}

// nolint: unused_exports -- host API for backwards-compatible BEAM handles
/// Wire metadata for a host's join-handle wrapper, never for capability lookup.
pub fn join_wire_key(
  state: State,
  operation: Operation,
) -> Result(#(String, Option(String), Option(String)), Nil) {
  use membership <- result.try(membership_for_channel(state, operation.channel))
  case membership.phase {
    Authorizing(pending, ref)
      | Admitting(pending, ref, _, _)
      if pending == operation
    -> Ok(#(membership.topic, membership.join_ref, ref))
    Authorizing(..) | Admitting(..) | Established(_) | Closing(..) -> Error(Nil)
  }
}

// nolint: unused_exports -- host API used by beryl's cleanup interpreter
/// Retrieve the current generation-scoped cleanup barrier.
pub fn pending_cleanup(state: State, topic: String) -> Result(Operation, Nil) {
  use membership <- result.try(dict.get(state.memberships, topic))
  case membership.phase {
    Closing(operation:, ..) -> Ok(operation)
    Authorizing(..) | Admitting(..) | Established(_) -> Error(Nil)
  }
}

/// Number of retained join/reply operations; host byte limits are independent.
pub fn pending_count(state: State) -> Int {
  let joins =
    state.memberships
    |> dict.values
    |> list.count(fn(membership) {
      case membership.phase {
        Authorizing(..) | Admitting(..) -> True
        Established(_) | Closing(..) -> False
      }
    })
  joins + dict.size(state.replies)
}

/// Whether a reply operation is still live.
pub fn reply_pending(state: State, operation: Operation) -> Bool {
  dict.has_key(state.replies, operation)
}

// nolint: unused_exports -- host API for backwards-compatible BEAM handles
/// Wire metadata for a host's backwards-compatible public handle wrapper.
/// These fields are not the operation's identity.
pub fn reply_wire_key(
  state: State,
  operation: Operation,
) -> Result(#(String, Option(String), Option(String)), Nil) {
  use reply <- result.try(dict.get(state.replies, operation))
  use membership <- result.map(membership_for_channel(state, reply.channel))
  #(membership.topic, membership.join_ref, Some(reply.ref))
}

/// Apply one input without clock reads, IO, global state, or host callbacks.
pub fn step(
  state: State,
  input: Input,
  now_ms: Int,
) -> Result(#(State, List(Action)), Error) {
  use <- bool.guard(
    when: !safe_deadline(now_ms, state.config.heartbeat_timeout_ms),
    return: Error(InvalidClock),
  )
  use <- bool.guard(when: state.closed, return: Ok(#(state, [])))
  use #(next, actions) <- result.map(transition(state, input, now_ms))
  #(next, list.append(actions, [Deadline(next_deadline(next))]))
}

fn transition(
  state: State,
  input: Input,
  now_ms: Int,
) -> Result(#(State, List(Action)), Error) {
  case input {
    Receive(decoded) ->
      case state.closing {
        Some(_) -> Ok(#(state, []))
        None -> receive(state, decoded, now_ms)
      }
    AcceptJoin(operation, payload, mode) ->
      answer_join(state, operation, payload, Some(mode))
    RejectJoin(operation, payload) ->
      answer_join(state, operation, payload, None)
    CallbackFinished(operation) ->
      answer_join(state, operation, reason("join not acknowledged"), None)
    AdmissionFinished(operation, accepted) ->
      finish_admission(state, operation, accepted)
    Reply(operation, status, payload) ->
      Ok(consume_reply(state, operation, Some(#(status, payload))))
    Discard(operation) -> Ok(consume_reply(state, operation, None))
    Push(channel, event, payload) -> {
      let actions = case
        membership_for_channel(state, channel),
        can_push(state, channel)
      {
        Ok(membership), True -> [
          Send(PushMessage(membership.topic, event, payload)),
        ]
        Ok(_), False | Error(Nil), _ -> []
      }
      Ok(#(state, actions))
    }
    BeginClose(channel, reason) ->
      case membership_for_channel(state, channel) {
        Ok(membership) -> begin_close(state, membership, reason, None)
        Error(Nil) -> Ok(#(state, []))
      }
    DrainFinished(operation, reason) ->
      Ok(finish_drain(state, operation, reason))
    CleanupFinished(operation) -> finish_cleanup(state, operation, now_ms)
    CheckDeadline ->
      case next_deadline(state) {
        Some(deadline) if now_ms >= deadline ->
          disconnect(state, HeartbeatTimeout)
        Some(_) | None -> Ok(#(state, []))
      }
    Disconnect(reason) -> disconnect(state, reason)
  }
}

fn receive(
  state: State,
  decoded: Decoded,
  now_ms: Int,
) -> Result(#(State, List(Action)), Error) {
  case decoded {
    Heartbeat(ref) -> {
      use <- bool.guard(
        when: now_ms < state.last_heartbeat_ms,
        return: Error(InvalidClock),
      )
      Ok(
        #(State(..state, last_heartbeat_ms: now_ms), [Send(HeartbeatReply(ref))]),
      )
    }
    Join(topic, payload, join_ref, ref) -> {
      use <- bool.guard(
        when: !valid_topic(state.config, topic) || reserved_topic(topic),
        return: Ok(
          #(state, [error_reply(join_ref, ref, topic, "invalid_topic")]),
        ),
      )
      case dict.get(state.memberships, topic) {
        Ok(membership) -> begin_close(state, membership, Normal, Some(decoded))
        Error(Nil) -> begin_join(state, topic, payload, join_ref, ref)
      }
    }
    Leave(topic, join_ref, ref) -> {
      use <- bool.guard(
        when: !valid_topic(state.config, topic)
          || stale_join_ref(state, topic, join_ref),
        return: Ok(#(state, [])),
      )
      let acknowledgment = case ref {
        Some(_) -> [
          Send(ReplyMessage(
            joined_ref(state, topic),
            ref,
            topic,
            StatusOk,
            json.object([]),
          )),
        ]
        None -> []
      }
      case dict.get(state.memberships, topic) {
        Error(Nil) -> Ok(#(state, acknowledgment))
        Ok(membership) -> {
          use #(next, actions) <- result.map(begin_close(
            state,
            membership,
            Normal,
            None,
          ))
          #(next, list.append(acknowledgment, actions))
        }
      }
    }
    Message(topic, event, payload, join_ref, ref) -> {
      receive_message(state, topic, event, payload, join_ref, ref)
    }
  }
}

fn receive_message(
  state: State,
  topic: String,
  event: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
) -> Result(#(State, List(Action)), Error) {
  let topic = resolve_topic(state, topic)
  use <- bool.guard(
    when: !valid_topic(state.config, topic) || !valid_event(state.config, event),
    return: Ok(#(state, [])),
  )
  case channel(state, topic) {
    Error(Nil) -> {
      let actions = case ref {
        Some(_) -> [error_reply(None, ref, topic, "unmatched topic")]
        None -> []
      }
      Ok(#(state, actions))
    }
    Ok(channel) -> {
      use <- bool.guard(
        when: stale_join_ref(state, topic, join_ref),
        return: Ok(#(state, [])),
      )
      begin_message(state, channel, topic, event, payload, ref)
    }
  }
}

fn begin_join(
  state: State,
  topic: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
) -> Result(#(State, List(Action)), Error) {
  use <- bool.guard(
    when: !can_join(state, topic),
    return: Ok(#(state, [error_reply(join_ref, ref, topic, "too_many_topics")])),
  )
  use <- bool.guard(
    when: pending_count(state) >= state.config.max_pending,
    return: disconnect(state, Fault("pending_capacity")),
  )
  use <- bool.guard(
    when: state.next_channel >= maximum_integer,
    return: Error(CounterExhausted),
  )
  let channel = Channel(state.connection, state.next_channel)
  use #(state, operation) <- result.map(allocate(state, channel))
  let membership =
    Membership(channel, topic, join_ref, Authorizing(operation, ref))
  #(
    State(
      ..state,
      next_channel: state.next_channel + 1,
      memberships: dict.insert(state.memberships, topic, membership),
    ),
    [DeliverJoin(channel, operation, topic, payload)],
  )
}

fn allocate(
  state: State,
  channel: Channel,
) -> Result(#(State, Operation), Error) {
  use <- bool.guard(
    when: state.next_operation >= maximum_integer,
    return: Error(CounterExhausted),
  )
  Ok(#(
    State(..state, next_operation: state.next_operation + 1),
    Operation(channel, state.next_operation),
  ))
}

fn membership_for_channel(
  state: State,
  channel: Channel,
) -> Result(Membership, Nil) {
  state.memberships
  |> dict.values
  |> list.find(fn(membership) { membership.channel == channel })
}

fn answer_join(
  state: State,
  operation: Operation,
  payload: Json,
  mode: Option(CloseMode),
) -> Result(#(State, List(Action)), Error) {
  case membership_for_channel(state, operation.channel) {
    Ok(Membership(phase: Authorizing(pending, ref), ..) as membership)
      if pending == operation
    ->
      case mode {
        None ->
          Ok(
            #(
              State(
                ..state,
                memberships: dict.delete(state.memberships, membership.topic),
              ),
              [
                Send(ReplyMessage(
                  membership.join_ref,
                  ref,
                  membership.topic,
                  StatusError,
                  payload,
                )),
              ],
            ),
          )
        Some(mode) -> {
          let membership =
            Membership(
              ..membership,
              phase: Admitting(operation, ref, payload, mode),
            )
          Ok(
            #(
              State(
                ..state,
                memberships: dict.insert(
                  state.memberships,
                  membership.topic,
                  membership,
                ),
              ),
              [AdmitJoin(membership.channel, operation, membership.topic)],
            ),
          )
        }
      }
    Ok(_) | Error(Nil) -> Ok(#(state, []))
  }
}

fn finish_admission(
  state: State,
  operation: Operation,
  accepted: Bool,
) -> Result(#(State, List(Action)), Error) {
  case membership_for_channel(state, operation.channel) {
    Ok(
      Membership(phase: Admitting(pending, ref, payload, mode), ..) as membership,
    )
      if pending == operation
    ->
      case accepted {
        False -> {
          let state =
            State(
              ..state,
              memberships: dict.delete(state.memberships, membership.topic),
            )
          disconnect(state, Fault("admission_rejected"))
        }
        True -> {
          let membership = Membership(..membership, phase: Established(mode))
          Ok(
            #(
              State(
                ..state,
                memberships: dict.insert(
                  state.memberships,
                  membership.topic,
                  membership,
                ),
              ),
              [
                Joined(membership.channel, membership.topic),
                Send(ReplyMessage(
                  membership.join_ref,
                  ref,
                  membership.topic,
                  StatusOk,
                  payload,
                )),
              ],
            ),
          )
        }
      }
    Ok(_) | Error(Nil) -> Ok(#(state, []))
  }
}

fn begin_message(
  state: State,
  channel: Channel,
  topic: String,
  event: String,
  payload: Dynamic,
  ref: Option(String),
) -> Result(#(State, List(Action)), Error) {
  case ref {
    None -> Ok(#(state, [DeliverMessage(channel, topic, event, payload, None)]))
    Some(ref) -> {
      let duplicate =
        state.replies
        |> dict.values
        |> list.any(fn(reply) { reply.channel == channel && reply.ref == ref })
      use <- bool.guard(
        when: duplicate,
        return: Ok(
          #(state, [
            error_reply(
              joined_ref(state, topic),
              Some(ref),
              topic,
              "duplicate_ref",
            ),
          ]),
        ),
      )
      use <- bool.guard(
        when: pending_count(state) >= state.config.max_pending,
        return: disconnect(state, Fault("pending_capacity")),
      )
      use #(state, operation) <- result.map(allocate(state, channel))
      #(
        State(
          ..state,
          replies: dict.insert(
            state.replies,
            operation,
            PendingReply(channel, ref),
          ),
        ),
        [DeliverMessage(channel, topic, event, payload, Some(operation))],
      )
    }
  }
}

fn consume_reply(
  state: State,
  operation: Operation,
  answer: Option(#(Status, Json)),
) -> #(State, List(Action)) {
  case dict.get(state.replies, operation) {
    Error(Nil) -> #(state, [])
    Ok(reply) -> {
      let actions = case answer, membership_for_channel(state, reply.channel) {
        Some(#(status, payload)), Ok(membership) -> [
          Send(ReplyMessage(
            membership.join_ref,
            Some(reply.ref),
            membership.topic,
            status,
            payload,
          )),
        ]
        None, Ok(_) | Some(_), Error(Nil) | None, Error(Nil) -> []
      }
      #(State(..state, replies: dict.delete(state.replies, operation)), actions)
    }
  }
}

fn begin_close(
  state: State,
  membership: Membership,
  reason: CloseReason,
  replacement: Option(Decoded),
) -> Result(#(State, List(Action)), Error) {
  case membership.phase {
    Closing(..) -> Ok(#(state, []))
    Authorizing(operation, _) | Admitting(operation, _, _, _) -> {
      use #(state, actions) <- result.try(reject_pending_for_close(
        state,
        membership,
        operation,
      ))
      case replacement {
        Some(Join(topic, payload, join_ref, ref)) -> {
          use #(state, next_actions) <- result.map(begin_join(
            state,
            topic,
            payload,
            join_ref,
            ref,
          ))
          #(state, list.append(actions, next_actions))
        }
        Some(Message(..)) | Some(Leave(..)) | Some(Heartbeat(_)) | None ->
          Ok(#(state, actions))
      }
    }
    Established(mode) -> {
      use #(state, operation) <- result.map(allocate(state, membership.channel))
      let membership =
        Membership(
          ..membership,
          phase: Closing(operation, reason, mode, replacement),
        )
      let state =
        State(
          ..state,
          memberships: dict.insert(
            state.memberships,
            membership.topic,
            membership,
          ),
        )
      let state = case mode {
        InvalidateImmediately -> drop_channel_replies(state, membership.channel)
        DrainBeforeCleanup -> state
      }
      #(state, [
        CloseChannel(membership.channel, operation, membership.topic, reason),
      ])
    }
  }
}

fn reject_pending_for_close(
  state: State,
  membership: Membership,
  operation: Operation,
) -> Result(#(State, List(Action)), Error) {
  case membership.phase {
    Authorizing(..) ->
      answer_join(state, operation, reason("join not acknowledged"), None)
    Admitting(_, ref, _, _) ->
      Ok(
        #(
          State(
            ..state,
            memberships: dict.delete(state.memberships, membership.topic),
          ),
          [
            error_reply(
              membership.join_ref,
              ref,
              membership.topic,
              "join not acknowledged",
            ),
          ],
        ),
      )
    Established(_) | Closing(..) -> Ok(#(state, []))
  }
}

fn drop_channel_replies(state: State, channel: Channel) -> State {
  State(
    ..state,
    replies: dict.filter(state.replies, fn(_, reply) {
      reply.channel != channel
    }),
  )
}

fn finish_drain(
  state: State,
  operation: Operation,
  reason: CloseReason,
) -> #(State, List(Action)) {
  case membership_for_channel(state, operation.channel) {
    Ok(Membership(phase: Closing(pending, _, _, replacement), ..) as membership)
      if pending == operation
    -> {
      let membership =
        Membership(
          ..membership,
          phase: Closing(pending, reason, InvalidateImmediately, replacement),
        )
      #(
        State(
          ..drop_channel_replies(state, membership.channel),
          memberships: dict.insert(
            state.memberships,
            membership.topic,
            membership,
          ),
        ),
        [],
      )
    }
    Ok(_) | Error(Nil) -> #(state, [])
  }
}

fn finish_cleanup(
  state: State,
  operation: Operation,
  now_ms: Int,
) -> Result(#(State, List(Action)), Error) {
  case membership_for_channel(state, operation.channel) {
    Ok(
      Membership(phase: Closing(pending, reason, _, replacement), ..) as membership,
    )
      if pending == operation
    -> {
      let state =
        State(
          ..drop_channel_replies(state, membership.channel),
          memberships: dict.delete(state.memberships, membership.topic),
        )
      let terminal =
        Send(TerminalMessage(membership.join_ref, membership.topic, reason))
      case state.closing, replacement {
        None, Some(decoded) -> {
          use #(state, actions) <- result.map(receive(state, decoded, now_ms))
          #(state, [terminal, ..actions])
        }
        None, None | Some(_), _ -> {
          let #(state, actions) = close_if_finished(state)
          Ok(#(state, [terminal, ..actions]))
        }
      }
    }
    Ok(_) | Error(Nil) -> Ok(#(state, []))
  }
}

fn disconnect(
  state: State,
  reason: CloseReason,
) -> Result(#(State, List(Action)), Error) {
  case state.closing {
    Some(_) -> Ok(#(state, []))
    None -> {
      let state = State(..state, closing: Some(reason))
      let memberships =
        state.memberships
        |> dict.to_list
        |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
      use #(state, actions) <- result.map(
        list.try_fold(memberships, #(state, []), fn(accumulator, entry) {
          use #(state, actions) <- result.map(begin_close(
            accumulator.0,
            entry.1,
            reason,
            None,
          ))
          #(state, list.append(accumulator.1, actions))
        }),
      )
      let #(state, final_actions) = close_if_finished(state)
      #(state, list.append(actions, final_actions))
    }
  }
}

fn close_if_finished(state: State) -> #(State, List(Action)) {
  case state.closing, dict.size(state.memberships) {
    Some(reason), 0 -> #(State(..state, closed: True), [CloseConnection(reason)])
    Some(_), _ | None, _ -> #(state, [])
  }
}

fn reason(text: String) -> Json {
  json.object([#("reason", json.string(text))])
}

fn error_reply(
  join_ref: Option(String),
  ref: Option(String),
  topic: String,
  text: String,
) -> Action {
  Send(ReplyMessage(join_ref, ref, topic, StatusError, reason(text)))
}

type ExportedMembership {
  ExportedMembership(
    generation: Int,
    topic: String,
    join_ref: Option(String),
    phase: String,
    mode: String,
    operation: Option(Int),
    ref: Option(String),
    replacement: Bool,
  )
}

type ExportedReply {
  ExportedReply(generation: Int, operation: Int, ref: String)
}

type ExportedState {
  ExportedState(
    version: Int,
    config: Config,
    epoch: String,
    next_channel: Int,
    next_operation: Int,
    heartbeat_remaining_ms: Int,
    memberships: List(ExportedMembership),
    replies: List(ExportedReply),
    closing: Option(String),
    closed: Bool,
  )
}

/// Export bounded version-1 JSON, without callbacks, application payloads or
/// clock-origin timestamps. Save a trusted wall-clock checkpoint beside this
/// string in the host attachment envelope.
pub fn export(state: State, now_ms: Int) -> Result(String, Error) {
  use <- bool.guard(
    when: !safe_deadline(now_ms, state.config.heartbeat_timeout_ms)
      || now_ms < state.last_heartbeat_ms,
    return: Error(InvalidClock),
  )
  let deadline = state.last_heartbeat_ms + state.config.heartbeat_timeout_ms + 1
  let remaining = case now_ms >= deadline {
    True -> 0
    False -> deadline - now_ms
  }
  let encoded =
    json.object([
      #("version", json.int(1)),
      #("config", encode_config(state.config)),
      #("epoch", json.string(state.connection.epoch)),
      #("next_channel", json.int(state.next_channel)),
      #("next_operation", json.int(state.next_operation)),
      #("heartbeat_remaining_ms", json.int(remaining)),
      #(
        "memberships",
        state.memberships
          |> dict.values
          |> list.sort(fn(left, right) {
            string.compare(left.topic, right.topic)
          })
          |> json.array(encode_membership),
      ),
      #(
        "replies",
        state.replies
          |> dict.to_list
          |> list.sort(fn(left, right) {
            int.compare(left.0.sequence, right.0.sequence)
          })
          |> json.array(fn(entry) {
            json.object([
              #("generation", json.int(entry.1.channel.generation)),
              #("operation", json.int(entry.0.sequence)),
              #("ref", json.string(entry.1.ref)),
            ])
          }),
      ),
      #("closing", encode_optional(option.map(state.closing, encode_reason))),
      #("closed", json.bool(state.closed)),
    ])
    |> json.to_string
  use <- bool.guard(
    when: string.byte_size(encoded) > maximum_snapshot_bytes,
    return: Error(SnapshotTooLarge),
  )
  Ok(encoded)
}

fn encode_config(config: Config) -> Json {
  json.object([
    #("max_topic_bytes", json.int(config.max_topic_bytes)),
    #("max_event_bytes", json.int(config.max_event_bytes)),
    #("max_channels", json.int(config.max_channels)),
    #("max_pending", json.int(config.max_pending)),
    #("heartbeat_timeout_ms", json.int(config.heartbeat_timeout_ms)),
    #("topicless_events", json.bool(config.topicless_events)),
  ])
}

fn encode_mode(mode: CloseMode) -> String {
  case mode {
    InvalidateImmediately -> "immediate"
    DrainBeforeCleanup -> "drain"
  }
}

fn encode_reason(reason: CloseReason) -> String {
  case reason {
    Normal -> "normal"
    Shutdown -> "shutdown"
    HeartbeatTimeout -> "heartbeat_timeout"
    Fault(text) -> "fault:" <> text
  }
}

fn encode_optional(value: Option(String)) -> Json {
  case value {
    Some(value) -> json.string(value)
    None -> json.null()
  }
}

fn encode_membership(membership: Membership) -> Json {
  let #(phase, mode, operation, ref, replacement) = case membership.phase {
    Authorizing(operation, ref) -> #(
      "authorizing",
      "immediate",
      Some(operation.sequence),
      ref,
      False,
    )
    Admitting(operation, ref, _, mode) -> #(
      "admitting",
      encode_mode(mode),
      Some(operation.sequence),
      ref,
      False,
    )
    Established(mode) -> #("established", encode_mode(mode), None, None, False)
    Closing(operation, _, mode, replacement) -> #(
      "closing",
      encode_mode(mode),
      Some(operation.sequence),
      None,
      option.is_some(replacement),
    )
  }
  json.object([
    #("generation", json.int(membership.channel.generation)),
    #("topic", json.string(membership.topic)),
    #("join_ref", encode_optional(membership.join_ref)),
    #("phase", json.string(phase)),
    #("mode", json.string(mode)),
    #("operation", case operation {
      Some(sequence) -> json.int(sequence)
      None -> json.null()
    }),
    #("ref", encode_optional(ref)),
    #("replacement", json.bool(replacement)),
  ])
}

fn config_decoder() -> decode.Decoder(Config) {
  use topic <- decode.field("max_topic_bytes", decode.int)
  use event <- decode.field("max_event_bytes", decode.int)
  use channels <- decode.field("max_channels", decode.int)
  use pending <- decode.field("max_pending", decode.int)
  use heartbeat <- decode.field("heartbeat_timeout_ms", decode.int)
  use topicless <- decode.field("topicless_events", decode.bool)
  decode.success(Config(topic, event, channels, pending, heartbeat, topicless))
}

fn membership_decoder() -> decode.Decoder(ExportedMembership) {
  use generation <- decode.field("generation", decode.int)
  use topic <- decode.field("topic", decode.string)
  use join_ref <- decode.field("join_ref", decode.optional(decode.string))
  use phase <- decode.field("phase", decode.string)
  use mode <- decode.field("mode", decode.string)
  use operation <- decode.field("operation", decode.optional(decode.int))
  use ref <- decode.field("ref", decode.optional(decode.string))
  use replacement <- decode.field("replacement", decode.bool)
  decode.success(ExportedMembership(
    generation,
    topic,
    join_ref,
    phase,
    mode,
    operation,
    ref,
    replacement,
  ))
}

fn reply_decoder() -> decode.Decoder(ExportedReply) {
  use generation <- decode.field("generation", decode.int)
  use operation <- decode.field("operation", decode.int)
  use ref <- decode.field("ref", decode.string)
  decode.success(ExportedReply(generation, operation, ref))
}

fn state_decoder() -> decode.Decoder(ExportedState) {
  use version <- decode.field("version", decode.int)
  use config <- decode.field("config", config_decoder())
  use epoch <- decode.field("epoch", decode.string)
  use next_channel <- decode.field("next_channel", decode.int)
  use next_operation <- decode.field("next_operation", decode.int)
  use remaining <- decode.field("heartbeat_remaining_ms", decode.int)
  use memberships <- decode.field(
    "memberships",
    decode.list(membership_decoder()),
  )
  use replies <- decode.field("replies", decode.list(reply_decoder()))
  use closing <- decode.field("closing", decode.optional(decode.string))
  use closed <- decode.field("closed", decode.bool)
  decode.success(ExportedState(
    version,
    config,
    epoch,
    next_channel,
    next_operation,
    remaining,
    memberships,
    replies,
    closing,
    closed,
  ))
}

/// Restore using elapsed wall-clock milliseconds validated by the host. A
/// backward or unavailable wall clock must close/reconnect, not resume.
///
/// Established channels without lost work retain their generation. Channels
/// with unrecoverable authorization, replies or cleanup are invalidated and
/// receive `phx_error`, requiring fresh authorization on rejoin. Counters never
/// rewind. Rehydrate host authority before delivering another command.
pub fn restore(
  snapshot: String,
  elapsed_ms: Int,
  now_ms: Int,
) -> Result(#(State, List(Action)), Error) {
  use <- bool.guard(
    when: string.byte_size(snapshot) > maximum_snapshot_bytes,
    return: Error(SnapshotTooLarge),
  )
  use <- bool.guard(
    when: elapsed_ms < 0 || !safe_integer(elapsed_ms),
    return: Error(InvalidClock),
  )
  use exported <- result.try(
    json.parse(snapshot, state_decoder())
    |> result.replace_error(InvalidSnapshot),
  )
  use <- bool.guard(
    when: exported.version != 1,
    return: Error(UnsupportedVersion(exported.version)),
  )
  use _ <- result.try(validate_export(exported))
  use initial <- result.try(new(exported.config, exported.epoch, now_ms))
  let remaining = case elapsed_ms >= exported.heartbeat_remaining_ms {
    True -> 0
    False -> exported.heartbeat_remaining_ms - elapsed_ms
  }
  let last_heartbeat_ms =
    now_ms - { exported.config.heartbeat_timeout_ms + 1 - remaining }
  use <- bool.guard(
    when: !safe_integer(last_heartbeat_ms),
    return: Error(InvalidClock),
  )
  let #(memberships, lost_actions) =
    exported.memberships
    |> list.sort(fn(left, right) { string.compare(left.topic, right.topic) })
    |> list.fold(#(dict.new(), []), fn(accumulator, item) {
      let channel = Channel(initial.connection, item.generation)
      let lost =
        item.phase != "established"
        || list.any(exported.replies, fn(reply) {
          reply.generation == item.generation
        })
      case lost {
        True -> #(accumulator.0, [
          Send(TerminalMessage(item.join_ref, item.topic, Fault("work_lost"))),
          ..accumulator.1
        ])
        False -> {
          let mode = case item.mode {
            "drain" -> DrainBeforeCleanup
            _ -> InvalidateImmediately
          }
          #(
            dict.insert(
              accumulator.0,
              item.topic,
              Membership(channel, item.topic, item.join_ref, Established(mode)),
            ),
            accumulator.1,
          )
        }
      }
    })
  let state =
    State(
      ..initial,
      next_channel: exported.next_channel,
      next_operation: exported.next_operation,
      last_heartbeat_ms: last_heartbeat_ms,
      memberships: memberships,
      closed: exported.closed,
    )
  let restored = case exported.closed, exported.closing {
    True, Some(reason) -> {
      use reason <- result.map(decode_reason(reason))
      #(state, [CloseConnection(reason), Deadline(None)])
    }
    True, None -> Error(InvalidSnapshot)
    False, closing -> {
      let input = case closing {
        Some(_) -> Disconnect(Fault("restore_during_close"))
        None -> CheckDeadline
      }
      step(state, input, now_ms)
    }
  }
  use #(state, actions) <- result.map(restored)
  #(state, list.append(list.reverse(lost_actions), actions))
}

fn validate_export(exported: ExportedState) -> Result(Nil, Error) {
  let config = exported.config
  use _ <- result.try(with_limits(
    config,
    max_topic_bytes: config.max_topic_bytes,
    max_event_bytes: config.max_event_bytes,
    max_channels: config.max_channels,
    max_pending: config.max_pending,
    heartbeat_timeout_ms: config.heartbeat_timeout_ms,
  ))
  use <- bool.guard(
    when: exported.next_channel < 1
      || exported.next_operation < 1
      || !safe_integer(exported.next_channel)
      || !safe_integer(exported.next_operation)
      || exported.next_operation < exported.next_channel
      || exported.heartbeat_remaining_ms < 0
      || !safe_integer(exported.heartbeat_remaining_ms)
      || exported.heartbeat_remaining_ms > config.heartbeat_timeout_ms + 1
      || list.length(exported.memberships) > config.max_channels
      || list.length(exported.replies) > config.max_pending
      || { exported.closed && exported.memberships != [] }
      || { exported.closed && exported.closing == None }
      || {
      !exported.closed && exported.closing != None && exported.memberships == []
    },
    return: Error(InvalidSnapshot),
  )
  use _ <- result.try(case exported.closing {
    None -> Ok(Normal)
    Some(reason) -> decode_reason(reason)
  })
  use _ <- result.try(
    list.try_fold(
      exported.memberships,
      #(dict.new(), dict.new(), dict.new(), 0),
      fn(seen, item) {
        use <- bool.guard(
          when: item.generation < 1
            || item.generation >= exported.next_channel
            || !valid_topic(config, item.topic)
            || reserved_topic(item.topic)
            || dict.has_key(seen.0, item.topic)
            || dict.has_key(seen.1, item.generation)
            || { item.mode != "immediate" && item.mode != "drain" }
            || { exported.closing != None && item.phase != "closing" },
          return: Error(InvalidSnapshot),
        )
        use sequences <- result.try(validate_exported_phase(
          item,
          exported.next_operation,
          seen.2,
        ))
        let pending =
          seen.3
          + case item.phase {
            "authorizing" | "admitting" -> 1
            _ -> 0
          }
        use <- bool.guard(
          when: pending + list.length(exported.replies) > config.max_pending,
          return: Error(InvalidSnapshot),
        )
        Ok(#(
          dict.insert(seen.0, item.topic, Nil),
          dict.insert(seen.1, item.generation, Nil),
          sequences,
          pending,
        ))
      },
    ),
  )
  let reserved_operations =
    exported.memberships
    |> list.filter_map(fn(item) {
      case item.operation {
        Some(sequence) -> Ok(#(sequence, Nil))
        None -> Error(Nil)
      }
    })
    |> dict.from_list
  use _ <- result.map(
    list.try_fold(
      exported.replies,
      #(reserved_operations, dict.new()),
      fn(seen, reply) {
        let membership =
          list.find(exported.memberships, fn(item) {
            item.generation == reply.generation
          })
        let compatible = case membership {
          Ok(item) ->
            item.phase == "established"
            || { item.phase == "closing" && item.mode == "drain" }
          Error(Nil) -> False
        }
        use <- bool.guard(
          when: !compatible
            || reply.operation < 1
            || reply.operation >= exported.next_operation
            || dict.has_key(seen.0, reply.operation)
            || dict.has_key(seen.1, #(reply.generation, reply.ref)),
          return: Error(InvalidSnapshot),
        )
        Ok(#(
          dict.insert(seen.0, reply.operation, Nil),
          dict.insert(seen.1, #(reply.generation, reply.ref), Nil),
        ))
      },
    ),
  )
  Nil
}

fn decode_reason(reason: String) -> Result(CloseReason, Error) {
  case reason {
    "normal" -> Ok(Normal)
    "shutdown" -> Ok(Shutdown)
    "heartbeat_timeout" -> Ok(HeartbeatTimeout)
    "fault:" <> text -> Ok(Fault(text))
    _ -> Error(InvalidSnapshot)
  }
}

fn validate_exported_phase(
  item: ExportedMembership,
  next_operation: Int,
  seen: Dict(Int, Nil),
) -> Result(Dict(Int, Nil), Error) {
  case item.phase, item.operation {
    "established", None if !item.replacement && item.ref == None -> Ok(seen)
    "authorizing", Some(sequence)
    | "admitting", Some(sequence)
    | "closing", Some(sequence)
    -> {
      use <- bool.guard(
        when: sequence < 1
          || sequence >= next_operation
          || dict.has_key(seen, sequence)
          || { item.phase != "closing" && item.replacement }
          || { item.phase == "closing" && item.ref != None },
        return: Error(InvalidSnapshot),
      )
      Ok(dict.insert(seen, sequence, Nil))
    }
    _, _ -> Error(InvalidSnapshot)
  }
}
