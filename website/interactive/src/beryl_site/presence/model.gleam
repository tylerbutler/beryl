import beryl_site/presence/protocol
import beryl_site/presence/transcript
import gleam/dict
import gleam/string

pub type Status {
  Static
  Connecting
  Connected
  Reconnecting
  Offline
  Incompatible
  Failed(String)
}

pub type ClientRole {
  Primary
  Secondary
}

pub type Command {
  GenerateScenario
  OpenClient(
    role: ClientRole,
    service_url: String,
    topic: String,
    name: String,
    compatibility_version: Int,
  )
  CloseClient(topic: String, role: ClientRole)
  CloseAll(topic: String)
}

pub type Message {
  ServiceUrlChanged(String)
  CompatibilityVersionChanged(Int)
  NameChanged(String)
  ConnectRequested
  ScenarioCreated(String)
  TransportOpened(ClientRole)
  JoinSucceeded(ClientRole, protocol.JoinReply)
  JoinFailed(ClientRole, String)
  PresenceDiffReceived(protocol.PresenceDiff)
  AddSecondaryRequested
  DisconnectSecondaryRequested
  TransportClosed(ClientRole, String)
  ProtocolFailed(String)
  ResetRequested(new_scenario_id: String)
  ComponentDisconnected
}

pub type Model {
  Model(
    service_url: String,
    expected_compatibility_version: Int,
    status: Status,
    topic: String,
    name: String,
    secondary_name: String,
    primary_client_id: String,
    secondary_connected: Bool,
    presences: protocol.PresenceState,
    transcript: List(transcript.Entry),
    next_sequence: Int,
  )
}

/// Returns the initial model with production defaults.
pub fn initial() -> Model {
  Model(
    service_url: "https://demos.beryl.tylerbutler.com",
    expected_compatibility_version: 1,
    status: Static,
    topic: "",
    name: "Alice",
    secondary_name: "Bob",
    primary_client_id: "",
    secondary_connected: False,
    presences: dict.new(),
    transcript: [],
    next_sequence: 1,
  )
}

fn record_event(model: Model, event: String, payload: String) -> Model {
  let entry = transcript.Entry(model.next_sequence, event, payload)
  Model(
    ..model,
    transcript: transcript.add(model.transcript, entry),
    next_sequence: model.next_sequence + 1,
  )
}

/// Pure update function — returns the next model and a list of commands for
/// the effect layer to execute.
pub fn update(model: Model, message: Message) -> #(Model, List(Command)) {
  case message {
    ServiceUrlChanged(url) ->
      case model.status {
        Static -> #(Model(..model, service_url: url), [])
        _ -> #(model, [])
      }

    CompatibilityVersionChanged(v) ->
      case model.status {
        Static -> #(Model(..model, expected_compatibility_version: v), [])
        _ -> #(model, [])
      }

    NameChanged(name) ->
      case model.status {
        Static -> #(Model(..model, name: name), [])
        _ -> #(model, [])
      }

    ConnectRequested ->
      case model.status {
        Static | Failed(_) -> {
          let m =
            Model(
              ..model,
              status: Connecting,
              presences: dict.new(),
              primary_client_id: "",
              secondary_connected: False,
            )
          #(m, [GenerateScenario])
        }
        _ -> #(model, [])
      }

    ScenarioCreated(id) -> {
      let topic = "demo:presence:" <> id
      let m = Model(..model, topic: topic)
      #(m, [
        OpenClient(
          role: Primary,
          service_url: model.service_url,
          topic: topic,
          name: model.name,
          compatibility_version: model.expected_compatibility_version,
        ),
      ])
    }

    TransportOpened(role) -> {
      let m = case role {
        Primary ->
          case model.status {
            Offline | Reconnecting -> Model(..model, status: Connecting)
            _ -> model
          }
        Secondary -> model
      }
      let m = record_event(m, "socket_open", string.inspect(role))
      #(m, [])
    }

    JoinSucceeded(role, reply) -> {
      let m = record_event(model, "phx_reply", string.inspect(reply))
      case reply.compatibility_version == model.expected_compatibility_version {
        False -> {
          let m = Model(..m, status: Incompatible)
          #(m, [CloseAll(model.topic)])
        }
        True ->
          case role {
            Primary -> {
              let m =
                Model(
                  ..m,
                  status: Connected,
                  presences: reply.presence_state,
                  primary_client_id: reply.client_id,
                )
              #(m, [])
            }
            Secondary -> {
              let m = Model(..m, secondary_connected: True)
              #(m, [])
            }
          }
      }
    }

    JoinFailed(role, reason) -> {
      let m = record_event(model, "join_error", reason)
      case protocol.decode_join_error(reason) {
        Ok(protocol.JoinError(code: 409, ..)) -> {
          let m = Model(..m, status: Incompatible)
          #(m, [CloseAll(model.topic)])
        }
        _ -> {
          let m = Model(..m, status: Failed(reason))
          #(m, [CloseClient(model.topic, role)])
        }
      }
    }

    PresenceDiffReceived(diff) -> {
      let m = record_event(model, "presence_diff", string.inspect(diff))
      let m = Model(..m, presences: protocol.apply_diff(m.presences, diff))
      #(m, [])
    }

    AddSecondaryRequested ->
      case model.status, model.secondary_connected {
        Connected, False -> #(model, [
          OpenClient(
            role: Secondary,
            service_url: model.service_url,
            topic: model.topic,
            name: model.secondary_name,
            compatibility_version: model.expected_compatibility_version,
          ),
        ])
        _, _ -> #(model, [])
      }

    DisconnectSecondaryRequested -> {
      let m = Model(..model, secondary_connected: False)
      #(m, [CloseClient(model.topic, Secondary)])
    }

    TransportClosed(role, reason) -> {
      let m = record_event(model, "socket_close", reason)
      case role {
        Secondary -> {
          let m = Model(..m, secondary_connected: False)
          #(m, [])
        }
        Primary ->
          case reason {
            "reconnect_exhausted" -> {
              let m = Model(..m, status: Failed("reconnect_exhausted"))
              #(m, [CloseAll(model.topic)])
            }
            "session_expired" -> {
              let m = Model(..m, status: Failed("session_expired"))
              #(m, [CloseAll(model.topic)])
            }
            "offline" -> {
              let m = Model(..m, status: Offline)
              #(m, [])
            }
            _ ->
              case model.status {
                Connected -> {
                  let m = Model(..m, status: Reconnecting)
                  #(m, [])
                }
                _ -> #(m, [])
              }
          }
      }
    }

    ProtocolFailed(reason) -> {
      let m = record_event(model, "protocol_error", reason)
      let m = Model(..m, status: Failed(reason))
      #(m, [CloseAll(model.topic)])
    }

    ResetRequested(new_scenario_id) -> {
      let new_topic = "demo:presence:" <> new_scenario_id
      let m =
        Model(
          ..model,
          status: Connecting,
          topic: new_topic,
          presences: dict.new(),
          primary_client_id: "",
          secondary_connected: False,
        )
      #(m, [
        CloseAll(model.topic),
        OpenClient(
          role: Primary,
          service_url: model.service_url,
          topic: new_topic,
          name: model.name,
          compatibility_version: model.expected_compatibility_version,
        ),
      ])
    }

    ComponentDisconnected -> #(model, [CloseAll(model.topic)])
  }
}
