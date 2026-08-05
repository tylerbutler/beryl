//// Local runtime statistics.
////
//// Snapshots are point-in-time values captured when the local socket runtime
//// services a request. They are intended for operational polling, not as an
//// event stream. Poll no more frequently than roughly once per second so
//// observation does not add meaningful runtime load.

import beryl

/// A point-in-time snapshot of local runtime state.
pub opaque type Snapshot {
  Snapshot(
    connected_sockets: Int,
    joined_socket_topic_pairs: Int,
    active_topics: Int,
    registered_channel_handlers: Int,
    coordinator_mailbox_length: Int,
  )
}

/// Errors returned while requesting a runtime snapshot.
pub type SnapshotError {
  /// The local socket runtime is not currently running.
  CoordinatorUnavailable
  /// The runtime did not service the request within the bounded timeout.
  RequestTimedOut
}

/// Request a point-in-time snapshot from the local runtime.
///
/// The request waits for at most approximately one second. During a
/// runtime restart this returns `CoordinatorUnavailable` or
/// `RequestTimedOut`; an overloaded runtime returns `RequestTimedOut`.
/// Neither condition panics. This API reports only the node represented by
/// `channels`; aggregate multi-node statistics outside Beryl.
///
/// Poll no more frequently than roughly once per second.
pub fn snapshot(sockets: beryl.Sockets) -> Result(Snapshot, SnapshotError) {
  case beryl.app_dispatch(sockets).stats() {
    Error(False) -> Error(CoordinatorUnavailable)
    Error(True) -> Error(RequestTimedOut)
    Ok(#(connected, joined, topics, mailbox)) ->
      Ok(Snapshot(
        connected_sockets: connected,
        joined_socket_topic_pairs: joined,
        active_topics: topics,
        registered_channel_handlers: 1,
        coordinator_mailbox_length: mailbox,
      ))
  }
}

/// Return the number of sockets connected to the local runtime.
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

/// Return the number of app dispatch handlers (one for a running app).
pub fn registered_channel_handlers(snapshot: Snapshot) -> Int {
  snapshot.registered_channel_handlers
}

/// Return the runtime mailbox length when it serviced the request.
pub fn coordinator_mailbox_length(snapshot: Snapshot) -> Int {
  snapshot.coordinator_mailbox_length
}
