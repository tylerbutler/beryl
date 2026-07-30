//// OTP supervision tree for beryl subsystems.
////
//// This module does not start processes directly. It builds a supervisor child
//// specification for the application's supervision tree, while stable named
//// subjects let callers construct the subsystem handles before that tree starts.
////
//// ## Example
////
//// ```gleam
//// import beryl
//// import beryl/presence
//// import beryl/supervisor
//// import beryl/wire
//// import gleam/otp/static_supervisor
////
//// let beryl =
////   supervisor.config(beryl.config(wire.phoenix_codec()))
////   |> supervisor.with_presence(presence.default_config("node1"))
////   |> supervisor.with_groups()
////
//// let assert Ok(_root) =
////   static_supervisor.new(static_supervisor.OneForOne)
////   |> static_supervisor.add(supervisor.start(beryl))
////   |> static_supervisor.start()
////
//// let channels = supervisor.channels(beryl)
//// ```

import beryl
import beryl/connection_limit
import beryl/coordinator
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

/// Configuration and stable handles for beryl's supervised subsystems.
///
/// Construct it with [`config`](#config), add optional subsystems with the
/// `with_*` functions, add [`start`](#start) to the application's supervisor,
/// then use [`channels`](#channels), [`presence`](#presence), and
/// [`groups`](#groups) to access the named processes.
pub opaque type SupervisedConfig {
  SupervisedConfig(
    channels_config: beryl.Config,
    registry_name: process.Name(coordinator.RegistryMsg),
    coordinator_name: process.Name(coordinator.Message),
    connection_limiter_name: Option(process.Name(connection_limit.Message)),
    presence_config: Option(presence.Config),
    presence_name: Option(process.Name(presence.Message)),
    groups_name: Option(process.Name(group.Message)),
  )
}

/// Configure the beryl supervision subtree.
///
/// The coordinator is always included. Presence and groups are opt-in via
/// [`with_presence`](#with_presence) and [`with_groups`](#with_groups).
pub fn config(channels: beryl.Config) -> SupervisedConfig {
  let max_per_ip = beryl.config_max_connections_per_ip(channels)
  let max_total = beryl.config_max_connections(channels)
  let connection_limiter_name = case
    connection_limit.enabled(max_per_ip, max_total)
  {
    True -> Some(process.new_name("beryl_connection_limiter"))
    False -> None
  }

  SupervisedConfig(
    channels_config: channels,
    registry_name: process.new_name("beryl_registry"),
    coordinator_name: process.new_name("beryl_coordinator"),
    connection_limiter_name: connection_limiter_name,
    presence_config: None,
    presence_name: None,
    groups_name: None,
  )
}

/// Enable presence tracking with the given configuration.
pub fn with_presence(
  config: SupervisedConfig,
  presence: presence.Config,
) -> SupervisedConfig {
  SupervisedConfig(
    ..config,
    presence_config: Some(presence),
    presence_name: Some(process.new_name("beryl_presence")),
  )
}

/// Enable named channel groups.
pub fn with_groups(config: SupervisedConfig) -> SupervisedConfig {
  case config.groups_name {
    Some(_) -> config
    None ->
      SupervisedConfig(
        ..config,
        groups_name: Some(process.new_name("beryl_groups")),
      )
  }
}

/// The channels handle for this supervised beryl instance.
///
/// Add [`start`](#start) to a running application supervisor before using the
/// handle.
pub fn channels(config: SupervisedConfig) -> beryl.Channels {
  beryl.channels_from_supervised_parts(
    coordinator: process.named_subject(config.coordinator_name),
    config: config.channels_config,
    registry: coordinator.registry_from_name(config.registry_name),
    connection_limiter: config.connection_limiter_name
      |> option_map(connection_limit.from_name),
  )
}

/// The presence handle, if presence was configured.
pub fn presence(config: SupervisedConfig) -> Option(presence.Presence) {
  config.presence_name
  |> option_map(fn(name) { presence.from_subject(process.named_subject(name)) })
}

/// The groups handle, if groups were configured.
pub fn groups(config: SupervisedConfig) -> Option(group.Groups) {
  config.groups_name
  |> option_map(fn(name) { group.from_subject(process.named_subject(name)) })
}

/// Build beryl's supervisor child specification.
///
/// Add the returned specification to the application's supervision tree. The
/// subtree isolates the connection limiter from a nested rest-for-one channel
/// supervisor. A coordinator crash therefore restarts its dependent presence
/// and groups processes while preserving registrations and live connection
/// counts.
pub fn start(
  config: SupervisedConfig,
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  supervision.supervisor(fn() { start_supervisor(config) })
}

fn start_supervisor(
  config: SupervisedConfig,
) -> Result(actor.Started(static_supervisor.Supervisor), actor.StartError) {
  use <- bool.guard(
    when: beryl.config_heartbeat_timeout_ms(config.channels_config) < 2,
    return: Error(actor.InitFailed("invalid heartbeat timeout")),
  )
  beryl.warn_if_unprotected(config.channels_config)

  let registry = coordinator.registry_from_name(config.registry_name)
  let coordinator_config =
    coordinator.CoordinatorConfig(
      ..beryl.to_coordinator_config(config.channels_config),
      registry: Some(registry),
    )

  let channels_builder =
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.restart_tolerance(intensity: 3, period: 5)
    |> static_supervisor.add(
      supervision.worker(fn() {
        coordinator.start_registry_named(config.registry_name)
      }),
    )

  let channels_builder =
    channels_builder
    |> static_supervisor.add(
      supervision.worker(fn() {
        let started = case beryl.config_pubsub(config.channels_config) {
          Some(pubsub) ->
            coordinator.start_named_with_pubsub(
              coordinator_config,
              pubsub,
              config.coordinator_name,
            )
          None ->
            coordinator.start_named(coordinator_config, config.coordinator_name)
        }

        started
        |> result.map_error(fn(error) {
          case error {
            coordinator.ActorStartFailed(error) -> error
            coordinator.InvalidHeartbeatTimeout ->
              actor.InitFailed("invalid heartbeat timeout")
          }
        })
      }),
    )

  let channels_builder = case config.presence_config, config.presence_name {
    Some(presence_config), Some(name) ->
      channels_builder
      |> static_supervisor.add(
        supervision.worker(fn() { presence.start_named(presence_config, name) }),
      )
    _, _ -> channels_builder
  }

  let channels_builder = case config.groups_name {
    Some(name) ->
      channels_builder
      |> static_supervisor.add(
        supervision.worker(fn() { group.start_named(name) }),
      )
    None -> channels_builder
  }

  let builder =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.restart_tolerance(intensity: 3, period: 5)

  let builder = case config.connection_limiter_name {
    Some(name) ->
      builder
      |> static_supervisor.add(
        supervision.worker(fn() {
          connection_limit.start_named(
            beryl.config_max_connections_per_ip(config.channels_config),
            beryl.config_max_connections(config.channels_config),
            name,
          )
        }),
      )
    None -> builder
  }

  case
    builder
    |> static_supervisor.add(static_supervisor.supervised(channels_builder))
    |> static_supervisor.start()
  {
    Error(error) -> {
      internal.logger("beryl.supervisor")
      |> log.error("Supervisor failed to start", [])
      Error(error)
    }
    Ok(started) -> {
      internal.logger("beryl.supervisor")
      |> log.info("Supervisor started", [
        #("presence", case config.presence_config {
          Some(_) -> "true"
          None -> "false"
        }),
        #("groups", case config.groups_name {
          Some(_) -> "true"
          None -> "false"
        }),
      ])
      Ok(started)
    }
  }
}

fn option_map(option: Option(a), transform: fn(a) -> b) -> Option(b) {
  case option {
    Some(value) -> Some(transform(value))
    None -> None
  }
}
