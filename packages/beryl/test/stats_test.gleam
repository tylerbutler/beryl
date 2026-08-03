import beryl
import beryl/channel
import beryl/coordinator
import beryl/internal/unsupervised
import beryl/stats
import beryl/telemetry
import beryl/wire
import beryl/wire/codec
import gleam/dynamic
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should

fn connect(
  channels: beryl.Channels,
  socket_id: String,
  sent: process.Subject(String),
) -> Nil {
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      socket_id,
      fn(text) {
        process.send(sent, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      None,
      dynamic.nil(),
    ),
  )
}

fn inbound(
  topic: String,
  kind: codec.InboundKind,
  ref: String,
) -> codec.Inbound {
  codec.inbound(
    join_ref: Some("join-" <> ref),
    ref: Some(ref),
    topic: topic,
    kind: kind,
    payload: dynamic.nil(),
  )
}

fn read_snapshot(channels: beryl.Channels) -> stats.Snapshot {
  let assert Ok(snapshot) = stats.snapshot(channels)
  snapshot
}

pub fn snapshot_tracks_registration_and_socket_lifecycle_test() {
  let assert Ok(channels) =
    unsupervised.start(beryl.config(wire.phoenix_codec()))
  let coordinator_subject = beryl.coordinator_subject(channels)
  let sent = process.new_subject()

  let initial = read_snapshot(channels)
  stats.connected_sockets(initial) |> should.equal(0)
  stats.joined_socket_topic_pairs(initial) |> should.equal(0)
  stats.active_topics(initial) |> should.equal(0)
  stats.registered_channel_handlers(initial) |> should.equal(0)
  should.be_true(stats.coordinator_mailbox_length(initial) >= 0)

  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let assert Ok(_) = beryl.register(channels, "room:*", handler)
  let assert Ok(_) = beryl.register(channels, "chat:*", handler)

  connect(channels, "socket-1", sent)
  connect(channels, "socket-2", sent)
  coordinator.route_decoded(
    coordinator_subject,
    "socket-1",
    inbound("room:a", codec.Join, "1"),
  )
  coordinator.route_decoded(
    coordinator_subject,
    "socket-1",
    inbound("room:b", codec.Join, "2"),
  )
  coordinator.route_decoded(
    coordinator_subject,
    "socket-2",
    inbound("room:a", codec.Join, "3"),
  )

  // Drain only the three exact socket replies created above.
  let assert Ok(_) = process.receive(sent, 500)
  let assert Ok(_) = process.receive(sent, 500)
  let assert Ok(_) = process.receive(sent, 500)

  let joined = read_snapshot(channels)
  stats.connected_sockets(joined) |> should.equal(2)
  stats.joined_socket_topic_pairs(joined) |> should.equal(3)
  stats.active_topics(joined) |> should.equal(2)
  stats.registered_channel_handlers(joined) |> should.equal(2)

  coordinator.route_decoded(
    coordinator_subject,
    "socket-1",
    inbound("room:a", codec.Leave, "1"),
  )
  // Leave sends one reply followed by one terminal frame.
  let assert Ok(_) = process.receive(sent, 500)
  let assert Ok(_) = process.receive(sent, 500)
  let after_leave = read_snapshot(channels)
  stats.joined_socket_topic_pairs(after_leave) |> should.equal(2)
  stats.active_topics(after_leave) |> should.equal(2)

  process.send(coordinator_subject, coordinator.SocketDisconnected("socket-2"))
  let assert Ok(_) = process.receive(sent, 500)
  let after_disconnect = read_snapshot(channels)
  stats.connected_sockets(after_disconnect) |> should.equal(1)
  stats.joined_socket_topic_pairs(after_disconnect) |> should.equal(1)
  stats.active_topics(after_disconnect) |> should.equal(1)

  coordinator.route_decoded(
    coordinator_subject,
    "socket-1",
    inbound("room:b", codec.Leave, "2"),
  )
  let assert Ok(_) = process.receive(sent, 500)
  let assert Ok(_) = process.receive(sent, 500)
  let after_final_leave = read_snapshot(channels)
  stats.joined_socket_topic_pairs(after_final_leave) |> should.equal(0)
  stats.active_topics(after_final_leave) |> should.equal(0)

  process.send(coordinator_subject, coordinator.SocketDisconnected("socket-1"))
  stats.connected_sockets(read_snapshot(channels)) |> should.equal(0)
  unsupervised.stop(channels)
}

pub fn snapshot_reports_coordinator_mailbox_at_service_time_test() {
  let assert Ok(channels) =
    unsupervised.start(beryl.config(wire.phoenix_codec()))
  let coordinator_subject = beryl.coordinator_subject(channels)
  let sent = process.new_subject()
  let callback_entered = process.new_subject()
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      process.send(callback_entered, Nil)
      // Intentionally hold the coordinator so requests can be queued in a
      // deterministic order behind this callback.
      process.sleep(100)
      channel.JoinOk(reply: None, socket: socket)
    })
  let assert Ok(_) = beryl.register(channels, "slow:*", handler)
  connect(channels, "mailbox-socket", sent)
  coordinator.route_decoded(
    coordinator_subject,
    "mailbox-socket",
    inbound("slow:room", codec.Join, "mailbox"),
  )
  let assert Ok(Nil) = process.receive(callback_entered, 500)

  let reply = process.new_subject()
  process.send(coordinator_subject, coordinator.GetStats(reply))
  process.send(coordinator_subject, coordinator.CheckHeartbeats)
  process.send(coordinator_subject, coordinator.CheckHeartbeats)
  process.send(coordinator_subject, coordinator.CheckHeartbeats)

  let assert Ok(snapshot) = process.receive(reply, 500)
  should.be_true(snapshot.coordinator_mailbox_length >= 3)
  let assert Ok(_) = process.receive(sent, 500)
  unsupervised.stop(channels)
}

pub fn snapshot_returns_unavailable_for_stopped_coordinator_test() {
  let assert Ok(channels) =
    unsupervised.start(beryl.config(wire.phoenix_codec()))
  unsupervised.stop(channels)

  stats.snapshot(channels)
  |> should.equal(Error(stats.CoordinatorUnavailable))
}

pub fn repeated_snapshot_timeouts_do_not_leak_caller_mailbox_messages_test() {
  let assert Ok(channels) =
    unsupervised.start(beryl.config(wire.phoenix_codec()))
  let sent = process.new_subject()
  let callback_entered = process.new_subject()
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      process.send(callback_entered, Nil)
      // Longer than two public snapshot bounds, simulating an overloaded
      // coordinator without relying on broad mailbox selection.
      process.sleep(2200)
      channel.JoinOk(reply: None, socket: socket)
    })
  let assert Ok(_) = beryl.register(channels, "slow:*", handler)
  connect(channels, "slow-socket", sent)
  coordinator.route_decoded(
    beryl.coordinator_subject(channels),
    "slow-socket",
    inbound("slow:room", codec.Join, "timeout"),
  )
  let assert Ok(Nil) = process.receive(callback_entered, 500)
  let mailbox_before = telemetry.mailbox_length()

  stats.snapshot(channels)
  |> should.equal(Error(stats.RequestTimedOut))
  stats.snapshot(channels)
  |> should.equal(Error(stats.RequestTimedOut))

  // The coordinator now services both queued requests, but their reply
  // subjects belong to exited proxy processes rather than this test process.
  let assert Ok(_) = process.receive(sent, 500)
  // A successful request is an exact coordinator barrier proving both late
  // replies have already been sent.
  let assert Ok(_) = stats.snapshot(channels)
  telemetry.mailbox_length() |> should.equal(mailbox_before)
  unsupervised.stop(channels)
}
