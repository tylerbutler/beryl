# Chatrooms Lobby Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent `lobby` channel to the chatrooms example so one WebSocket connection carries both global room-directory updates and one active `room:*` chat subscription.

**Architecture:** The server routes the exact `lobby` topic beside the existing `room:*` pattern and broadcasts `rooms_changed` only after room presence changes. The browser joins `lobby` once, fetches authoritative counts from the existing `/api/rooms` endpoint, and keeps that subscription while replacing its active room channel.

**Tech Stack:** Gleam 1.16, Beryl app-side dispatch, Beryl presence, vanilla JavaScript, Phoenix JavaScript client, Mist, gleeunit, Playwright

## Global Constraints

- Use the exact topic `lobby` for the second channel type.
- Keep `lobby` joined while the browser switches between `room:*` topics.
- Keep `/api/rooms` as the authoritative source for room counts.
- Broadcast `rooms_changed` only after `PresenceTrack` or `PresenceUntrack`.
- Send `rooms_changed` on topic `lobby` with payload `{room: <room name>}`.
- Accept no client events on `lobby`.
- Preserve fail-closed rejection for unknown topics.
- Rejected room joins must not broadcast `rooms_changed`.
- If the lobby join fails, preserve room chat behavior without live counts.
- If `/api/rooms` fails, preserve the last successful counts.
- Ignore stale overlapping `/api/rooms` responses.
- Add no dependencies.

## File Structure

- Create `examples/chatrooms/test/chatrooms_app_test.gleam` for lobby routing and room invalidation effect tests.
- Create `examples/chatrooms/test/chatrooms_test.gleam` as the package test entrypoint.
- Modify `examples/chatrooms/src/chatrooms/app.gleam` to add the lobby model, route lobby events, and emit room-directory invalidations.
- Modify `examples/chatrooms/src/chatrooms/router.gleam` to add accessible room-count badges.
- Modify `examples/chatrooms/priv/static/app.js` to keep separate lobby and room channels and refresh room counts safely.
- Modify `examples/chatrooms/priv/static/style.css` to lay out and style room-count badges.
- Modify `examples/chatrooms/e2e/chatrooms.spec.js` to cover dual subscriptions, count refreshes, failures, stale responses, and live updates.
- Modify `examples/chatrooms/README.md` to document the second channel type and its events.

---

### Task 1: Route the Lobby Channel

**Files:**
- Create: `examples/chatrooms/test/chatrooms_app_test.gleam`
- Create: `examples/chatrooms/test/chatrooms_test.gleam`
- Modify: `examples/chatrooms/src/chatrooms/app.gleam:15-27`
- Modify: `examples/chatrooms/src/chatrooms/app.gleam:32-35`
- Modify: `examples/chatrooms/src/chatrooms/app.gleam:182-255`

**Interfaces:**
- Consumes: Existing room `join`, `update`, and `closed` functions and Beryl's ordered `Effect` list.
- Produces: `Lobby`, `lobby_join`, `lobby_update`, `lobby_closed`, and `Standalone.lobby`, consumed by Tasks 2 and 3.

- [ ] **Step 1: Add the Gleam test entrypoint**

Create `examples/chatrooms/test/chatrooms_test.gleam`:

```gleam
import gleeunit

/// Test entrypoint: gleeunit discovers and runs every `*_test` module in
/// this package.
pub fn main() {
  gleeunit.main()
}
```

- [ ] **Step 2: Write failing lobby and invalidation tests**

Create `examples/chatrooms/test/chatrooms_app_test.gleam`:

```gleam
import beryl/event
import beryl/group
import beryl/presence
import chatrooms/app
import gleam/dict
import gleam/dynamic
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should

fn context() -> app.Ctx {
  let assert Ok(presence_handle) =
    presence.start(presence.default_config("chatrooms-lobby-test"))
  let assert Ok(groups) = group.start()
  let assert Ok(_) = group.create(groups, "public")
  let assert Ok(_) = group.add(groups, "public", "room:general")
  app.Ctx(presence: presence_handle, groups: groups)
}

fn lobby_ref() -> event.Ref {
  event.make_join_ref(
    topic: "lobby",
    join_ref: Some("lobby-join"),
    msg_ref: Some("lobby-ref"),
  )
}

fn room_ref(topic: String) -> event.Ref {
  event.make_join_ref(
    topic: topic,
    join_ref: Some("room-join"),
    msg_ref: Some("room-ref"),
  )
}

fn empty_payload() -> dynamic.Dynamic {
  dynamic.properties([])
}

fn connect_info() -> event.ConnectInfo(Nil) {
  event.ConnectInfo(
    socket_id: "socket-1",
    seed: event.empty_seed(),
    self: event.make_sender(fn(_message) { Nil }),
  )
}

pub fn lobby_join_is_accepted_test() {
  let #(model, effects) = app.lobby_join(lobby_ref())

  model |> should.equal(app.Lobby)
  let assert [event.AcceptJoin(_, None)] = effects
}

pub fn lobby_messages_are_ignored_test() {
  let #(model, effects) =
    app.lobby_update(app.Lobby, "refresh", empty_payload(), None)

  model |> should.equal(app.Lobby)
  effects |> should.equal([])
}

pub fn standalone_routes_lobby_join_test() {
  let #(model, _) = app.standalone_init(connect_info())
  let next =
    app.standalone_update(
      context(),
      model,
      event.Join("lobby", empty_payload(), lobby_ref()),
    )

  let assert event.Next(
    app.Standalone(
      socket_id: _,
      rooms: _,
      lobby: Some(app.Lobby),
    ),
    [event.AcceptJoin(_, None)],
  ) = next
}

pub fn closing_lobby_preserves_room_models_test() {
  let room =
    app.Model(username: "Alice", color: "#abcdef", room_name: "general")
  let model =
    app.Standalone(
      socket_id: "socket-1",
      rooms: dict.from_list([#("room:general", room)]),
      lobby: Some(app.Lobby),
    )

  let next =
    app.standalone_update(
      context(),
      model,
      event.Closed("lobby", event.Normal),
    )

  let assert event.Next(
    app.Standalone(socket_id: _, rooms: rooms, lobby: None),
    [],
  ) = next
  dict.has_key(rooms, "room:general") |> should.be_true
}

pub fn unrelated_topic_is_rejected_test() {
  let #(model, _) = app.standalone_init(connect_info())
  let next =
    app.standalone_update(
      context(),
      model,
      event.Join(
        "notifications:alice",
        empty_payload(),
        room_ref("notifications:alice"),
      ),
    )

  let assert event.Next(_, [event.RejectJoin(_, reason)]) = next
  json.to_string(reason)
  |> should.equal("{\"reason\":\"unknown_topic\"}")
}
```

- [ ] **Step 3: Run the focused tests and confirm failure**

Run:

```bash
cd examples/chatrooms
gleam test -- --filter "lobby"
```

Expected: compilation fails because `Lobby`, `lobby_join`, `lobby_update`, and `Standalone.lobby` do not exist.

- [ ] **Step 4: Add the lobby model and functions**

In `examples/chatrooms/src/chatrooms/app.gleam`, add after `Model`:

```gleam
/// Per-socket state for the application-wide lobby topic.
pub type Lobby {
  Lobby
}
```

Add before the standalone wrapper:

```gleam
/// Accept the application-wide `lobby` topic.
pub fn lobby_join(ref: Ref) -> #(Lobby, List(Effect)) {
  #(Lobby, [event.AcceptJoin(ref, None)])
}

/// The lobby is read-only; client events produce no effects.
pub fn lobby_update(
  model: Lobby,
  _event_name: String,
  _payload: Dynamic,
  _ref: Option(Ref),
) -> #(Lobby, List(Effect)) {
  #(model, [])
}

/// Closing the lobby requires no external cleanup.
pub fn lobby_closed(_model: Lobby) -> List(Effect) {
  []
}
```

- [ ] **Step 5: Route lobby events in the standalone model**

Change `Standalone` to:

```gleam
pub type Standalone {
  Standalone(
    socket_id: String,
    rooms: Dict(String, Model),
    lobby: Option(Lobby),
  )
}
```

Change `standalone_init` to:

```gleam
#(
  Standalone(socket_id: info.socket_id, rooms: dict.new(), lobby: None),
  [],
)
```

In the `event.Join` branch, route the exact lobby topic before `room:*`:

```gleam
case topic {
  "lobby" -> {
    let #(lobby, effects) = lobby_join(ref)
    event.Next(Standalone(..model, lobby: Some(lobby)), effects)
  }
  "room:" <> _ -> {
    // Keep the existing room join body unchanged.
  }
  _ ->
    event.Next(model, [
      event.RejectJoin(
        ref,
        json.object([#("reason", json.string("unknown_topic"))]),
      ),
    ])
}
```

In the `event.Message` branch, route lobby messages before room lookup:

```gleam
case topic {
  "lobby" ->
    case model.lobby {
      Some(lobby) -> {
        let #(lobby, effects) =
          lobby_update(lobby, event_name, payload, ref)
        event.Next(Standalone(..model, lobby: Some(lobby)), effects)
      }
      None -> event.Next(model, [])
    }
  _ ->
    case dict.get(model.rooms, topic) {
      // Keep the existing room update body unchanged.
    }
}
```

In the `event.Closed` branch, route the lobby before room lookup:

```gleam
case topic {
  "lobby" ->
    case model.lobby {
      Some(lobby) ->
        event.Next(
          Standalone(..model, lobby: None),
          lobby_closed(lobby),
        )
      None -> event.Next(model, [])
    }
  _ ->
    case dict.get(model.rooms, topic) {
      // Keep the existing room close body unchanged.
    }
}
```

- [ ] **Step 6: Format and run server tests**

Run:

```bash
cd examples/chatrooms
gleam format src test
gleam test
```

Expected: all five new tests pass.

- [ ] **Step 7: Commit the server channel**

```bash
git add examples/chatrooms/src/chatrooms/app.gleam examples/chatrooms/test
git commit -m "feat(chatrooms): add lobby channel"
```

---

### Task 2: Join Both Channels and Render Initial Room Counts

**Files:**
- Modify: `examples/chatrooms/src/chatrooms/router.gleam:64-87`
- Modify: `examples/chatrooms/priv/static/app.js:11-18`
- Modify: `examples/chatrooms/priv/static/app.js:24-40`
- Modify: `examples/chatrooms/priv/static/app.js:246-250`
- Modify: `examples/chatrooms/priv/static/style.css:47-71`
- Modify: `examples/chatrooms/e2e/chatrooms.spec.js` after `Page structure`

**Interfaces:**
- Consumes: Task 1's exact `lobby` topic and the existing `GET /api/rooms` response shape `{topic, name, users}`.
- Produces: `lobbyChannel`, `refreshRoomCounts`, `updateRoomCounts`, count badges, and lobby-first startup used by Task 3.

- [ ] **Step 1: Add failing dual-channel and count tests**

Add after the `Page structure` describe block in `examples/chatrooms/e2e/chatrooms.spec.js`:

```javascript
  test.describe("Lobby channel", () => {
    test("joins lobby and a room on the same socket", async ({ page }) => {
      const joinedTopics = [];
      page.on("websocket", (ws) => {
        ws.on("framesent", (frame) => {
          try {
            const data = JSON.parse(frame.payload);
            if (Array.isArray(data) && data[3] === "phx_join") {
              joinedTopics.push(data[2]);
            }
          } catch {
            // ignore non-JSON frames
          }
        });
      });

      await gotoWithUsername(page, "LobbyUser");

      await expect.poll(() => joinedTopics).toContain("lobby");
      await expect.poll(() => joinedTopics.some((topic) =>
        topic.startsWith("room:")
      )).toBe(true);
    });

    test("renders a count badge for every room", async ({ page }) => {
      await gotoWithUsername(page, "CountUser");

      const badges = page.locator(".room-count");
      await expect(badges).toHaveCount(3);
      await expect(
        page.locator('.room-count[data-room-count="general"]')
      ).toHaveText("1", { timeout: 10_000 });
      await expect(
        page.locator('.room-count[data-room-count="random"]')
      ).toHaveText("0");
      await expect(
        page.locator('.room-count[data-room-count="help"]')
      ).toHaveText("0");
    });

  });
```

- [ ] **Step 2: Run the focused browser tests and confirm failure**

Run:

```bash
cd examples/chatrooms
npx playwright test --grep "Lobby channel"
```

Expected: tests fail because the browser never joins `lobby` and no count badges exist.

- [ ] **Step 3: Add accessible count-badge markup**

In `examples/chatrooms/src/chatrooms/router.gleam`, change each room item to:

```gleam
"<li class=\"room-item\" data-room=\""
<> name
<> "\"><span class=\"room-hash\">#</span>"
<> "<span class=\"room-name\">"
<> name
<> "</span>"
<> "<span class=\"room-count\" data-room-count=\""
<> name
<> "\" aria-label=\"User count unavailable for "
<> name
<> "\">–</span></li>"
```

- [ ] **Step 4: Style room rows and count badges**

Update `.room-item`:

```css
.room-item {
  display: flex;
  align-items: center;
  padding: 0.4rem 1rem;
  cursor: pointer;
  color: #96989d;
  font-size: 0.9rem;
  border-radius: 4px;
  margin: 1px 0.5rem;
  transition: background 0.15s, color 0.15s;
}
```

Replace `.room-hash`'s margin with:

```css
.room-hash {
  color: #96989d;
  margin-right: 4px;
}
```

Add after `.room-hash`:

```css
.room-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.room-count {
  min-width: 1.5rem;
  margin-left: auto;
  padding: 1px 5px;
  border-radius: 999px;
  background: #35373c;
  color: #b5bac1;
  font-size: 0.7rem;
  line-height: 1.3;
  text-align: center;
}

.room-item.active .room-count {
  background: #2b2d31;
  color: #fff;
}
```

- [ ] **Step 5: Add separate lobby state and safe room refreshes**

In `examples/chatrooms/priv/static/app.js`, add to state:

```javascript
  let lobbyChannel = null;
  let lobbyJoined = false;
  let roomRefreshSequence = 0;
```

After the DOM references, add:

```javascript
  async function refreshRoomCounts() {
    const requestSequence = ++roomRefreshSequence;

    try {
      const response = await fetch("/api/rooms");
      if (!response.ok) {
        throw new Error(`Room refresh failed with ${response.status}`);
      }
      const rooms = await response.json();
      if (requestSequence !== roomRefreshSequence) return;
      updateRoomCounts(rooms);
    } catch (error) {
      if (requestSequence === roomRefreshSequence) {
        console.warn("Could not refresh room counts", error);
      }
    }
  }

  function updateRoomCounts(rooms) {
    if (!Array.isArray(rooms)) return;

    const counts = new Map();
    for (const room of rooms) {
      if (
        room &&
        typeof room.name === "string" &&
        Number.isInteger(room.users) &&
        room.users >= 0
      ) {
        counts.set(room.name, room.users);
      }
    }

    document.querySelectorAll(".room-count").forEach((badge) => {
      const roomName = badge.dataset.roomCount;
      if (!counts.has(roomName)) return;
      const users = counts.get(roomName);
      badge.textContent = String(users);
      badge.setAttribute(
        "aria-label",
        `${users} ${users === 1 ? "user" : "users"} in ${roomName}`
      );
    });
  }
```

- [ ] **Step 6: Refresh counts after successful room joins**

In the existing `currentChannel.join().receive("ok", ...)` callback, add:

```javascript
        if (lobbyJoined) {
          refreshRoomCounts();
        }
```

The complete callback becomes:

```javascript
      .receive("ok", (resp) => {
        mySocketId = resp.socket_id;
        myUsername = resp.username;
        myColor = resp.color;
        if (lobbyJoined) {
          refreshRoomCounts();
        }
      })
```

- [ ] **Step 7: Join lobby before the first room**

Replace the bottom auto-join block with:

```javascript
  function joinFirstRoom() {
    const firstRoom = document.querySelector(".room-item");
    if (firstRoom) {
      joinRoom(firstRoom.dataset.room);
    }
  }

  lobbyChannel = socket.channel("lobby", {});
  lobbyChannel.join()
    .receive("ok", () => {
      lobbyJoined = true;
      joinFirstRoom();
    })
    .receive("error", (response) => {
      console.warn("Failed to join lobby", response);
      joinFirstRoom();
    });
```

Do not add the `rooms_changed` listener yet; Task 3 adds live invalidation.

- [ ] **Step 8: Run lobby and regression browser tests**

Run:

```bash
cd examples/chatrooms
npx playwright test --grep "Lobby channel|Channel join|Room switching|API"
```

Expected: all selected tests pass.

- [ ] **Step 9: Commit lobby startup and initial counts**

```bash
git add examples/chatrooms/src/chatrooms/router.gleam examples/chatrooms/priv/static/app.js examples/chatrooms/priv/static/style.css examples/chatrooms/e2e/chatrooms.spec.js
git commit -m "feat(chatrooms): show live room counts"
```

---

### Task 3: Publish and Consume Live Lobby Invalidations

**Files:**
- Modify: `examples/chatrooms/test/chatrooms_app_test.gleam`
- Modify: `examples/chatrooms/src/chatrooms/app.gleam:43-108`
- Modify: `examples/chatrooms/src/chatrooms/app.gleam:165-180`
- Modify: `examples/chatrooms/src/chatrooms/app.gleam:296-302`
- Modify: `examples/chatrooms/priv/static/app.js` beside the Task 2 lobby join
- Modify: `examples/chatrooms/e2e/chatrooms.spec.js` after the Lobby channel tests

**Interfaces:**
- Consumes: Task 1's lobby routing and Task 2's `lobbyChannel` and `refreshRoomCounts`.
- Produces: Ordered `rooms_changed` broadcasts and live room counts that survive room switches while the lobby remains joined.

- [ ] **Step 1: Add failing server invalidation tests**

Append to `examples/chatrooms/test/chatrooms_app_test.gleam`:

```gleam
pub fn accepted_room_join_invalidates_lobby_after_presence_track_test() {
  let #(joined, effects) =
    app.join(
      context(),
      "socket-1",
      "room:general",
      dynamic.properties([
        #(dynamic.string("username"), dynamic.string("Alice")),
      ]),
      room_ref("room:general"),
    )

  joined |> should.be_some
  let assert [
    event.AcceptJoin(_, _),
    event.PresenceTrack("room:general", "Alice", _),
    event.Broadcast("lobby", "rooms_changed", changed),
    event.Broadcast("room:general", "new_msg", _),
    event.BroadcastPresence("room:general", "presence_list", _),
  ] = effects
  json.to_string(changed) |> should.equal("{\"room\":\"general\"}")
}

pub fn rejected_room_join_does_not_invalidate_lobby_test() {
  let #(joined, effects) =
    app.join(
      context(),
      "socket-1",
      "room:missing",
      empty_payload(),
      room_ref("room:missing"),
    )

  joined |> should.be_none
  let assert [event.RejectJoin(_, _)] = effects
}

pub fn room_close_invalidates_lobby_after_presence_untrack_test() {
  let model =
    app.Model(username: "Alice", color: "#abcdef", room_name: "general")
  let effects =
    app.closed(context(), "socket-1", "room:general", model)

  let assert [
    event.PresenceUntrack("room:general", "Alice"),
    event.Broadcast("lobby", "rooms_changed", changed),
    event.Broadcast("room:general", "new_msg", _),
    event.BroadcastPresence("room:general", "presence_list", _),
  ] = effects
  json.to_string(changed) |> should.equal("{\"room\":\"general\"}")
}
```

- [ ] **Step 2: Run server invalidation tests and confirm failure**

Run:

```bash
cd examples/chatrooms
gleam test -- --filter "invalidate"
```

Expected: the accepted join and room close tests fail because no `rooms_changed` broadcast exists.

- [ ] **Step 3: Add ordered room invalidations**

In the successful room join effect list, insert the lobby broadcast immediately after `PresenceTrack`:

```gleam
event.Broadcast("lobby", "rooms_changed", room_changed(room_name)),
```

The complete success effect list must be:

```gleam
[
  event.AcceptJoin(ref, Some(reply)),
  event.PresenceTrack(topic, username, meta),
  event.Broadcast("lobby", "rooms_changed", room_changed(room_name)),
  event.Broadcast(topic, "new_msg", sys_payload),
  event.BroadcastPresence(topic, "presence_list", encode_users),
]
```

In `closed`, place the lobby broadcast immediately after `PresenceUntrack`:

```gleam
[
  event.PresenceUntrack(topic, model.username),
  event.Broadcast("lobby", "rooms_changed", room_changed(model.room_name)),
  event.Broadcast(topic, "new_msg", sys_payload),
  event.BroadcastPresence(topic, "presence_list", encode_users),
]
```

Add beside `system_message`:

```gleam
fn room_changed(room_name: String) -> json.Json {
  json.object([#("room", json.string(room_name))])
}
```

- [ ] **Step 4: Run server tests**

Run:

```bash
cd examples/chatrooms
gleam format src test
gleam test
```

Expected: all eight lobby and invalidation tests pass.

- [ ] **Step 5: Add failing live-update browser tests**

Add after the Lobby channel describe block:

```javascript
  test.describe("Live lobby updates", () => {
    test("updates room counts when another user joins and leaves", async ({
      browser,
    }) => {
      const context1 = await browser.newContext();
      const context2 = await browser.newContext();
      const page1 = await context1.newPage();
      const page2 = await context2.newPage();

      try {
        await gotoWithUsername(page1, "Observer");
        await expect(
          page1.locator('.room-count[data-room-count="general"]')
        ).toHaveText("1", { timeout: 10_000 });

        await gotoWithUsername(page2, "Joiner");
        await expect(
          page1.locator('.room-count[data-room-count="general"]')
        ).toHaveText("2", { timeout: 10_000 });

        await context2.close();
        await expect(
          page1.locator('.room-count[data-room-count="general"]')
        ).toHaveText("1", { timeout: 10_000 });
      } finally {
        await context1.close();
        await context2.close().catch(() => {});
      }
    });

    test("keeps lobby joined while switching rooms", async ({ page }) => {
      const leaves = [];
      page.on("websocket", (ws) => {
        ws.on("framesent", (frame) => {
          try {
            const data = JSON.parse(frame.payload);
            if (Array.isArray(data) && data[3] === "phx_leave") {
              leaves.push(data[2]);
            }
          } catch {
            // ignore non-JSON frames
          }
        });
      });

      await gotoWithUsername(page, "Switcher");
      await expect(
        page.locator('.room-count[data-room-count="general"]')
      ).toHaveText("1", { timeout: 10_000 });

      await page.locator('.room-item[data-room="random"]').click();
      await expect(page.locator(".room-item.active")).toContainText("random");
      await expect(
        page.locator('.room-count[data-room-count="general"]')
      ).toHaveText("0", { timeout: 10_000 });
      await expect(
        page.locator('.room-count[data-room-count="random"]')
      ).toHaveText("1", { timeout: 10_000 });

      expect(leaves).toContain("room:general");
      expect(leaves).not.toContain("lobby");
    });

    test("keeps the last counts when a live refresh fails", async ({
      browser,
    }) => {
      const context1 = await browser.newContext();
      const context2 = await browser.newContext();
      const page1 = await context1.newPage();
      const page2 = await context2.newPage();
      let failRefreshes = false;
      let failedRequests = 0;

      await page1.route("**/api/rooms", async (route) => {
        if (failRefreshes) {
          failedRequests += 1;
          await route.fulfill({ status: 503, body: "unavailable" });
        } else {
          await route.continue();
        }
      });

      try {
        await gotoWithUsername(page1, "FailureObserver");
        await expect(
          page1.locator('.room-count[data-room-count="general"]')
        ).toHaveText("1", { timeout: 10_000 });

        failRefreshes = true;
        await gotoWithUsername(page2, "FailureJoiner");
        await expect.poll(() => failedRequests).toBeGreaterThan(0);
        await expect(
          page1.locator('.room-count[data-room-count="general"]')
        ).toHaveText("1");
      } finally {
        await context1.close();
        await context2.close();
      }
    });

    test("ignores a stale overlapping live refresh", async ({ browser }) => {
      const context1 = await browser.newContext();
      const context2 = await browser.newContext();
      const page1 = await context1.newPage();
      const page2 = await context2.newPage();
      let raceMode = false;
      let delayedRequestSeen = false;

      await page1.route("**/api/rooms", async (route) => {
        if (!raceMode) {
          await route.continue();
        } else if (!delayedRequestSeen) {
          delayedRequestSeen = true;
          await new Promise((resolve) => setTimeout(resolve, 300));
          await route.fulfill({
            status: 200,
            contentType: "application/json",
            body: JSON.stringify([
              { topic: "room:general", name: "general", users: 9 },
              { topic: "room:random", name: "random", users: 0 },
              { topic: "room:help", name: "help", users: 0 },
            ]),
          });
        } else {
          await route.fulfill({
            status: 200,
            contentType: "application/json",
            body: JSON.stringify([
              { topic: "room:general", name: "general", users: 1 },
              { topic: "room:random", name: "random", users: 1 },
              { topic: "room:help", name: "help", users: 0 },
            ]),
          });
        }
      });

      try {
        await gotoWithUsername(page1, "RaceObserver");
        await expect(
          page1.locator('.room-count[data-room-count="general"]')
        ).toHaveText("1", { timeout: 10_000 });

        raceMode = true;
        await gotoWithUsername(page2, "RaceJoiner");
        await expect.poll(() => delayedRequestSeen).toBe(true);
        await page2.locator('.room-item[data-room="random"]').click();

        await expect(
          page1.locator('.room-count[data-room-count="general"]')
        ).toHaveText("1", { timeout: 10_000 });
        await expect(
          page1.locator('.room-count[data-room-count="random"]')
        ).toHaveText("1", { timeout: 10_000 });
        await page1.waitForTimeout(350);
        await expect(
          page1.locator('.room-count[data-room-count="general"]')
        ).toHaveText("1");
      } finally {
        await context1.close();
        await context2.close();
      }
    });
  });
```

- [ ] **Step 6: Run live-update tests and confirm failure**

Run:

```bash
cd examples/chatrooms
npx playwright test --grep "Live lobby updates"
```

Expected: counts remain stale because the client does not handle `rooms_changed`.

- [ ] **Step 7: Subscribe to lobby invalidations**

Immediately after creating `lobbyChannel`, add:

```javascript
  lobbyChannel.on("rooms_changed", () => {
    refreshRoomCounts();
  });
```

- [ ] **Step 8: Run focused and full browser tests**

Run:

```bash
cd examples/chatrooms
npx playwright test --grep "Lobby channel|Live lobby updates|Room switching|Multi-user presence"
npm test
```

Expected: focused tests and the complete chatrooms Playwright suite pass.

- [ ] **Step 9: Commit live invalidation handling**

```bash
git add examples/chatrooms/src/chatrooms/app.gleam examples/chatrooms/test/chatrooms_app_test.gleam examples/chatrooms/priv/static/app.js examples/chatrooms/e2e/chatrooms.spec.js
git commit -m "feat(chatrooms): refresh counts from lobby"
```

---

### Task 4: Document and Verify the Two-Channel Demo

**Files:**
- Modify: `examples/chatrooms/README.md:3-24`
- Modify: `examples/chatrooms/README.md:26-55`
- Modify: `examples/chatrooms/README.md:71-83`

**Interfaces:**
- Consumes: The completed lobby and room channel behavior.
- Produces: Documentation and final verification evidence matching the implementation.

- [ ] **Step 1: Update the feature list and architecture**

Add after the multi-room chat feature:

```markdown
- 🧭 **Persistent lobby channel** — one socket stays joined to `lobby` while switching between `room:*` topics
- 🔢 **Live room counts** — lobby invalidations refresh authoritative counts from `/api/rooms`
```

Add these rows to **beryl Features Exercised**:

```markdown
| **Multiple channel types** | `beryl/event` | Exact `lobby` topic plus wildcard `room:*` topics on one socket |
| **Ordered effects** | `beryl/event` | Presence changes apply before lobby invalidations |
```

Replace the app-side dispatch architecture line with:

```text
  ├── beryl app-side dispatch
  │   ├── lobby (persistent room-directory invalidation channel)
  │   └── room:* (replaceable chat-room channels)
```

- [ ] **Step 2: Document lobby events**

Add to the Channel Events table:

```markdown
| Server → Client | `rooms_changed` on `lobby` | Invalidate room counts after room membership changes `{room}` |
```

Add after the table:

```markdown
The browser joins `lobby` once and keeps it joined while replacing its active
`room:*` channel. `rooms_changed` invalidates the directory; the browser then
loads the current counts from `GET /api/rooms`.
```

- [ ] **Step 3: Format and test the chatrooms example**

Run:

```bash
cd examples/chatrooms
gleam format src test
gleam check
gleam test
npm test
```

Expected: formatting completes, Gleam checks pass, all eight Gleam tests pass, and the complete Playwright suite passes.

- [ ] **Step 4: Run workspace validation**

Run from the repository root:

```bash
just format-check
just check
just test
```

Expected: all workspace formatting, type checks, and tests pass.

- [ ] **Step 5: Remove generated browser artifacts**

Remove only generated chatrooms test output:

```bash
rm -rf examples/chatrooms/test-results examples/chatrooms/playwright-report
```

Expected: `git status --short` lists only intended source, test, and documentation changes plus any pre-existing unrelated files.

- [ ] **Step 6: Commit documentation and formatting**

```bash
git add examples/chatrooms/README.md examples/chatrooms/src examples/chatrooms/test examples/chatrooms/priv/static examples/chatrooms/e2e/chatrooms.spec.js
git commit -m "docs(chatrooms): describe lobby channel"
```
