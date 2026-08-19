//// Local runtime statistics.
////
//// Snapshots are point-in-time values as observed by the runtime process
//// servicing the request. Counts may lag in-flight connect and disconnect
//// notifications that have not yet reached that process, so they are
//// eventually consistent rather than exact at the instant of the call. They
//// are intended for operational polling, not as an event stream. Poll no
//// more frequently than roughly once per second so observation does not add
//// meaningful runtime load.

import beryl

/// A point-in-time snapshot of local runtime state.
pub opaque type Snapshot {
  Snapshot(
    connected_sockets: Int,
    joined_socket_topic_pairs: Int,
    active_topics: Int,
  )
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
  case beryl.app_dispatch(sockets).stats() {
    Error(beryl.StatsRuntimeUnavailable) -> Error(RuntimeUnavailable)
    Error(beryl.StatsRequestTimedOut) -> Error(RequestTimedOut)
    Ok(stats) ->
      Ok(Snapshot(
        connected_sockets: stats.connected_sockets,
        joined_socket_topic_pairs: stats.joined_socket_topic_pairs,
        active_topics: stats.active_topics,
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
