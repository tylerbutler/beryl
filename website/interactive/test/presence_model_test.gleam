import beryl_site/presence/model
import beryl_site/presence/protocol
import gleam/dict
import gleeunit/should

pub fn connect_requests_a_fresh_scenario_test() {
  let #(updated, commands) =
    model.update(model.initial(), model.ConnectRequested)
  updated.status |> should.equal(model.Connecting)
  commands |> should.equal([model.GenerateScenario])
}

pub fn scenario_creation_opens_primary_client_test() {
  let connecting =
    model.Model(..model.initial(), status: model.Connecting, name: "Alice")
  let #(updated, commands) =
    model.update(
      connecting,
      model.ScenarioCreated("0123456789abcdef0123456789abcdef"),
    )

  updated.topic
  |> should.equal("demo:presence:0123456789abcdef0123456789abcdef")
  commands
  |> should.equal([
    model.OpenClient(
      role: model.Primary,
      service_url: "https://demos.beryl.tylerbutler.com",
      topic: "demo:presence:0123456789abcdef0123456789abcdef",
      name: "Alice",
      compatibility_version: 1,
    ),
  ])
}

pub fn incompatible_join_disconnects_all_clients_test() {
  let reply =
    protocol.JoinReply(
      compatibility_version: 99,
      client_id: "client-a",
      presence_state: dict.new(),
    )
  let current =
    model.Model(
      ..model.initial(),
      topic: "demo:presence:0123456789abcdef0123456789abcdef",
    )
  let #(updated, commands) =
    model.update(current, model.JoinSucceeded(model.Primary, reply))

  updated.status |> should.equal(model.Incompatible)
  commands
  |> should.equal([
    model.CloseAll("demo:presence:0123456789abcdef0123456789abcdef"),
  ])
}

pub fn offline_close_preserves_client_for_phoenix_reconnect_test() {
  let connected = model.Model(..model.initial(), status: model.Connected)
  let #(updated, commands) =
    model.update(connected, model.TransportClosed(model.Primary, "offline"))

  updated.status |> should.equal(model.Offline)
  commands |> should.equal([])
}

pub fn reconnect_exhausted_enters_failed_and_closes_all_test() {
  let connected =
    model.Model(
      ..model.initial(),
      status: model.Connected,
      topic: "demo:presence:0123456789abcdef0123456789abcdef",
    )
  let #(updated, commands) =
    model.update(
      connected,
      model.TransportClosed(model.Primary, "reconnect_exhausted"),
    )

  updated.status |> should.equal(model.Failed("reconnect_exhausted"))
  commands
  |> should.equal([
    model.CloseAll("demo:presence:0123456789abcdef0123456789abcdef"),
  ])
}

pub fn expired_session_stops_reconnects_test() {
  let connected =
    model.Model(
      ..model.initial(),
      status: model.Connected,
      topic: "demo:presence:0123456789abcdef0123456789abcdef",
    )
  let #(updated, commands) =
    model.update(
      connected,
      model.TransportClosed(model.Primary, "session_expired"),
    )

  updated.status |> should.equal(model.Failed("session_expired"))
  commands
  |> should.equal([
    model.CloseAll("demo:presence:0123456789abcdef0123456789abcdef"),
  ])
}

pub fn name_changed_accepted_in_failed_state_test() {
  let failed =
    model.Model(..model.initial(), status: model.Failed("reconnect_exhausted"))
  let #(updated, commands) = model.update(failed, model.NameChanged("Charlie"))

  updated.name |> should.equal("Charlie")
  commands |> should.equal([])
}

pub fn reset_closes_old_topic_and_opens_new_test() {
  let old_topic = "demo:presence:0123456789abcdef0123456789abcdef"
  let new_id = "fedcba9876543210fedcba9876543210"
  let new_topic = "demo:presence:" <> new_id
  let current =
    model.Model(
      ..model.initial(),
      status: model.Connected,
      topic: old_topic,
      name: "Alice",
      secondary_connected: True,
      presences: dict.from_list([
        #("client-x", [
          protocol.Meta(name: "Alice", color: "#ff0000", phx_ref: "ref-1"),
        ]),
      ]),
    )
  let #(updated, commands) = model.update(current, model.ResetRequested(new_id))

  updated.status |> should.equal(model.Connecting)
  updated.topic |> should.equal(new_topic)
  updated.presences |> should.equal(dict.new())
  updated.primary_client_id |> should.equal("")
  updated.secondary_connected |> should.equal(False)
  commands
  |> should.equal([
    model.CloseAll(old_topic),
    model.OpenClient(
      role: model.Primary,
      service_url: "https://demos.beryl.tylerbutler.com",
      topic: new_topic,
      name: "Alice",
      compatibility_version: 1,
    ),
  ])
}
