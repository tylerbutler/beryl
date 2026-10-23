# Lustre integration plan

## Status

Proposed.

## Goal

Make it easy for a Lustre application to connect to beryl, join topics, send
and receive typed application messages, handle connection changes, and clean
up resources.

The first implementation should reuse the Phoenix JavaScript client. It
already manages the Phoenix wire protocol, heartbeats, references, reconnects,
and channel rejoins. beryl should not replace this behavior until there is a
clear need.

## Success criterion

An existing authenticated Lustre page can add an online-user display with one
server join handler, one client effect, and one Lustre `Msg` branch.

## Scope

The initial work covers:

- reuse of an existing authenticated browser session
- WebSocket connection lifecycle
- topic join and leave
- client pushes and server events
- push replies and errors
- initial presence state and presence diffs
- reconnect state
- translation of callbacks into Lustre messages
- resource cleanup when a Lustre component stops
- an example that uses shared Gleam protocol types

The initial work does not cover:

- a new channel schema language
- protocol code generation
- a pure Gleam implementation of the Phoenix client protocol
- support for every Gleam browser framework
- a general component framework around channels

## Phase 1: Build a complete Lustre example

Start with an existing Lustre site that already has authenticated users and
protected pages. Add beryl to one page to show which users are currently
online. Use a small local Gleam FFI wrapper around the Phoenix JavaScript
client.

The WebSocket endpoint should use the same origin and session as the existing
site. The browser sends its session cookie with the WebSocket handshake.
beryl's `on_connect` validates the session once and stores verified user
metadata for later topic authorization. Do not send another authentication
token in the join payload or verify the user again in the join handler.

Cookie-authenticated WebSockets must use an allowed-origin policy to prevent
cross-site WebSocket hijacking.

### Demo behavior

The authenticated page joins a page-specific topic such as
`page:dashboard`. The server uses the verified user ID as the presence key and
includes display data such as the user's name and avatar in the presence
metadata.

After it accepts the join, the server:

1. tracks the authenticated user with `PresenceTrack`
2. sends the initial roster with `PushPresence`
3. broadcasts later joins and leaves as `presence_diff` events
4. relies on beryl to remove the tracked presence when the topic or socket
   closes

Keep `AcceptJoin`, `PresenceTrack`, and `PushPresence` in that order so the
initial snapshot includes the new presence and arrives after the join
acknowledgment.

The example must show:

1. connecting to the beryl WebSocket endpoint
2. reporting connecting, connected, reconnecting, and disconnected states
3. joining and leaving a topic
4. mapping channel events to the application's Lustre `Msg` type
5. pushing an event and handling its reply
6. decoding invalid server payloads as explicit errors
7. reconnecting and rejoining without duplicate subscriptions
8. closing channels and the socket during application cleanup
9. applying `presence_state` and `presence_diff` to one typed client model
10. rendering the current authenticated users as an online-user list

The presence model should expose a small application-facing type such as
`List(PresentUser)`. The Lustre application should not need to understand the
Phoenix presence wire format.

### Deliverables

- an authenticated Lustre site with a presence-enabled page
- a beryl WebSocket route that reuses the site's session authentication
- a small Phoenix client FFI module
- a typed `PresenceEvent` and presence reducer
- browser integration tests for authentication, presence, reconnects, and
  cleanup
- a website guide based on the completed example

### Exit criteria

The example works without application-specific JavaScript other than the
small FFI boundary. Its integration code is clear enough to identify which
parts are common to other Lustre applications. The page adds presence with
one server join handler, one client effect, and one Lustre `Msg` branch.

## Phase 2: Extract a `beryl_lustre` package

Extract only the integration code that the example proves to be reusable.
Keep the package as a thin Lustre adapter over the Phoenix JavaScript client.

The likely API areas are:

- connection effects
- channel join and leave effects
- push effects with typed reply mapping
- server-event mapping into application messages
- connection-state messages
- typed presence events and a presence reducer
- explicit cleanup

A possible application-facing shape is:

```gleam
pub fn connect(
  url: String,
  topic: String,
  on_event: fn(Event) -> message,
) -> Effect(message)

pub fn update_presence(
  presence: Presence,
  event: Event,
) -> Result(Presence, PresenceError)

pub fn present_users(presence: Presence) -> List(PresentUser)
```

This is a direction, not a fixed public API. Design the final API from the
example's real call sites.

### Design requirements

- represent failures with `Result` or explicit Lustre messages
- make ownership and cleanup clear
- prevent duplicate event handlers after reconnects
- do not hide payload decoding failures
- preserve the order of events received from one channel
- keep Phoenix-specific values behind opaque Gleam types
- permit several channels on one connection
- keep session verification on the server
- hide the Phoenix presence wire format from Lustre application code

### Exit criteria

The example uses `beryl_lustre` without local connection or channel lifecycle
code. The adapter remains small and delegates protocol behavior to Phoenix
JavaScript.

## Phase 3: Share protocol types

Move application event names and payload codecs into cross-target Gleam
modules that both the BEAM server and JavaScript client can import.

For example:

```gleam
pub type ClientEvent {
  AddItem(name: String)
  DeleteItem(id: String)
}

pub type ServerEvent {
  ItemAdded(Item)
  ItemDeleted(id: String)
}

pub fn encode_client_event(event: ClientEvent) -> #(String, Json)

pub fn decode_server_event(
  name: String,
  payload: Dynamic,
) -> Result(ServerEvent, DecodeError)
```

This provides typed application messages without adding a schema language or
code generator.

### Exit criteria

The example has no duplicated event-name constants or payload definitions
between its server and browser packages.

## Phase 4: Consider a framework-neutral client

Create a JavaScript-target `beryl_client` package only if another frontend
integration needs the same connection and channel logic.

If created:

- `beryl_client` owns the framework-neutral Phoenix wrapper
- `beryl_lustre` only maps client callbacks and operations to Lustre effects
  and messages
- framework adapters share the same connection, channel, reply, and presence
  types

Do not split the package in advance. One Lustre integration does not justify
two public packages.

## Optional follow-up helpers

Add these only when examples show repeated application code:

- a connection-state model and reducer
- a bounded outbound queue during temporary disconnection
- presence reducers for `presence_state` and `presence_diff`
- standard join rejection, timeout, decode, and closure errors
- keyed channel handles for component-local cleanup
- a reusable channel component

## Deferred design

A typed channel schema and generated server and client APIs could provide more
end-to-end type safety. It would also add a schema format, generator,
compatibility policy, and build step.

Reconsider code generation only if shared Gleam protocol modules cause
measurable duplication or cannot express required compatibility rules.

## Implementation order

1. Select the existing example to convert.
2. Implement the smallest local Phoenix FFI wrapper.
3. Complete and test the Lustre client.
4. Document the integration from the working example.
5. Review the repeated integration code.
6. Extract `beryl_lustre` if the common API is clear.
7. Move event types and codecs into shared cross-target modules.
8. Evaluate `beryl_client` after a second frontend use case exists.
