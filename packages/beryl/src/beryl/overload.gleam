//// Admission limits for local beryl work.
////
//// Counts include queued and executing work. Accounted payload bytes are not
//// a measurement of BEAM heap memory. Typed messages, closures, application
//// state, raw PubSub delivery, and transport buffers are outside byte limits.

/// A local admission boundary. These values are also telemetry labels.
pub type Boundary {
  RouterQueue
  SocketQueue
  WorkerQueue
  PresenceQueue
  CallbackBatch
}

/// Work was not admitted, or a callback's complete result was rejected.
pub type AdmissionError {
  Unavailable
  Closed
  Overloaded(boundary: Boundary)
  ItemTooLarge(boundary: Boundary)
}

/// A bounded request failed before admission or while awaiting completion.
pub type CallError {
  AdmissionRejected(AdmissionError)
  /// A timeout does not prove that the operation was not applied.
  RequestTimedOut
  OwnerUnavailable
}

/// Owner-independent accounting. Bytes exclude opaque function environments.
/// `cancelled` counts removed pending work and reclaimed abandoned reservations.
/// Age is in milliseconds.
pub type Occupancy {
  Occupancy(
    boundary: Boundary,
    items: Int,
    bytes: Int,
    max_items: Int,
    max_bytes: Int,
    high_items: Int,
    high_bytes: Int,
    rejected: Int,
    cancelled: Int,
    oldest_age_ms: Int,
  )
}

/// A queue limit must be positive.
pub type LimitError {
  InvalidItemLimit
  InvalidByteLimit
}

/// Positive count and accounted-payload limits.
pub opaque type Limits {
  Limits(items: Int, bytes: Int)
}

/// Construct finite limits. Zero does not disable queue admission.
pub fn limits(
  items items: Int,
  bytes bytes: Int,
) -> Result(Limits, LimitError) {
  case items > 0, bytes > 0 {
    False, _ -> Error(InvalidItemLimit)
    True, False -> Error(InvalidByteLimit)
    True, True -> Ok(Limits(items, bytes))
  }
}

/// Default router or presence mutation limits.
pub fn shared_limits() -> Limits {
  Limits(4096, 33_554_432)
}

/// Default socket limits, including suspended work and pending reports.
pub fn socket_limits() -> Limits {
  Limits(1024, 8_388_608)
}

/// Default topic-worker input limits.
pub fn worker_limits() -> Limits {
  Limits(256, 8_388_608)
}

/// Maximum outstanding items.
pub fn max_items(limits: Limits) -> Int {
  limits.items
}

/// Maximum accounted payload bytes.
pub fn max_bytes(limits: Limits) -> Int {
  limits.bytes
}

/// Describe an admission failure without including application data.
pub fn describe(error: AdmissionError) -> String {
  case error {
    Unavailable -> "owner unavailable"
    Closed -> "target closed"
    Overloaded(_) -> "work queue full"
    ItemTooLarge(_) -> "work item exceeds its size limit"
  }
}
