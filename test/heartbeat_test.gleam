import beryl/channel
import beryl/coordinator
import beryl/topic
import gleam/dynamic
import gleam/erlang/process
import gleam/json
import gleam/option.{None}
import gleam/string
import gleeunit/should

/// Helper: start a coordinator with a very short heartbeat check interval
fn start_coordinator_with_heartbeat(
  check_interval_ms: Int,
  timeout_ms: Int,
) -> process.Subject(coordinator.Message) {
  let config =
    coordinator.CoordinatorConfig(
      heartbeat_check_interval_ms: check_interval_ms,
      heartbeat_timeout_ms: timeout_ms,
    )
  let assert Ok(coord) = coordinator.start_with_config(config)
  coord
}

/// Helper: connect a mock socket and return a subject that captures sent messages
fn connect_mock_socket(
  coord: process.Subject(coordinator.Message),
  socket_id: String,
) -> process.Subject(String) {
  let sent_messages = process.new_subject()
  let send_fn = fn(msg: String) -> Result(Nil, Nil) {
    process.send(sent_messages, msg)
    Ok(Nil)
  }
  process.send(
    coord,
    coordinator.SocketConnected(socket_id, send_fn, dynamic.nil()),
  )
  // Small sleep to let the coordinator process the message
  process.sleep(10)
  sent_messages
}

/// Helper: query whether a socket is still connected by sending a heartbeat
/// and checking for a reply
fn socket_is_connected(
  coord: process.Subject(coordinator.Message),
  socket_id: String,
  sent_messages: process.Subject(String),
) -> Bool {
  // Drain any pending messages first
  drain(sent_messages)
  process.send(coord, coordinator.Heartbeat(socket_id, "probe"))
  case process.receive(sent_messages, 50) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Drain all pending messages from a subject
fn drain(subject: process.Subject(String)) -> Nil {
  case process.receive(subject, 0) {
    Ok(_) -> drain(subject)
    Error(_) -> Nil
  }
}

pub fn heartbeat_timeout_evicts_stale_socket_test() {
  let coord = start_coordinator_with_heartbeat(25, 50)
  let sent = connect_mock_socket(coord, "socket-1")

  // Socket should be connected initially
  socket_is_connected(coord, "socket-1", sent)
  |> should.be_true

  // Wait long enough for the timeout to fire (> 50ms timeout + 25ms check)
  process.sleep(120)

  // Socket should be evicted now
  socket_is_connected(coord, "socket-1", sent)
  |> should.be_false
}

pub fn heartbeat_resets_timeout_test() {
  let coord = start_coordinator_with_heartbeat(30, 100)
  let sent = connect_mock_socket(coord, "socket-1")

  // Send heartbeats to keep the socket alive
  process.send(coord, coordinator.Heartbeat("socket-1", "hb-1"))
  process.sleep(50)

  process.send(coord, coordinator.Heartbeat("socket-1", "hb-2"))
  process.sleep(50)

  process.send(coord, coordinator.Heartbeat("socket-1", "hb-3"))
  process.sleep(50)

  // After 150ms total, the socket should still be alive because we kept
  // sending heartbeats within the 100ms timeout window
  socket_is_connected(coord, "socket-1", sent)
  |> should.be_true
}

pub fn heartbeat_timeout_only_evicts_stale_sockets_test() {
  let coord = start_coordinator_with_heartbeat(20, 80)
  let sent_active = connect_mock_socket(coord, "active-socket")
  let sent_stale = connect_mock_socket(coord, "stale-socket")

  // Keep only "active-socket" alive with heartbeats
  process.sleep(40)
  process.send(coord, coordinator.Heartbeat("active-socket", "hb-1"))
  process.sleep(40)
  process.send(coord, coordinator.Heartbeat("active-socket", "hb-2"))

  // Wait for the stale socket to be evicted
  process.sleep(60)

  // Active socket should still be connected
  socket_is_connected(coord, "active-socket", sent_active)
  |> should.be_true

  // Stale socket should be evicted
  socket_is_connected(coord, "stale-socket", sent_stale)
  |> should.be_false
}

pub fn periodic_check_runs_repeatedly_test() {
  let coord = start_coordinator_with_heartbeat(15, 40)

  // Connect first socket and let it time out
  let sent1 = connect_mock_socket(coord, "first-socket")
  process.sleep(80)

  socket_is_connected(coord, "first-socket", sent1)
  |> should.be_false

  // Connect second socket - the check timer should still be running
  let sent2 = connect_mock_socket(coord, "second-socket")

  socket_is_connected(coord, "second-socket", sent2)
  |> should.be_true

  // Wait for it to time out too
  process.sleep(80)

  socket_is_connected(coord, "second-socket", sent2)
  |> should.be_false
}

pub fn no_heartbeat_check_when_interval_is_zero_test() {
  let coord = start_coordinator_with_heartbeat(0, 50)
  let sent = connect_mock_socket(coord, "socket-1")

  // Even after waiting well beyond the timeout, the socket stays connected
  // because the check timer is never scheduled
  process.sleep(150)

  socket_is_connected(coord, "socket-1", sent)
  |> should.be_true
}

pub fn socket_connected_initializes_heartbeat_timestamp_test() {
  let coord = start_coordinator_with_heartbeat(20, 100)
  let sent = connect_mock_socket(coord, "socket-1")

  // After 60ms (within 100ms timeout), socket should still be alive
  process.sleep(60)

  socket_is_connected(coord, "socket-1", sent)
  |> should.be_true
}

pub fn manual_check_heartbeats_evicts_stale_test() {
  // No automatic checking (interval=0) but manually trigger CheckHeartbeats
  let coord = start_coordinator_with_heartbeat(0, 50)
  let sent = connect_mock_socket(coord, "socket-1")

  // Wait past the timeout
  process.sleep(80)

  // Manually send CheckHeartbeats to evict the stale socket
  process.send(coord, coordinator.CheckHeartbeats)
  process.sleep(20)

  // Now it should be evicted
  socket_is_connected(coord, "socket-1", sent)
  |> should.be_false
}

pub fn default_coordinator_start_works_test() {
  let assert Ok(coord) = coordinator.start()

  let sent = connect_mock_socket(coord, "socket-1")
  socket_is_connected(coord, "socket-1", sent)
  |> should.be_true
}

pub fn heartbeat_reply_still_sent_test() {
  let coord = start_coordinator_with_heartbeat(0, 60_000)
  let sent = connect_mock_socket(coord, "socket-1")

  process.send(coord, coordinator.Heartbeat("socket-1", "hb-ref-42"))

  let assert Ok(reply) = process.receive(sent, 100)
  string.contains(reply, "phx_reply")
  |> should.be_true
  string.contains(reply, "hb-ref-42")
  |> should.be_true
}

pub fn zero_timeout_with_checking_enabled_returns_error_test() {
  let config =
    coordinator.CoordinatorConfig(
      heartbeat_check_interval_ms: 50,
      heartbeat_timeout_ms: 0,
    )
  coordinator.start_with_config(config)
  |> should.be_error
  |> should.equal(coordinator.InvalidHeartbeatTimeout)
}

pub fn negative_timeout_with_checking_enabled_returns_error_test() {
  let config =
    coordinator.CoordinatorConfig(
      heartbeat_check_interval_ms: 50,
      heartbeat_timeout_ms: -1,
    )
  coordinator.start_with_config(config)
  |> should.be_error
  |> should.equal(coordinator.InvalidHeartbeatTimeout)
}

pub fn zero_timeout_with_checking_disabled_is_ok_test() {
  let config =
    coordinator.CoordinatorConfig(
      heartbeat_check_interval_ms: 0,
      heartbeat_timeout_ms: 0,
    )
  coordinator.start_with_config(config)
  |> should.be_ok
}

pub fn positive_timeout_with_checking_enabled_is_ok_test() {
  let config =
    coordinator.CoordinatorConfig(
      heartbeat_check_interval_ms: 50,
      heartbeat_timeout_ms: 5000,
    )
  coordinator.start_with_config(config)
  |> should.be_ok
}

/// Helper: register a channel handler that sends terminate reason to a subject
fn register_handler_with_terminate(
  coord: process.Subject(coordinator.Message),
  pattern: String,
  terminate_subject: process.Subject(channel.StopReason),
) -> Nil {
  let handler =
    coordinator.ChannelHandler(
      pattern: topic.parse_pattern(pattern),
      join: fn(_topic, _payload, _ctx) {
        coordinator.JoinOkErased(reply: None, assigns: dynamic.nil())
      },
      handle_in: fn(_event, _payload, ctx) {
        coordinator.NoReplyErased(assigns: ctx.assigns)
      },
      terminate: fn(reason, _ctx) { process.send(terminate_subject, reason) },
    )

  let reply_subject = process.new_subject()
  process.send(
    coord,
    coordinator.RegisterChannel(pattern, handler, reply_subject),
  )
  let assert Ok(Ok(Nil)) = process.receive(reply_subject, 500)
  Nil
}

/// Helper: join a socket to a topic and wait for the reply
fn join_topic(
  coord: process.Subject(coordinator.Message),
  socket_id: String,
  topic_name: String,
  sent_messages: process.Subject(String),
) -> Nil {
  process.send(
    coord,
    coordinator.Join(socket_id, topic_name, dynamic.nil(), None, "join-ref"),
  )
  // Wait for the join reply
  let assert Ok(reply) = process.receive(sent_messages, 200)
  string.contains(reply, "phx_reply")
  |> should.be_true
}

pub fn terminate_callback_called_on_heartbeat_eviction_test() {
  let coord = start_coordinator_with_heartbeat(25, 50)

  // Register a handler that captures terminate reason
  let terminate_reasons = process.new_subject()
  register_handler_with_terminate(coord, "room:*", terminate_reasons)

  // Connect socket and join a topic
  let sent = connect_mock_socket(coord, "socket-t1")
  join_topic(coord, "socket-t1", "room:lobby", sent)

  // Wait for heartbeat timeout to evict the socket
  process.sleep(120)

  // Verify terminate was called with HeartbeatTimeout
  let assert Ok(reason) = process.receive(terminate_reasons, 200)
  reason |> should.equal(channel.HeartbeatTimeout)
}

pub fn topic_cleanup_after_heartbeat_eviction_test() {
  // Use longer timeout to give more margin for heartbeat timing
  let coord = start_coordinator_with_heartbeat(40, 150)

  // Register a handler for the topic
  let terminate_reasons = process.new_subject()
  register_handler_with_terminate(coord, "room:*", terminate_reasons)

  // Connect two sockets and join them to the same topic
  let sent_stale = connect_mock_socket(coord, "socket-stale")
  join_topic(coord, "socket-stale", "room:lobby", sent_stale)

  let sent_active = connect_mock_socket(coord, "socket-active")
  join_topic(coord, "socket-active", "room:lobby", sent_active)

  // Keep active socket alive while stale one times out
  process.sleep(60)
  process.send(coord, coordinator.Heartbeat("socket-active", "hb-1"))
  process.sleep(60)
  process.send(coord, coordinator.Heartbeat("socket-active", "hb-2"))
  process.sleep(60)
  process.send(coord, coordinator.Heartbeat("socket-active", "hb-3"))

  // Wait for stale socket eviction (stale hasn't sent heartbeats for 180ms+ > 150ms timeout)
  process.sleep(60)

  // Stale socket should be evicted
  socket_is_connected(coord, "socket-stale", sent_stale)
  |> should.be_false

  // Active socket still connected
  socket_is_connected(coord, "socket-active", sent_active)
  |> should.be_true

  // Drain any pending messages from both sockets
  drain(sent_stale)
  drain(sent_active)

  // Broadcast to the topic - only active socket should receive it
  process.send(
    coord,
    coordinator.Broadcast(
      "room:lobby",
      "test_event",
      json.object([#("msg", json.string("hello"))]),
      None,
    ),
  )

  // Active socket should receive the broadcast
  let assert Ok(msg) = process.receive(sent_active, 200)
  string.contains(msg, "test_event")
  |> should.be_true

  // Stale socket should NOT receive the broadcast (no phantom delivery)
  case process.receive(sent_stale, 100) {
    Ok(_) -> should.fail()
    Error(_) -> Nil
  }
}
