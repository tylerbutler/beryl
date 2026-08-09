//// Local runtime statistics.
////
//// Snapshots are point-in-time values captured when the local socket runtime
//// services a request. They are intended for operational polling, not as an
//// event stream. Poll no more frequently than roughly once per second so
//// observation does not add meaningful runtime load.

import beryl
import beryl/runtime

/// A point-in-time snapshot of local runtime state.
pub opaque type Snapshot {
  Snapshot(inner: runtime.StatsSnapshot)
}

/// Errors returned while requesting a runtime snapshot.
pub type SnapshotError {
  /// The local socket runtime is not currently running.
  RuntimeUnavailable
  /// The runtime did not service the request within the bounded timeout.
  RequestTimedOut
}

/// Request a point-in-time snapshot from the local runtime.
///
/// The request waits for at most approximately one second. During a
/// runtime restart this returns `RuntimeUnavailable` or
/// `RequestTimedOut`; an overloaded runtime returns `RequestTimedOut`.
/// Neither condition panics. This API reports only the node represented by
/// `sockets`; aggregate multi-node statistics outside Beryl.
///
/// Poll no more frequently than roughly once per second.
pub fn snapshot(sockets: beryl.Sockets) -> Result(Snapshot, SnapshotError) {
  case beryl.runtime_stats(sockets) {
    Error(runtime.RuntimeDown) -> Error(RuntimeUnavailable)
    Error(runtime.RequestTimeout) -> Error(RequestTimedOut)
    Ok(inner) -> Ok(Snapshot(inner))
  }
}

/// Return the number of sockets connected to the local runtime.
pub fn connected_sockets(snapshot: Snapshot) -> Int {
  snapshot.inner.connected_sockets
}

/// Return the number of joined socket/topic pairs.
///
/// One socket joined to two topics contributes two pairs.
pub fn joined_socket_topic_pairs(snapshot: Snapshot) -> Int {
  snapshot.inner.joined_socket_topic_pairs
}

/// Return the number of topics with at least one local joined socket.
pub fn active_topics(snapshot: Snapshot) -> Int {
  snapshot.inner.active_topics
}

/// Return the runtime mailbox length when it serviced the request.
pub fn runtime_mailbox_length(snapshot: Snapshot) -> Int {
  snapshot.inner.runtime_mailbox_length
}
