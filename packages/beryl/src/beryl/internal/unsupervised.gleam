//// Unsupervised channel-system startup.
////
//// This module is **package-internal**: it is listed in `internal_modules`,
//// so it is excluded from generated documentation and from beryl's published
//// API. It exists purely so beryl's own tests can drive a bare coordinator
//// without standing up a supervision tree.
////
//// Like beryl's other internal modules (`beryl/coordinator`, `beryl/log`,
//// `beryl/rate_limit`), the boundary is not enforced by the compiler for
//// path dependencies inside this workspace — it is a project rule. Nothing
//// outside `packages/beryl/test` may import this module.
////
//// Applications must start beryl through `beryl/supervisor`, which returns a
//// child specification for their own OTP supervision tree. A channel system
//// started here has nothing watching it: if the coordinator crashes, the
//// system stays down and every connected socket is stranded.

import beryl
import beryl/connection_limit
import beryl/coordinator
import beryl/error as beryl_error
import beryl/internal
import gleam/bool
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/result

/// Errors when starting an unsupervised channels system.
pub type StartError {
  /// The coordinator actor failed to start.
  CoordinatorStartFailed(beryl_error.StartFailure)
  /// `heartbeat_timeout_ms` must be at least 2. The server derives its
  /// staleness check interval as `heartbeat_timeout_ms / 2` (integer
  /// division), so a timeout of 1 would round down to a check interval of 0 —
  /// which disables heartbeat eviction entirely. `start` rejects such a config
  /// loudly rather than silently turning eviction off.
  InvalidHeartbeatTimeout
}

/// Start an unsupervised channels system.
///
/// Test-only. Production code uses `beryl/supervisor` so OTP can restart the
/// subtree; see this module's documentation.
pub fn start(config: beryl.Config) -> Result(beryl.Channels, StartError) {
  use <- bool.guard(
    when: beryl.config_heartbeat_timeout_ms(config) < 2,
    return: internal.result_error(InvalidHeartbeatTimeout),
  )
  beryl.warn_if_unprotected(config)
  // Registrations live in a registry that outlives the coordinator, so a
  // supervised restart (or manual coordinator replacement) can re-seed them.
  use registry <- result.try(
    coordinator.start_registry()
    |> result.map_error(fn(error) {
      CoordinatorStartFailed(beryl_error.from_actor_start_error(error))
    }),
  )
  let coord_config =
    coordinator.CoordinatorConfig(
      ..beryl.to_coordinator_config(config),
      registry: Some(registry),
    )

  let coordinator_result = case beryl.config_pubsub(config) {
    Some(ps) -> coordinator.start_with_config_and_pubsub(coord_config, ps)
    None -> coordinator.start_with_config(coord_config)
  }

  case coordinator_result {
    Ok(coord) ->
      Ok(beryl.channels_from_coordinator(
        coordinator: coord,
        config: config,
        registry: Some(registry),
      ))
    error_result -> {
      case
        result.unwrap_error(
          error_result,
          or: coordinator.InvalidHeartbeatTimeout,
        )
      {
        coordinator.ActorStartFailed(error) ->
          internal.result_error(
            CoordinatorStartFailed(beryl_error.from_actor_start_error(error)),
          )
        coordinator.InvalidHeartbeatTimeout ->
          internal.result_error(InvalidHeartbeatTimeout)
      }
    }
  }
}

/// Stop an unsupervised channels system.
///
/// Shuts down the coordinator actor started by `start` and any auxiliary
/// limiter actors owned by the `Channels` handle. Joined channel handlers
/// receive `channel.Shutdown` in their `terminate` callback before the
/// coordinator exits. After this call the `Channels` handle must not be used.
pub fn stop(channels: beryl.Channels) -> Nil {
  stop_coordinator(beryl.coordinator_subject(channels))
  connection_limit.stop_optional(beryl.channels_connection_limiter(channels))
  case beryl.channels_registry(channels) {
    Some(registry) -> coordinator.stop_registry(registry)
    None -> Nil
  }
}

fn stop_coordinator(coordinator: process.Subject(coordinator.Message)) -> Nil {
  let should_send = case process.subject_owner(coordinator) {
    Ok(pid) -> process.is_alive(pid)
    _ -> False
  }

  use <- bool.guard(when: !should_send, return: Nil)
  let reply = process.new_subject()
  process.send(coordinator, coordinator.Stop(reply))
  let _stop_result = process.receive(reply, 5000)
  Nil
}
