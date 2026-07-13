import beryl_site/presence/model
import beryl_site/presence/protocol
import beryl_site/presence/reconnect
import gleam/list
import gleam/option
import lustre/effect.{type Effect}

@external(javascript, "./phoenix_ffi.mjs", "scenarioId")
fn scenario_id() -> String

@external(javascript, "./phoenix_ffi.mjs", "connect")
fn connect_ffi(
  role: String,
  service_url: String,
  topic: String,
  name: String,
  compatibility_version: Int,
  reconnect_delay: fn(Int) -> Int,
  on_open: fn() -> Nil,
  on_join: fn(String) -> Nil,
  on_join_error: fn(String) -> Nil,
  on_presence_diff: fn(String) -> Nil,
  on_close: fn(String) -> Nil,
) -> Nil

@external(javascript, "./phoenix_ffi.mjs", "disconnect")
fn disconnect_ffi(topic: String, role: String) -> Nil

@external(javascript, "./phoenix_ffi.mjs", "disconnectAll")
fn disconnect_all_ffi(topic: String) -> Nil

/// Runs the given commands as managed Lustre effects, bridging to the Phoenix
/// JavaScript client for socket, channel, and presence work.
pub fn run(commands: List(model.Command)) -> Effect(model.Message) {
  commands
  |> list.map(run_one)
  |> effect.batch
}

fn run_one(command: model.Command) -> Effect(model.Message) {
  case command {
    model.GenerateScenario ->
      effect.from(fn(dispatch) {
        dispatch(model.ScenarioCreated(scenario_id()))
      })
    model.OpenClient(role, service_url, topic, name, compatibility_version) ->
      effect.from(fn(dispatch) {
        connect_ffi(
          role_to_string(role),
          service_url,
          topic,
          name,
          compatibility_version,
          fn(attempt) {
            reconnect.delay(attempt)
            |> option.unwrap(-1)
          },
          fn() { dispatch(model.TransportOpened(role)) },
          fn(encoded) {
            case protocol.decode_join(encoded) {
              Ok(reply) -> dispatch(model.JoinSucceeded(role, reply))
              Error(reason) -> dispatch(model.ProtocolFailed(reason))
            }
          },
          fn(reason) { dispatch(model.JoinFailed(role, reason)) },
          fn(encoded) {
            case protocol.decode_diff(encoded) {
              Ok(diff) -> dispatch(model.PresenceDiffReceived(diff))
              Error(reason) -> dispatch(model.ProtocolFailed(reason))
            }
          },
          fn(reason) { dispatch(model.TransportClosed(role, reason)) },
        )
      })
    model.CloseClient(topic, role) ->
      effect.from(fn(_dispatch) { disconnect_ffi(topic, role_to_string(role)) })
    model.CloseAll(topic) ->
      effect.from(fn(_dispatch) { disconnect_all_ffi(topic) })
  }
}

fn role_to_string(role: model.ClientRole) -> String {
  case role {
    model.Primary -> "primary"
    model.Secondary -> "secondary"
  }
}
