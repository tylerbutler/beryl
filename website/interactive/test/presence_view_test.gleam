import beryl_site/component/presence_lab
import beryl_site/presence/model
import beryl_site/presence/protocol
import beryl_site/presence/transcript
import gleam/string
import gleeunit/should
import lustre/element

pub fn static_component_names_the_presence_lab_test() {
  presence_lab.view(presence_lab.initial_model())
  |> element.to_readable_string
  |> string.contains("Presence lab")
  |> should.be_true
}

pub fn disconnected_view_has_progressive_controls_test() {
  let rendered =
    presence_lab.view(presence_lab.initial_model())
    |> element.to_readable_string

  rendered |> string.contains("data-testid=\"primary-name\"") |> should.be_true
  rendered
  |> string.contains("data-testid=\"connect-primary\"")
  |> should.be_true
  rendered |> string.contains("aria-live=\"polite\"") |> should.be_true
}

pub fn connected_view_shows_status_and_gates_controls_test() {
  let connected_model =
    model.Model(
      ..presence_lab.initial_model(),
      status: model.Connected,
      topic: "demo:presence:abc123",
      secondary_connected: False,
    )

  let rendered =
    presence_lab.view(connected_model)
    |> element.to_readable_string

  rendered |> string.contains("Ready to connect") |> should.be_false
  rendered |> string.contains(">\n      Connected\n") |> should.be_true

  // Name input is disabled while connected.
  rendered
  |> string.contains("<input data-testid=\"primary-name\" disabled")
  |> should.be_true

  // Connect is disabled once already connected.
  rendered
  |> string.contains("<button data-testid=\"connect-primary\" disabled>")
  |> should.be_true

  // Add secondary is enabled: connected with no secondary yet.
  rendered
  |> string.contains("<button data-testid=\"add-secondary\">")
  |> should.be_true

  // Disconnect secondary is disabled: no secondary connected.
  rendered
  |> string.contains("<button data-testid=\"disconnect-secondary\" disabled>")
  |> should.be_true

  // Reset is enabled once a scenario topic exists.
  rendered
  |> string.contains("<button data-testid=\"reset-scenario\">")
  |> should.be_true

  // Connecting/Connected/Reconnecting states hide the static fallback slot.
  rendered |> string.contains("slot name=\"fallback\"") |> should.be_false
}

pub fn incompatible_view_shows_status_and_reenables_connect_test() {
  let incompatible_model =
    model.Model(..presence_lab.initial_model(), status: model.Incompatible)

  let rendered =
    presence_lab.view(incompatible_model)
    |> element.to_readable_string

  rendered
  |> string.contains(
    "Incompatible demo version; refresh the documentation page",
  )
  |> should.be_true

  // Connect stays disabled: Incompatible is not Static or Failed.
  rendered
  |> string.contains("<button data-testid=\"connect-primary\" disabled>")
  |> should.be_true

  // Incompatible is a terminal state, so the static fallback slot returns.
  rendered |> string.contains("slot name=\"fallback\"") |> should.be_true
}

pub fn failed_view_shows_reason_and_reenables_connect_test() {
  let failed_model =
    model.Model(
      ..presence_lab.initial_model(),
      status: model.Failed("session_expired"),
    )

  let rendered =
    presence_lab.view(failed_model)
    |> element.to_readable_string

  rendered
  |> string.contains("Demo failed: session_expired")
  |> should.be_true

  // Connect is re-enabled after a failure so the user can retry.
  rendered
  |> string.contains("<button data-testid=\"connect-primary\">")
  |> should.be_true

  // Name is editable again after a failure.
  rendered
  |> string.contains(
    "<input data-testid=\"primary-name\" id=\"primary-name-input\" value=\"Alice\">",
  )
  |> should.be_true

  rendered |> string.contains("slot name=\"fallback\"") |> should.be_true
}

pub fn presence_list_renders_visible_name_and_color_text_test() {
  let with_presence =
    model.Model(
      ..presence_lab.initial_model(),
      presences: protocol.state([
        #("client-1", [protocol.Meta("Alice", "emerald", "ref-1")]),
      ]),
    )

  presence_lab.view(with_presence)
  |> element.to_readable_string
  |> string.contains("Alice — emerald")
  |> should.be_true
}

pub fn transcript_renders_event_and_payload_text_test() {
  let with_transcript =
    model.Model(..presence_lab.initial_model(), transcript: [
      transcript.Entry(2, "presence_diff", "joins:client-2"),
      transcript.Entry(1, "socket_open", "Primary"),
    ])

  let rendered =
    presence_lab.view(with_transcript)
    |> element.to_readable_string

  rendered |> string.contains("presence_diff") |> should.be_true
  rendered |> string.contains("joins:client-2") |> should.be_true
  rendered |> string.contains("socket_open") |> should.be_true
  rendered |> string.contains("Primary") |> should.be_true
}
