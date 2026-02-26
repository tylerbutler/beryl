//// Supervisor - OTP supervision tree for beryl subsystems
////
//// Starts all configured beryl subsystems (coordinator, pubsub, presence,
//// groups) under an OTP supervisor with a rest-for-one strategy. If the
//// coordinator crashes, downstream subsystems (presence, groups) are also
//// restarted since they hold references that become stale.
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
import beryl/presence
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision

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
  )
}

/// Errors when starting the supervised system
pub type StartError {
  /// The supervisor failed to start
  SupervisorStartFailed(actor.StartError)
}

/// Start all configured beryl subsystems under an OTP supervisor
///
/// Uses a rest-for-one strategy: if the coordinator crashes, presence and
/// groups are also restarted since they hold references that become stale.
/// Child start order: coordinator -> presence (optional) -> groups (optional).
///
/// The existing `beryl.start()` function is preserved for unsupervised use.
pub fn start(config: SupervisedConfig) -> Result(SupervisedChannels, StartError) {
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

  // Build coordinator config from channels config
  let coord_config =
    coordinator.CoordinatorConfig(
      heartbeat_check_interval_ms: config.channels.heartbeat_interval_ms,
      heartbeat_timeout_ms: config.channels.heartbeat_timeout_ms,
    )

  // Build the supervisor with rest-for-one strategy.
  // If the coordinator crashes, presence and groups restart too since they
  // may hold stale references to socket PIDs.
  let builder =
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.restart_tolerance(intensity: 3, period: 5)

  // Always add coordinator as the first child
  let builder =
    builder
    |> static_supervisor.add(
      supervision.worker(fn() {
        coordinator.start_named(coord_config, coordinator_name)
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
    Error(err) -> Error(SupervisorStartFailed(err))
    Ok(_started) -> {
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

      Ok(SupervisedChannels(channels: channels, presence: pres, groups: grps))
    }
  }
}
