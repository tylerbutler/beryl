//// A point-in-time snapshot of local runtime state.
////
//// Snapshots are point-in-time values as observed by the runtime process
//// servicing the request. Counts may lag in-flight connect and disconnect
//// notifications that have not yet reached that process, so they are
//// eventually consistent rather than exact at the instant of the call. They
//// are intended for operational polling, not as an event stream. Poll no
//// more frequently than roughly once per second so observation does not add
//// meaningful runtime load.

import beryl
import beryl/overload

/// Read local router admission accounting without waiting for a router turn.
pub fn queue(
  sockets: beryl.Sockets,
) -> Result(overload.Occupancy, overload.AdmissionError) {
  beryl.app_dispatch(sockets).queue_snapshot()
}

/// A point-in-time snapshot of local runtime state.
pub opaque type Snapshot {
  Snapshot(
    connected_sockets: Int,
    joined_socket_topic_pairs: Int,
    active_topics: Int,
  )
}

/// Errors from a runtime snapshot request.
pub type SnapshotError {
  /// The local socket runtime is not running.
  RuntimeUnavailable
  /// The runtime did not process the request before the timeout.
  RequestTimedOut
  /// The request did not enter the runtime queue.
  AdmissionRejected(overload.AdmissionError)
}

/// Request a snapshot from the local runtime.
///
/// The request waits for about one second at most. During a runtime restart,
/// this function returns `RuntimeUnavailable` or `RequestTimedOut`. An
/// full runtime queue returns `AdmissionRejected`.
/// Neither condition panics. This API reports only the node represented by
/// `sockets`; aggregate multi-node statistics outside beryl.
///
/// Poll no more frequently than roughly once per second.
pub fn get(sockets: beryl.Sockets) -> Result(Snapshot, SnapshotError) {
  case beryl.app_dispatch(sockets).stats() {
    Error(beryl.StatsRuntimeUnavailable) -> Error(RuntimeUnavailable)
    Error(beryl.StatsRequestTimedOut) -> Error(RequestTimedOut)
    Error(beryl.StatsAdmissionRejected(overload.Unavailable)) ->
      Error(RuntimeUnavailable)
    Error(beryl.StatsAdmissionRejected(error)) ->
      Error(AdmissionRejected(error))
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
