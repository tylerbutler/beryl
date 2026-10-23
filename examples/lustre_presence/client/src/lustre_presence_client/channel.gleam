import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import lustre_presence_client/phoenix
import lustre_presence_client/presence

pub opaque type Client {
  Client(
    socket: phoenix.Socket,
    channel: phoenix.Channel,
    subscriptions: List(phoenix.Subscription),
  )
}

pub type Event {
  Connecting
  Connected
  Reconnecting
  Disconnected(String)
  Presence(presence.PresenceEvent)
  DecodeFailed(presence.PresenceError)
}

pub type PushError {
  Rejected(Dynamic)
  TimedOut
}

pub fn connect(
  url: String,
  topic: String,
  on_event: fn(Event) -> Nil,
) -> Client {
  on_event(Connecting)

  let socket = phoenix.new_socket(url)
  let channel = phoenix.channel(socket, topic, json.object([]))
  let subscriptions = [
    phoenix.on_close(socket, fn(_) { on_event(Reconnecting) }),
    phoenix.on_error(socket, fn(_) { on_event(Reconnecting) }),
    phoenix.on_channel_close(channel, fn(_) {
      on_event(Disconnected("The channel closed."))
    }),
    phoenix.on_channel_error(channel, fn(_) { on_event(Reconnecting) }),
    phoenix.on_message(channel, "presence_state", fn(payload) {
      case presence.decode_state(payload) {
        Ok(event) -> on_event(Presence(event))
        Error(error) -> on_event(DecodeFailed(error))
      }
    }),
    phoenix.on_message(channel, "presence_diff", fn(payload) {
      case presence.decode_diff(payload) {
        Ok(event) -> on_event(Presence(event))
        Error(error) -> on_event(DecodeFailed(error))
      }
    }),
    phoenix.on_page_hide(fn() {
      let _ = phoenix.leave(channel)
      phoenix.disconnect(socket)
    }),
  ]

  let pending_join = phoenix.join(channel)
  phoenix.receive_ok(pending_join, fn(_) { on_event(Connected) })
  phoenix.receive_error(pending_join, fn(_) {
    on_event(Disconnected("The server rejected the channel join."))
  })
  phoenix.receive_timeout(pending_join, fn() {
    on_event(Disconnected("The channel join timed out."))
  })
  phoenix.connect(socket)

  Client(socket:, channel:, subscriptions:)
}

pub fn push(
  client: Client,
  event: String,
  payload: json.Json,
  callback: fn(Result(Dynamic, PushError)) -> Nil,
) -> Nil {
  let Client(channel:, ..) = client
  let pending = phoenix.push(channel, event, payload)
  phoenix.receive_ok(pending, fn(reply) { callback(Ok(reply)) })
  phoenix.receive_error(pending, fn(reply) { callback(Error(Rejected(reply))) })
  phoenix.receive_timeout(pending, fn() { callback(Error(TimedOut)) })
}

pub fn close(client: Client) -> Nil {
  let Client(socket:, channel:, subscriptions:) = client
  list.each(subscriptions, phoenix.unsubscribe)
  let _ = phoenix.leave(channel)
  phoenix.disconnect(socket)
}
