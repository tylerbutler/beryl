import beryl_site/presence/model
import beryl_site/presence/protocol
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/list
import lustre/attribute
import lustre/component
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const styles = "
:host {
  display: block;
  color: var(--sl-color-gray-1, #e8f2ed);
}
*, *::before, *::after {
  box-sizing: border-box;
}
.lab {
  border: 1px solid var(--beryl-hairline, #48665a);
  border-radius: 16px;
  background: var(--beryl-surface, #173126);
  padding: clamp(1rem, 3vw, 1.5rem);
  max-width: 100%;
}
.controls {
  display: flex;
  flex-wrap: wrap;
  gap: 0.375rem;
}
code, li {
  overflow-wrap: break-word;
  word-break: break-word;
}
button:focus-visible,
input:focus-visible {
  outline: 2px solid var(--beryl-ring, #65d99b);
  outline-offset: 2px;
}
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { transition: none !important; }
}
"

@external(javascript, "../phoenix_ffi.mjs", "setResetToken")
fn set_reset_token(event: dynamic.Dynamic) -> Nil

pub fn view(current: model.Model) -> Element(model.Message) {
  html.section([attribute.aria_labelledby("presence-lab-title")], [
    html.style([], styles),
    html.div([attribute.class("lab")], [
      html.h2([attribute.id("presence-lab-title")], [
        html.text("Presence lab"),
      ]),
      status_region(current),
      scenario_topic(current),
      name_field(current),
      controls(current),
      presence_list(current),
      event_transcript(current),
      fallback_slot(current),
    ]),
  ])
}

fn status_text(status: model.Status) -> String {
  case status {
    model.Static -> "Ready to connect"
    model.Connecting -> "Connecting"
    model.Connected -> "Connected"
    model.Reconnecting -> "Connection lost; reconnecting"
    model.Offline -> "Offline; reconnecting when the network returns"
    model.Incompatible ->
      "Incompatible demo version; refresh the documentation page"
    model.Failed(reason) -> "Demo failed: " <> reason
  }
}

fn status_region(current: model.Model) -> Element(model.Message) {
  html.div(
    [
      attribute.role("status"),
      attribute.aria_live("polite"),
      attribute.attribute("data-testid", "presence-status"),
    ],
    [html.text(status_text(current.status))],
  )
}

fn scenario_topic(current: model.Model) -> Element(model.Message) {
  html.code([attribute.attribute("data-testid", "scenario-topic")], [
    html.text(current.topic),
  ])
}

fn name_disabled(status: model.Status) -> Bool {
  case status {
    model.Connecting
    | model.Connected
    | model.Reconnecting
    | model.Offline
    | model.Incompatible -> True
    model.Static | model.Failed(_) -> False
  }
}

fn name_field(current: model.Model) -> Element(model.Message) {
  html.div([], [
    html.label([attribute.for("primary-name-input")], [html.text("Name")]),
    html.input([
      attribute.id("primary-name-input"),
      attribute.attribute("data-testid", "primary-name"),
      attribute.value(current.name),
      attribute.disabled(name_disabled(current.status)),
      event.on_input(model.NameChanged),
    ]),
  ])
}

fn add_secondary_enabled(current: model.Model) -> Bool {
  current.status == model.Connected && !current.secondary_connected
}

fn controls(current: model.Model) -> Element(model.Message) {
  html.div([attribute.class("controls")], [
    html.button(
      [
        attribute.attribute("data-testid", "connect-primary"),
        attribute.disabled(!model.can_connect(current.status)),
        event.on_click(model.ConnectRequested),
      ],
      [html.text("Connect")],
    ),
    html.button(
      [
        attribute.attribute("data-testid", "add-secondary"),
        attribute.disabled(!add_secondary_enabled(current)),
        event.on_click(model.AddSecondaryRequested),
      ],
      [html.text("Add secondary")],
    ),
    html.button(
      [
        attribute.attribute("data-testid", "disconnect-secondary"),
        attribute.disabled(!current.secondary_connected),
        event.on_click(model.DisconnectSecondaryRequested),
      ],
      [html.text("Disconnect secondary")],
    ),
    html.button(
      [
        attribute.attribute("data-testid", "reset-scenario"),
        attribute.disabled(current.topic == ""),
        event.on(
          "click",
          // Sets a host attribute then deliberately fails: Lustre's synchronous
          // attribute-change flush routes the reset token without a stale rAF-render race.
          decode.then(decode.dynamic, fn(click_event) {
            set_reset_token(click_event)
            decode.failure(
              model.ConnectRequested,
              "reset-handled-via-attribute",
            )
          }),
        ),
      ],
      [html.text("Reset")],
    ),
  ])
}

fn presence_list(current: model.Model) -> Element(model.Message) {
  let items =
    current.presences
    |> dict.to_list
    |> list.flat_map(fn(entry) {
      let #(_client_id, metas) = entry
      list.map(metas, presence_item)
    })

  html.ul([attribute.attribute("data-testid", "presence-list")], items)
}

fn presence_item(meta: protocol.Meta) -> Element(model.Message) {
  html.li([], [
    html.span([attribute.aria_hidden(True)], [swatch(meta.color)]),
    html.text(meta.name <> " — " <> meta.color),
  ])
}

fn swatch(color: String) -> Element(model.Message) {
  html.span(
    [
      attribute.class("swatch"),
      attribute.attribute("style", "background-color: " <> color <> ";"),
    ],
    [],
  )
}

fn event_transcript(current: model.Model) -> Element(model.Message) {
  html.ol(
    [attribute.attribute("data-testid", "event-transcript")],
    list.map(current.transcript, transcript_item),
  )
}

fn transcript_item(entry: model.Entry) -> Element(model.Message) {
  html.li([], [
    html.text(int.to_string(entry.sequence) <> " " <> entry.event <> " "),
    html.text(entry.payload),
  ])
}

fn wants_fallback(status: model.Status) -> Bool {
  case status {
    model.Static | model.Offline | model.Incompatible | model.Failed(_) -> True
    model.Connecting | model.Connected | model.Reconnecting -> False
  }
}

fn fallback_slot(current: model.Model) -> Element(model.Message) {
  case wants_fallback(current.status) {
    False -> element.none()
    True ->
      component.named_slot("fallback", [], [
        html.p([], [
          html.text(
            "Static preview only. Connect to see the live presence demo.",
          ),
        ]),
      ])
  }
}
