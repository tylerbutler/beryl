import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}

/// A Phoenix socket connection.
pub type Socket

/// A topic subscription multiplexed over a socket.
pub type Channel

/// A pending join, leave, or message reply.
pub type Push

/// A registered callback that can be removed.
pub type Subscription

/// Create a socket that uses Phoenix's default client options.
@external(javascript, "./phoenix_ffi.mjs", "newSocket")
pub fn new_socket(url: String) -> Socket

/// Connect a socket.
@external(javascript, "./phoenix_ffi.mjs", "connect")
pub fn connect(socket: Socket) -> Nil

/// Disconnect a socket and stop automatic reconnects.
@external(javascript, "./phoenix_ffi.mjs", "disconnect")
pub fn disconnect(socket: Socket) -> Nil

/// Run a callback when the socket opens.
@external(javascript, "./phoenix_ffi.mjs", "onOpen")
pub fn on_open(socket: Socket, callback: fn() -> Nil) -> Subscription

/// Run a callback when the socket closes.
@external(javascript, "./phoenix_ffi.mjs", "onClose")
pub fn on_close(socket: Socket, callback: fn(Dynamic) -> Nil) -> Subscription

/// Run a callback when the socket reports an error.
@external(javascript, "./phoenix_ffi.mjs", "onError")
pub fn on_error(socket: Socket, callback: fn(Dynamic) -> Nil) -> Subscription

/// Create a channel for a topic and its join parameters.
@external(javascript, "./phoenix_ffi.mjs", "channel")
pub fn channel(socket: Socket, topic: String, params: Json) -> Channel

/// Join a channel.
@external(javascript, "./phoenix_ffi.mjs", "join")
pub fn join(channel: Channel) -> Push

/// Leave a channel.
@external(javascript, "./phoenix_ffi.mjs", "leave")
pub fn leave(channel: Channel) -> Push

/// Run a callback for a server event.
@external(javascript, "./phoenix_ffi.mjs", "onMessage")
pub fn on_message(
  channel: Channel,
  event: String,
  callback: fn(Dynamic) -> Nil,
) -> Subscription

/// Run a callback when a channel closes.
@external(javascript, "./phoenix_ffi.mjs", "onChannelClose")
pub fn on_channel_close(
  channel: Channel,
  callback: fn(Dynamic) -> Nil,
) -> Subscription

/// Run a callback when a channel reports an error.
@external(javascript, "./phoenix_ffi.mjs", "onChannelError")
pub fn on_channel_error(
  channel: Channel,
  callback: fn(Dynamic) -> Nil,
) -> Subscription

/// Push an event and JSON payload to a channel.
@external(javascript, "./phoenix_ffi.mjs", "push")
pub fn push(channel: Channel, event: String, payload: Json) -> Push

/// Run a callback for a successful push reply.
@external(javascript, "./phoenix_ffi.mjs", "receiveOk")
pub fn receive_ok(push: Push, callback: fn(Dynamic) -> Nil) -> Nil

/// Run a callback for an error push reply.
@external(javascript, "./phoenix_ffi.mjs", "receiveError")
pub fn receive_error(push: Push, callback: fn(Dynamic) -> Nil) -> Nil

/// Run a callback when a push times out.
@external(javascript, "./phoenix_ffi.mjs", "receiveTimeout")
pub fn receive_timeout(push: Push, callback: fn() -> Nil) -> Nil

/// Remove one registered callback.
@external(javascript, "./phoenix_ffi.mjs", "unsubscribe")
pub fn unsubscribe(subscription: Subscription) -> Nil
