//// Local coordinator statistics.
////
//// Snapshots are point-in-time values captured when the local coordinator
//// services a request. They are intended for operational polling, not as an
//// event stream. Poll no more frequently than roughly once per second so
//// observation does not add meaningful coordinator load.

import beryl
import beryl/coordinator
import beryl/internal
import gleam/erlang/process

const request_timeout_ms = 1000

/// A point-in-time snapshot of local coordinator state.
pub opaque type Snapshot {
  Snapshot(
    connected_sockets: Int,
    joined_socket_topic_pairs: Int,
    active_topics: Int,
    registered_channel_handlers: Int,
    coordinator_mailbox_length: Int,
  )
}

/// Errors returned while requesting a coordinator snapshot.
pub type SnapshotError {
  /// The local coordinator is not currently running.
  CoordinatorUnavailable
  /// The coordinator did not service the request within the bounded timeout.
  RequestTimedOut
}

/// Request a point-in-time snapshot from the local coordinator.
///
/// The request waits for at most approximately one second. During a
/// coordinator restart this returns `CoordinatorUnavailable` or
/// `RequestTimedOut`; an overloaded coordinator returns `RequestTimedOut`.
/// Neither condition panics. This API reports only the node represented by
/// `channels`; aggregate multi-node statistics outside Beryl.
///
/// Poll no more frequently than roughly once per second.
pub fn snapshot(channels: beryl.Channels) -> Result(Snapshot, SnapshotError) {
  let coordinator_subject = beryl.coordinator_subject(channels)
  let completed = process.new_subject()
  let _proxy =
    process.spawn_unlinked(fn() {
      process.send(completed, request_snapshot(coordinator_subject))
    })
  process.receive_forever(completed)
}

fn request_snapshot(
  coordinator_subject: process.Subject(coordinator.Message),
) -> Result(Snapshot, SnapshotError) {
  case process.subject_owner(coordinator_subject) {
    Error(Nil) -> Error(CoordinatorUnavailable)
    Ok(owner) ->
      case process.is_alive(owner) {
        False -> Error(CoordinatorUnavailable)
        True -> send_and_receive(coordinator_subject)
      }
  }
}

fn send_and_receive(
  coordinator_subject: process.Subject(coordinator.Message),
) -> Result(Snapshot, SnapshotError) {
  // The named coordinator can disappear after the owner check. Sending to an
  // unregistered name raises on the BEAM, so rescue that unavoidable race and
  // expose it as a typed unavailable result.
  let reply = process.new_subject()
  case
    internal.rescue(fn() {
      process.send(coordinator_subject, coordinator.GetStats(reply))
    })
  {
    Error(_) -> Error(CoordinatorUnavailable)
    Ok(Nil) ->
      case process.receive(reply, request_timeout_ms) {
        Error(Nil) -> Error(RequestTimedOut)
        Ok(value) -> Ok(from_coordinator_snapshot(value))
      }
  }
}

fn from_coordinator_snapshot(value: coordinator.StatsSnapshot) -> Snapshot {
  Snapshot(
    connected_sockets: value.connected_sockets,
    joined_socket_topic_pairs: value.joined_socket_topic_pairs,
    active_topics: value.active_topics,
    registered_channel_handlers: value.registered_channel_handlers,
    coordinator_mailbox_length: value.coordinator_mailbox_length,
  )
}

/// Return the number of sockets connected to the local coordinator.
pub fn connected_sockets(snapshot: Snapshot) -> Int {
  snapshot.connected_sockets
}

/// Return the number of joined socket/topic pairs.
///
/// One socket joined to two topics contributes two pairs.
pub fn joined_socket_topic_pairs(snapshot: Snapshot) -> Int {
  snapshot.joined_socket_topic_pairs
}

/// Return the number of topics with at least one local joined socket.
pub fn active_topics(snapshot: Snapshot) -> Int {
  snapshot.active_topics
}

/// Return the number of channel handlers registered with the coordinator.
pub fn registered_channel_handlers(snapshot: Snapshot) -> Int {
  snapshot.registered_channel_handlers
}

/// Return the coordinator mailbox length when it serviced the request.
pub fn coordinator_mailbox_length(snapshot: Snapshot) -> Int {
  snapshot.coordinator_mailbox_length
}
