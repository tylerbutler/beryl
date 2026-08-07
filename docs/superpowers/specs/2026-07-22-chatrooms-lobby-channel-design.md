# Chatrooms Lobby Channel Design

## Goal

Add a second channel type to the chatrooms example. Each browser keeps a
`lobby` channel joined while it joins and leaves `room:*` channels. The room
list shows live user counts, demonstrating that one WebSocket connection can
multiplex channels with different scopes and lifecycles.

## Why a Lobby Channel

The existing example already joins several `room:*` topics, but every topic
uses the same chat-room behavior. A persistent `lobby` channel adds a distinct
channel type:

- `lobby` represents application-wide room activity.
- `room:*` represents membership and conversation within one room.
- Switching rooms replaces the room subscription but preserves the lobby
  subscription.

This boundary reflects a typical application: global navigation data and
room-specific interaction travel over the same socket but use separate
channels.

## Server Architecture

`chatrooms/app.gleam` handles the exact `lobby` topic separately from the
existing `room:*` pattern.

The standalone socket model stores:

- the existing dictionary of joined room models;
- an optional lobby model that records whether the socket joined `lobby`.

The lobby has no mutable domain state and accepts no client messages. A lobby
join returns a normal successful join reply. Closing the lobby clears only the
lobby model.

Successful room joins mutate the example-local session tracker before returning
a lobby invalidation. Room closes untrack the session before returning the same
invalidation. This ordering ensures the count changes before lobby subscribers
receive the event.

The invalidation event is:

```text
topic: lobby
event: rooms_changed
payload: {room: <room name>}
```

The event names the affected room for diagnostics, but clients refresh the
complete directory.

## Authoritative Room Counts

The lobby channel does not broadcast computed counts. The example-local session
tracker publishes a snapshot only for the room topic it mutates, so a
cross-topic count assembled inside `update` could race with concurrent joins.

The existing `GET /api/rooms` endpoint remains the authoritative count source.
Clients fetch it:

1. after the lobby join succeeds;
2. after each `rooms_changed` event.

This design also demonstrates a common realtime pattern: WebSocket events
invalidate data, and an HTTP endpoint returns the current snapshot.

## Client Behavior

`priv/static/app.js` keeps two channel references:

- `lobbyChannel`, joined once for the page's lifetime;
- `currentChannel`, replaced when the user switches rooms.

The client joins `lobby` before auto-joining the first room. If the lobby join
fails, chat remains available; the client logs the failure and joins the room
without live count updates.

Each room-list item contains a count badge. Counts begin in an unavailable
state and update after the first successful `/api/rooms` response.

Room refreshes use a monotonically increasing request sequence. The client
applies only the newest response, preventing a slow request from overwriting a
newer snapshot.

If a refresh fails, the client keeps the last successful counts and logs the
error. A later invalidation triggers another refresh.

## Routing and Failure Behavior

- `lobby` joins succeed.
- Client messages sent to `lobby` produce no effects.
- Closing `lobby` does not affect joined rooms.
- Closing a room does not affect the lobby subscription.
- Unknown topics remain fail-closed with the existing `unknown_topic`
  rejection.
- Rejected room joins do not broadcast `rooms_changed`.

## Interface Changes

The room list gains a compact count badge beside each room name. The badge has
an accessible label such as `2 users in general`. No new panel, modal, or
navigation mode is required.

The README explains that the browser joins `lobby` and one `room:*` topic over
the same WebSocket connection.

## Testing

Gleam tests cover:

- accepting an exact `lobby` join;
- ignoring lobby client messages;
- clearing the lobby model without changing room models;
- rejecting unrelated topics;
- emitting `rooms_changed` only after accepted room joins;
- tracking the session before join invalidation;
- untracking the session before close invalidation;
- omitting invalidation for rejected room joins.

Playwright tests cover:

- joining both `lobby` and a `room:*` topic on one socket;
- keeping `lobby` joined across room switches;
- rendering initial room counts;
- updating counts when another user joins or leaves;
- preserving the last counts when `/api/rooms` fails;
- ignoring stale overlapping room-directory responses.

Existing chat, presence, typing, authentication, and room-switching tests remain
unchanged or gain regression assertions where needed.

## Out of Scope

- Message history or unread counts.
- Cross-room announcements.
- Private notifications or direct messages.
- Lobby presence or a global user list.
- Creating, deleting, or renaming rooms.
- Replacing the existing `/api/rooms` endpoint.
