---
title: Quick Start
---

:::caution[Pre-1.0 Software]
beryl is not yet 1.0. The API is unstable and features may be removed in minor releases.
:::

This guide walks you through setting up a basic real-time channel with beryl.

## 1. Add beryl to your project

```bash
gleam add beryl
```

## 2. Define a channel

Create a channel module with typed assigns and callbacks:

```gleam
import beryl/channel.{type Channel, type HandleResult, type JoinResult}
import beryl/socket.{type Socket}
import gleam/json.{type Json}
import gleam/option.{None}

/// Per-socket state for this channel
pub type ChatAssigns {
  ChatAssigns(user_id: String, username: String)
}

/// Create the channel handler
pub fn new() -> Channel(ChatAssigns) {
  channel.new(join)
  |> channel.with_handle_in(handle_in)
}

/// Handle join requests
fn join(
  topic: String,
  payload: Json,
  socket: Socket(ChatAssigns),
) -> JoinResult(ChatAssigns) {
  // Set up assigns with user info
  let assigns = ChatAssigns(user_id: "user_123", username: "alice")
  let socket = socket.set_assigns(socket, assigns)
  channel.JoinOk(reply: None, socket: socket)
}

/// Handle incoming messages
fn handle_in(
  event: String,
  payload: Json,
  socket: Socket(ChatAssigns),
) -> HandleResult(ChatAssigns) {
  case event {
    "new_message" -> {
      // Echo the message back to the sender
      channel.Reply("new_message", payload, socket)
    }
    _ -> channel.NoReply(socket)
  }
}
```

## 3. Start the channel system

Wire everything together at application startup:

```gleam
import beryl
import your_app/chat_channel

pub fn main() {
  // Start the channel system with default config
  let assert Ok(channels) = beryl.start(beryl.default_config())

  // Register the chat channel for "chat:*" topics
  let assert Ok(Nil) = beryl.register(channels, "chat:*", chat_channel.new())

  // channels.coordinator is passed to the WebSocket transport
}
```

## 4. Add WebSocket transport

In your Wisp router, upgrade WebSocket connections:

```gleam
import beryl/transport/websocket
import wisp

fn handle_request(req: wisp.Request, channels: beryl.Channels) -> wisp.Response {
  // Upgrade /socket requests to WebSocket
  use <- websocket.upgrade(
    req,
    channels.coordinator,
    websocket.default_config("/socket"),
  )

  // Fall through to regular HTTP routing
  case wisp.path_segments(req) {
    [] -> wisp.ok()
    _ -> wisp.not_found()
  }
}
```

## Next steps

- Learn about [Channels](/guides/channels/) in depth
- Add [Presence tracking](/guides/presence/) to see who's online
- Set up [PubSub](/guides/pubsub/) for distributed messaging
- Configure [WebSocket transport](/guides/websocket/) options
