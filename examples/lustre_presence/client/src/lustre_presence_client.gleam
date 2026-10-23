import gleam/list
import gleam/option.{type Option, None, Some}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import lustre_presence_client/channel
import lustre_presence_client/presence

pub type Connection {
  Connecting
  Connected
  Reconnecting
  Disconnected
}

pub type Model {
  Model(
    client: Option(channel.Client),
    connection: Connection,
    presence: presence.Presence,
    error: Option(String),
  )
}

pub type Message {
  ClientReady(channel.Client)
  ChannelEvent(channel.Event)
  DisconnectRequested
}

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", initial_model())
  Nil
}

pub fn initial_model() -> Model {
  Model(
    client: None,
    connection: Connecting,
    presence: presence.new(),
    error: None,
  )
}

fn init(model: Model) -> #(Model, Effect(Message)) {
  #(model, connect())
}

fn connect() -> Effect(Message) {
  effect.from(fn(dispatch) {
    let client =
      channel.connect("/socket", "page:dashboard", fn(channel_event) {
        dispatch(ChannelEvent(channel_event))
      })
    dispatch(ClientReady(client))
  })
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ClientReady(client) -> #(
      Model(..model, client: Some(client)),
      effect.none(),
    )
    ChannelEvent(channel_event) -> handle_channel_event(model, channel_event)
    DisconnectRequested -> #(
      Model(..model, client: None, connection: Disconnected, error: None),
      case model.client {
        Some(client) -> effect.from(fn(_) { channel.close(client) })
        None -> effect.none()
      },
    )
  }
}

fn handle_channel_event(
  model: Model,
  channel_event: channel.Event,
) -> #(Model, Effect(Message)) {
  case channel_event {
    channel.Connecting -> #(
      Model(..model, connection: Connecting, error: None),
      effect.none(),
    )
    channel.Connected -> #(
      Model(..model, connection: Connected, error: None),
      effect.none(),
    )
    channel.Reconnecting -> #(
      Model(..model, connection: Reconnecting),
      effect.none(),
    )
    channel.Disconnected(reason) -> #(
      Model(..model, connection: Disconnected, error: Some(reason)),
      effect.none(),
    )
    channel.DecodeFailed(_) -> #(
      Model(..model, error: Some("The server sent invalid presence data.")),
      effect.none(),
    )
    channel.Presence(event) ->
      case presence.update(model.presence, event) {
        Ok(updated) -> #(
          Model(..model, presence: updated, error: None),
          effect.none(),
        )
        Error(_) -> #(
          Model(..model, error: Some("The presence update was invalid.")),
          effect.none(),
        )
      }
  }
}

fn view(model: Model) -> Element(Message) {
  let users = presence.present_users(model.presence)

  html.main([attribute.class("presence-page")], [
    html.h1([], [html.text("Online users")]),
    html.p(
      [
        attribute.id("connection-status"),
        attribute.aria_live("polite"),
      ],
      [html.text(connection_label(model.connection))],
    ),
    view_error(model.error),
    case users {
      [] ->
        html.p([attribute.class("empty-presence")], [
          html.text("No users are online."),
        ])
      _ ->
        html.ul(
          [attribute.aria_label("Online users")],
          list.map(users, view_user),
        )
    },
    html.button(
      [
        attribute.type_("button"),
        attribute.disabled(model.connection == Disconnected),
        event.on_click(DisconnectRequested),
      ],
      [html.text("Disconnect")],
    ),
  ])
}

fn view_user(user: presence.PresentUser) -> Element(Message) {
  html.li([], [
    html.img([
      attribute.src(user.avatar_url),
      attribute.alt(""),
      attribute.width(32),
      attribute.height(32),
    ]),
    html.span([], [html.text(user.name)]),
  ])
}

fn view_error(error: Option(String)) -> Element(Message) {
  case error {
    None -> html.text("")
    Some(message) ->
      html.p([attribute.role("alert"), attribute.class("presence-error")], [
        html.text(message),
      ])
  }
}

fn connection_label(connection: Connection) -> String {
  case connection {
    Connecting -> "Connecting"
    Connected -> "Connected"
    Reconnecting -> "Reconnecting"
    Disconnected -> "Disconnected"
  }
}
