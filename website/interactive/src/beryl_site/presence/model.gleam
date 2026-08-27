import beryl_site/presence/protocol
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

const max_transcript_entries = 100

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

/// Why the Phoenix client closed a transport, as reported by the JavaScript
/// bridge.
pub type CloseReason {
  ReconnectExhausted
  SessionExpired
  NetworkOffline
  OtherClose(String)
}

/// One line of the event transcript shown under the presence list.
pub type Entry {
  Entry(sequence: Int, event: String, payload: String)
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
  TransportClosed(ClientRole, CloseReason)
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
    transcript: List(Entry),
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

/// Returns the reconnect delay in milliseconds for the given attempt number,
/// or `None` once retries are exhausted (after 5 attempts).
pub fn reconnect_delay(attempt: Int) -> Option(Int) {
  case attempt {
    1 -> Some(1000)
    2 -> Some(2000)
    3 -> Some(5000)
    4 | 5 -> Some(10_000)
    _ -> None
  }
}

/// Parses the close reason string emitted by the JavaScript bridge.
pub fn string_to_close_reason(raw: String) -> CloseReason {
  case raw {
    "reconnect_exhausted" -> ReconnectExhausted
    "session_expired" -> SessionExpired
    "offline" -> NetworkOffline
    _ -> OtherClose(raw)
  }
}

/// Formats a close reason for the transcript and the `Failed` status.
pub fn close_reason_to_string(reason: CloseReason) -> String {
  case reason {
    ReconnectExhausted -> "reconnect_exhausted"
    SessionExpired -> "session_expired"
    NetworkOffline -> "offline"
    OtherClose(raw) -> raw
  }
}

/// True while the lab is idle or has failed, so a new connection can start.
pub fn can_connect(status: Status) -> Bool {
  case status {
    Static | Failed(_) -> True
    Connecting | Connected | Reconnecting | Offline | Incompatible -> False
  }
}

/// True only before the first connection, when host attributes may still
/// change the service URL and expected compatibility version.
fn accepts_settings(status: Status) -> Bool {
  case status {
    Static -> True
    Connecting
    | Connected
    | Reconnecting
    | Offline
    | Incompatible
    | Failed(_) -> False
  }
}

/// Prepends an entry to the transcript, keeping at most 100 entries (newest
/// first).
fn record_event(model: Model, event: String, payload: String) -> Model {
  let entry = Entry(model.next_sequence, event, payload)
  Model(
    ..model,
    transcript: list.take([entry, ..model.transcript], max_transcript_entries),
    next_sequence: model.next_sequence + 1,
  )
}

fn open_primary(model: Model, topic: String) -> Command {
  OpenClient(
    role: Primary,
    service_url: model.service_url,
    topic: topic,
    name: model.name,
    compatibility_version: model.expected_compatibility_version,
  )
}

/// Pure update function — returns the next model and a list of commands for
/// the effect layer to execute.
pub fn update(model: Model, message: Message) -> #(Model, List(Command)) {
  case message {
    ServiceUrlChanged(url) ->
      case accepts_settings(model.status) {
        True -> #(Model(..model, service_url: url), [])
        False -> #(model, [])
      }

    CompatibilityVersionChanged(version) ->
      case accepts_settings(model.status) {
        True -> #(Model(..model, expected_compatibility_version: version), [])
        False -> #(model, [])
      }

    NameChanged(name) ->
      case can_connect(model.status) {
        True -> #(Model(..model, name: name), [])
        False -> #(model, [])
      }

    ConnectRequested ->
      case can_connect(model.status) {
        True -> {
          let updated =
            Model(
              ..model,
              status: Connecting,
              presences: dict.new(),
              primary_client_id: "",
              secondary_connected: False,
            )
          #(updated, [GenerateScenario])
        }
        False -> #(model, [])
      }

    ScenarioCreated(id) -> {
      let topic = "demo:presence:" <> id
      #(Model(..model, topic: topic), [open_primary(model, topic)])
    }

    TransportOpened(role) -> {
      let updated = case role {
        Secondary -> model
        Primary ->
          case model.status {
            Offline | Reconnecting -> Model(..model, status: Connecting)
            Static | Connecting | Connected | Incompatible | Failed(_) -> model
          }
      }
      #(record_event(updated, "socket_open", string.inspect(role)), [])
    }

    JoinSucceeded(role, reply) -> {
      let updated = record_event(model, "phx_reply", string.inspect(reply))
      case reply.compatibility_version == model.expected_compatibility_version {
        False -> #(Model(..updated, status: Incompatible), [
          CloseAll(model.topic),
        ])
        True ->
          case role {
            Primary -> #(
              Model(
                ..updated,
                status: Connected,
                presences: reply.presence_state,
                primary_client_id: reply.client_id,
              ),
              [],
            )
            Secondary -> #(Model(..updated, secondary_connected: True), [])
          }
      }
    }

    JoinFailed(role, reason) -> {
      let updated = record_event(model, "join_error", reason)
      case protocol.decode_join_error(reason) {
        Ok(protocol.JoinError(code: 409, ..)) -> #(
          Model(..updated, status: Incompatible),
          [CloseAll(model.topic)],
        )
        Ok(_) | Error(_) -> #(Model(..updated, status: Failed(reason)), [
          CloseClient(model.topic, role),
        ])
      }
    }

    PresenceDiffReceived(diff) -> {
      let updated = record_event(model, "presence_diff", string.inspect(diff))
      #(
        Model(
          ..updated,
          presences: protocol.apply_diff(updated.presences, diff),
        ),
        [],
      )
    }

    AddSecondaryRequested ->
      case model.status == Connected && !model.secondary_connected {
        True -> #(model, [
          OpenClient(
            role: Secondary,
            service_url: model.service_url,
            topic: model.topic,
            name: model.secondary_name,
            compatibility_version: model.expected_compatibility_version,
          ),
        ])
        False -> #(model, [])
      }

    DisconnectSecondaryRequested -> #(
      Model(..model, secondary_connected: False),
      [CloseClient(model.topic, Secondary)],
    )

    TransportClosed(role, reason) -> {
      let updated =
        record_event(model, "socket_close", close_reason_to_string(reason))
      case role {
        Secondary -> #(Model(..updated, secondary_connected: False), [])
        Primary ->
          case reason {
            ReconnectExhausted | SessionExpired -> #(
              Model(..updated, status: Failed(close_reason_to_string(reason))),
              [CloseAll(model.topic)],
            )
            NetworkOffline -> #(Model(..updated, status: Offline), [])
            OtherClose(_) ->
              case model.status {
                Connected -> #(Model(..updated, status: Reconnecting), [])
                Static
                | Connecting
                | Reconnecting
                | Offline
                | Incompatible
                | Failed(_) -> #(updated, [])
              }
          }
      }
    }

    ProtocolFailed(reason) -> {
      let updated = record_event(model, "protocol_error", reason)
      #(Model(..updated, status: Failed(reason)), [CloseAll(model.topic)])
    }

    ResetRequested(new_scenario_id) -> {
      let new_topic = "demo:presence:" <> new_scenario_id
      let updated =
        Model(
          ..model,
          status: Connecting,
          topic: new_topic,
          presences: dict.new(),
          primary_client_id: "",
          secondary_connected: False,
        )
      #(updated, [CloseAll(model.topic), open_primary(model, new_topic)])
    }

    ComponentDisconnected -> #(model, [CloseAll(model.topic)])
  }
}
