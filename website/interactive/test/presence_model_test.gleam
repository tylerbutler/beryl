import beryl_site/presence/model
import beryl_site/presence/protocol
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
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
    model.update(
      connected,
      model.TransportClosed(model.Primary, model.NetworkOffline),
    )

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
      model.TransportClosed(model.Primary, model.ReconnectExhausted),
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
      model.TransportClosed(model.Primary, model.SessionExpired),
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

pub fn unexpected_close_while_connected_enters_reconnecting_test() {
  let connected = model.Model(..model.initial(), status: model.Connected)
  let #(updated, commands) =
    model.update(
      connected,
      model.TransportClosed(model.Primary, model.OtherClose("socket_closed")),
    )

  updated.status |> should.equal(model.Reconnecting)
  commands |> should.equal([])
  let assert [newest, ..] = updated.transcript
  newest.payload |> should.equal("socket_closed")
}

pub fn close_reason_round_trips_through_strings_test() {
  ["reconnect_exhausted", "session_expired", "offline", "socket_error"]
  |> list.each(fn(raw) {
    raw
    |> model.string_to_close_reason
    |> model.close_reason_to_string
    |> should.equal(raw)
  })
}

pub fn transcript_keeps_newest_one_hundred_entries_test() {
  // int.range(1, 102, ...) iterates 1..101 inclusive (stops when current == 102)
  let recorded =
    int.range(from: 1, to: 102, with: model.initial(), run: fn(current, _index) {
      let #(next, _commands) =
        model.update(current, model.TransportOpened(model.Secondary))
      next
    })

  list.length(recorded.transcript) |> should.equal(100)
  let assert [newest, ..] = recorded.transcript
  newest.sequence |> should.equal(101)
}

pub fn reconnect_schedule_is_bounded_test() {
  model.reconnect_delay(1) |> should.equal(Some(1000))
  model.reconnect_delay(2) |> should.equal(Some(2000))
  model.reconnect_delay(3) |> should.equal(Some(5000))
  model.reconnect_delay(4) |> should.equal(Some(10_000))
  model.reconnect_delay(5) |> should.equal(Some(10_000))
  model.reconnect_delay(6) |> should.equal(None)
}
