//// Supervisor - OTP supervision tree for beryl subsystems
////
//// Starts all configured beryl subsystems (coordinator, presence, groups)
//// under an OTP supervisor with a rest-for-one strategy. If the coordinator
//// crashes, downstream subsystems (presence, groups) are also restarted to
//// maintain state consistency — a fresh coordinator has no knowledge of
//// existing subscriptions, so presence/groups tracking stale topic data
//// would be inconsistent. PubSub is not supervised here; it is backed by
//// Erlang's `pg` module which has its own lifecycle.
////
//// ## Example
////
//// ```gleam
//// import beryl
//// import beryl/supervisor
//// import beryl/presence
//// import gleam/option.{None, Some}
////
//// let config = supervisor.SupervisedConfig(
////   channels: beryl.default_config(),
////   presence: Some(presence.default_config("node1")),
////   groups: True,
//// )
//// let assert Ok(supervised) = supervisor.start(config)
//// // supervised.channels, supervised.presence, supervised.groups
//// ```

import beryl
import beryl/coordinator
import beryl/group
import beryl/internal
import beryl/presence
import birch/logger
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result

/// Configuration for starting all beryl subsystems under a supervisor
pub type SupervisedConfig {
  SupervisedConfig(
    /// Configuration for the channels system (coordinator is always started)
    channels: beryl.Config,
    /// Optional presence configuration. When Some, presence is started.
    presence: Option(presence.Config),
    /// Whether to start the groups subsystem
    groups: Bool,
  )
}

/// Handle to all supervised beryl subsystems
pub type SupervisedChannels {
  SupervisedChannels(
    /// The channels system handle (always present)
    channels: beryl.Channels,
    /// Presence handle (if configured)
    presence: Option(presence.Presence),
    /// Groups handle (if configured)
    groups: Option(group.Groups),
    /// The supervisor process PID (for lifecycle management)
    supervisor_pid: process.Pid,
  )
}

/// Errors when starting the supervised system
pub type StartError {
  /// The supervisor failed to start
  SupervisorStartFailed(actor.StartError)
  /// heartbeat_timeout_ms must be > 0
  InvalidHeartbeatTimeout
}

/// Start all configured beryl subsystems under an OTP supervisor
///
/// Uses a rest-for-one strategy: if the coordinator crashes, presence and
/// groups are also restarted to maintain state consistency (a fresh coordinator
/// has no knowledge of existing subscriptions or sockets).
/// Child start order: coordinator -> presence (optional) -> groups (optional).
///
/// The existing `beryl.start()` function is preserved for unsupervised use.
pub fn start(config: SupervisedConfig) -> Result(SupervisedChannels, StartError) {
  // Validate heartbeat_timeout_ms before deriving check_interval
  case config.channels.heartbeat_timeout_ms <= 0 {
    True -> Error(InvalidHeartbeatTimeout)
    False -> start_supervised(config)
  }
}

fn start_supervised(
  config: SupervisedConfig,
) -> Result(SupervisedChannels, StartError) {
  let log = internal.logger("beryl.supervisor")

  // Create names for each subsystem up front. The supervisor starts children
  // via callbacks, so we use named actors to retrieve subjects afterward.
  // Names must be created before supervisor start (not dynamically in loops).
  let coordinator_name = process.new_name("beryl_coordinator")

  let presence_name = case config.presence {
    Some(_) -> Some(process.new_name("beryl_presence"))
    None -> None
  }

  let groups_name = case config.groups {
    True -> Some(process.new_name("beryl_groups"))
    False -> None
  }

  // Build coordinator config from channels config.
  // Server checks at half the timeout interval (same as beryl.start).
  let check_interval = config.channels.heartbeat_timeout_ms / 2
  let coord_config =
    coordinator.CoordinatorConfig(
      heartbeat_check_interval_ms: check_interval,
      heartbeat_timeout_ms: config.channels.heartbeat_timeout_ms,
    )

  // Build the supervisor with rest-for-one strategy.
  // If the coordinator crashes, presence and groups restart too to maintain
  // consistency — a fresh coordinator has empty state.
  let builder =
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.restart_tolerance(intensity: 3, period: 5)

  // Always add coordinator as the first child
  let builder =
    builder
    |> static_supervisor.add(
      supervision.worker(fn() {
        coordinator.start_named(coord_config, coordinator_name)
        |> result.map_error(fn(err) {
          case err {
            coordinator.ActorStartFailed(e) -> e
            coordinator.InvalidHeartbeatTimeout -> actor.InitTimeout
          }
        })
      }),
    )

  // Optionally add presence
  let builder = case config.presence, presence_name {
    Some(pres_config), Some(name) ->
      builder
      |> static_supervisor.add(
        supervision.worker(fn() { presence.start_named(pres_config, name) }),
      )
    _, _ -> builder
  }

  // Optionally add groups
  let builder = case groups_name {
    Some(name) ->
      builder
      |> static_supervisor.add(
        supervision.worker(fn() { group.start_named(name) }),
      )
    None -> builder
  }

  // Start the supervisor — this starts all children
  case static_supervisor.start(builder) {
    Error(err) -> {
      log
      |> logger.error("Supervisor failed to start", [])
      Error(SupervisorStartFailed(err))
    }
    Ok(started) -> {
      let presence_enabled = case config.presence {
        Some(_) -> "true"
        None -> "false"
      }
      let groups_enabled = case config.groups {
        True -> "true"
        False -> "false"
      }
      log
      |> logger.info("Supervisor started", [
        #("presence", presence_enabled),
        #("groups", groups_enabled),
      ])

      // Reconstruct handles from the named subjects.
      // The supervisor has started all children and they registered with
      // their names, so named_subject will route messages correctly.
      let coord_subject = process.named_subject(coordinator_name)
      let channels =
        beryl.Channels(
          coordinator: coord_subject,
          config: config.channels,
          pubsub: config.channels.pubsub,
        )

      let pres = case presence_name {
        Some(name) ->
          Some(presence.Presence(subject: process.named_subject(name)))
        None -> None
      }

      let grps = case groups_name {
        Some(name) -> Some(group.Groups(subject: process.named_subject(name)))
        None -> None
      }

      Ok(SupervisedChannels(
        channels: channels,
        presence: pres,
        groups: grps,
        supervisor_pid: started.pid,
      ))
    }
  }
}

/// Stop the supervisor and all its children
///
/// Cleanly shuts down the supervisor process, which terminates all child
/// processes (coordinator, presence, groups) in reverse start order. After
/// this call the `SupervisedChannels` handle should no longer be used.
pub fn stop(supervised: SupervisedChannels) -> Nil {
  let log = internal.logger("beryl.supervisor")
  log |> logger.info("Supervisor stopping", [])
  stop_supervisor(supervised.supervisor_pid)
}

/// Create a child specification for composing beryl into a larger supervision tree
///
/// Returns a supervisor-type child spec that starts the beryl supervision tree.
/// This enables embedding beryl as a subtree in an application's top-level
/// supervisor.
///
/// ## Example
///
/// ```gleam
/// import beryl/supervisor
/// import gleam/otp/static_supervisor
///
/// let beryl_config = supervisor.SupervisedConfig(
///   channels: beryl.default_config(),
///   presence: None,
///   groups: True,
/// )
///
/// static_supervisor.new(static_supervisor.OneForOne)
/// |> static_supervisor.add(supervisor.child_spec(beryl_config))
/// |> static_supervisor.start()
/// ```
pub fn child_spec(
  config: SupervisedConfig,
) -> supervision.ChildSpecification(SupervisedChannels) {
  supervision.ChildSpecification(
    start: fn() {
      case start(config) {
        Ok(supervised) ->
          Ok(actor.Started(pid: supervised.supervisor_pid, data: supervised))
        Error(SupervisorStartFailed(err)) -> Error(err)
        Error(InvalidHeartbeatTimeout) -> Error(actor.InitTimeout)
      }
    },
    restart: supervision.Permanent,
    significant: False,
    child_type: supervision.Supervisor,
  )
}

@external(erlang, "beryl_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil
