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
//// import beryl/wire
////
//// let config =
////   supervisor.config(beryl.config(wire.phoenix_codec()))
////   |> supervisor.with_presence(presence.default_config("node1"))
////   |> supervisor.with_groups()
//// let assert Ok(supervised) = supervisor.start(config)
//// // supervisor.channels(supervised), supervisor.presence(supervised),
//// // supervisor.groups(supervised)
//// ```

import beryl
import beryl/coordinator
import beryl/error as beryl_error
import beryl/group
import beryl/internal
import beryl/log
import beryl/presence
import gleam/bool
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result

/// Configuration for starting all beryl subsystems under a supervisor.
///
/// Opaque: build it with [`config`](#config) and refine it with the
/// `with_*` functions. This keeps the configuration extensible — new
/// subsystem options can be added post-1.0 without breaking callers.
pub opaque type SupervisedConfig {
  SupervisedConfig(
    channels: beryl.Config,
    presence: Option(presence.Config),
    groups: Bool,
  )
}

/// Handle to all supervised beryl subsystems.
///
/// Opaque: read its fields with the accessor functions
/// ([`channels`](#channels), [`presence`](#presence), [`groups`](#groups),
/// [`supervisor_pid`](#supervisor_pid)). This lets the handle grow new
/// fields post-1.0 without breaking readers.
pub opaque type SupervisedChannels {
  SupervisedChannels(
    channels: beryl.Channels,
    presence: Option(presence.Presence),
    groups: Option(group.Groups),
    supervisor_pid: process.Pid,
  )
}

/// Start building a supervised configuration.
///
/// Requires the channels configuration (the coordinator is always started).
/// Presence and groups are opt-in via [`with_presence`](#with_presence) and
/// [`with_groups`](#with_groups); by default neither is started.
pub fn config(channels: beryl.Config) -> SupervisedConfig {
  SupervisedConfig(channels: channels, presence: None, groups: False)
}

/// Enable presence tracking with the given configuration.
pub fn with_presence(
  config: SupervisedConfig,
  presence: presence.Config,
) -> SupervisedConfig {
  SupervisedConfig(..config, presence: Some(presence))
}

/// Enable the named channel groups subsystem.
pub fn with_groups(config: SupervisedConfig) -> SupervisedConfig {
  SupervisedConfig(..config, groups: True)
}

/// The channels system handle (always present).
pub fn channels(supervised: SupervisedChannels) -> beryl.Channels {
  supervised.channels
}

/// The presence handle, if presence was configured.
pub fn presence(supervised: SupervisedChannels) -> Option(presence.Presence) {
  supervised.presence
}

/// The groups handle, if groups were configured.
pub fn groups(supervised: SupervisedChannels) -> Option(group.Groups) {
  supervised.groups
}

/// The supervisor process PID (for lifecycle management).
pub fn supervisor_pid(supervised: SupervisedChannels) -> process.Pid {
  supervised.supervisor_pid
}

/// Errors when starting the supervised system
pub type StartError {
  /// The supervisor failed to start
  SupervisorStartFailed(beryl_error.StartFailure)
  /// `heartbeat_timeout_ms` must be at least 2 — the same validation as
  /// `beryl.start` (the staleness check interval is derived as
  /// `heartbeat_timeout_ms / 2`, so 1 would silently disable eviction).
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
pub fn start(
  config: SupervisedConfig,
) -> Result(SupervisedChannels, StartError) {
  // Validate heartbeat_timeout_ms before deriving check_interval, using the
  // same bound as beryl.start so both entry points reject the same configs.
  use <- bool.guard(
    when: beryl.config_heartbeat_timeout_ms(config.channels) < 2,
    return: Error(InvalidHeartbeatTimeout),
  )
  beryl.warn_if_unprotected(config.channels)
  start_supervised(config)
}

fn start_supervised(
  config: SupervisedConfig,
) -> Result(SupervisedChannels, StartError) {
  let logger = internal.logger("beryl.supervisor")

  // Create names for each subsystem up front. The supervisor starts children
  // via callbacks, so we use named actors to retrieve subjects afterward.
  // Names must be created before supervisor start (not dynamically in loops).
  let registry_name = process.new_name("beryl_registry")
  let coordinator_name = process.new_name("beryl_coordinator")

  let presence_name = case config.presence {
    Some(_) -> Some(process.new_name("beryl_presence"))
    None -> None
  }

  let groups_name = case config.groups {
    True -> Some(process.new_name("beryl_groups"))
    False -> None
  }

  // Build coordinator config from channels config (same mapping and
  // half-timeout check interval as beryl.start), pointing the coordinator
  // at the supervised registry so restarts recover registrations.
  let registry = coordinator.registry_from_name(registry_name)
  let coord_config =
    coordinator.CoordinatorConfig(
      ..beryl.to_coordinator_config(config.channels),
      registry: Some(registry),
    )

  // Build the supervisor with rest-for-one strategy.
  // If the coordinator crashes, presence and groups restart too to maintain
  // consistency — a fresh coordinator reloads its handler registrations
  // from the registry, which starts earlier and survives the restart.
  let builder =
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.restart_tolerance(intensity: 3, period: 5)

  // The registry is the first child: with rest-for-one, a coordinator crash
  // restarts everything after it but never the registry itself, so channel
  // registrations survive.
  let builder =
    builder
    |> static_supervisor.add(
      supervision.worker(fn() {
        coordinator.start_registry_named(registry_name)
      }),
    )

  // The coordinator follows the registry
  let builder =
    builder
    |> static_supervisor.add(
      supervision.worker(fn() {
        let started = case beryl.config_pubsub(config.channels) {
          Some(ps) ->
            coordinator.start_named_with_pubsub(
              coord_config,
              ps,
              coordinator_name,
            )
          None -> coordinator.start_named(coord_config, coordinator_name)
        }

        started
        |> result.map_error(fn(err) {
          case err {
            coordinator.ActorStartFailed(e) -> e
            coordinator.InvalidHeartbeatTimeout ->
              actor.InitFailed("invalid heartbeat timeout")
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
      logger
      |> log.error("Supervisor failed to start", [])
      Error(SupervisorStartFailed(beryl_error.from_actor_start_error(err)))
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
      logger
      |> log.info("Supervisor started", [
        #("presence", presence_enabled),
        #("groups", groups_enabled),
      ])

      // Reconstruct handles from the named subjects.
      // The supervisor has started all children and they registered with
      // their names, so named_subject will route messages correctly.
      let coord_subject = process.named_subject(coordinator_name)
      let channels =
        beryl.channels_from_coordinator(
          coordinator: coord_subject,
          config: config.channels,
          registry: Some(registry),
        )

      let pres = case presence_name {
        Some(name) -> Some(presence.from_subject(process.named_subject(name)))
        None -> None
      }

      let grps = case groups_name {
        Some(name) -> Some(group.from_subject(process.named_subject(name)))
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
  internal.logger("beryl.supervisor") |> log.info("Supervisor stopping", [])
  stop_supervisor(supervised.supervisor_pid)
}

// nolint: unused_exports -- public embedding API for host static_supervisor trees; intended for downstream consumers
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
/// let beryl_config =
///   supervisor.config(beryl.config(wire.phoenix_codec()))
///   |> supervisor.with_groups()
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
        Error(SupervisorStartFailed(failure)) ->
          Error(actor.InitFailed(beryl_error.describe_start_failure(failure)))
        Error(InvalidHeartbeatTimeout) ->
          Error(actor.InitFailed("invalid heartbeat timeout"))
      }
    },
    restart: supervision.Permanent,
    significant: False,
    child_type: supervision.Supervisor,
  )
}

@external(erlang, "beryl_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil
