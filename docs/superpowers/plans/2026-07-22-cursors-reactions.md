# Cursors Reactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a selectable reaction toolbar to the cursors example and broadcast click-positioned reactions that rise and fade for every connected user.

**Architecture:** The browser owns toolbar state and ephemeral animation nodes. It sends a dedicated `reaction` event with an allowed emoji and normalized coordinates; the Gleam app validates the payload and broadcasts it to every other socket without storing reaction state.

**Tech Stack:** Gleam 1.16, beryl app-side dispatch, vanilla JavaScript, CSS animations, Phoenix JS client, gleeunit, Playwright

## Global Constraints

- Offer exactly `👍`, `❤️`, `😂`, `🎉`, and `🔥`.
- Start with `👍` selected; selecting the active reaction again clears the selection.
- Keep selection active across canvas clicks until the user changes or clears it.
- Use a dedicated `reaction` event with `{ reaction, x, y }`.
- Normalize `x` and `y` to the inclusive range `0.0` through `1.0`.
- Broadcast reactions to every other socket with `BroadcastFrom`; render the sender's reaction locally.
- Store no reaction history or server-side reaction state.
- Remove each reaction node after its animation.
- Preserve a reduced-motion fade.
- Add no dependencies.

## File Structure

- Create `examples/cursors/test/cursors_app_test.gleam` for reaction payload validation and effect tests.
- Modify `examples/cursors/src/cursors/app.gleam` to decode, validate, and broadcast reaction events.
- Modify `examples/cursors/src/cursors/router.gleam` to render the accessible reaction toolbar.
- Modify `examples/cursors/priv/static/app.js` to manage selection, local animation, normalized sends, and remote rendering.
- Modify `examples/cursors/priv/static/style.css` to style the toolbar and reaction animations.
- Modify `examples/cursors/e2e/cursors.spec.js` to cover toolbar behavior, animation cleanup, wire payloads, and multi-user rendering.
- Modify `examples/cursors/README.md` to describe reactions in the demo and architecture.

---

### Task 1: Validate and Broadcast Reaction Events

**Files:**
- Create: `examples/cursors/test/cursors_app_test.gleam`
- Modify: `examples/cursors/src/cursors/app.gleam:12-21`
- Modify: `examples/cursors/src/cursors/app.gleam:65-88`
- Modify: `examples/cursors/src/cursors/app.gleam:189-208`

**Interfaces:**
- Consumes: Existing `app.update(Ctx, String, String, Model, String, Dynamic) -> #(Model, List(Effect))`
- Produces: `reaction` handling that emits `event.BroadcastFrom(topic, "reaction", payload)` only for supported emoji and normalized coordinates

- [ ] **Step 1: Write failing Gleam tests**

Create `examples/cursors/test/cursors_app_test.gleam`:

```gleam
import beryl/event
import beryl/presence
import cursors/app
import gleam/dynamic
import gleam/json
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn context() -> app.Ctx {
  let assert Ok(handle) =
    presence.start(presence.default_config("cursors-reaction-test"))
  app.Ctx(presence: handle)
}

fn model() -> app.Model {
  app.Model(username: "Alice", color: "#abcdef")
}

fn reaction_payload(
  reaction: String,
  x: dynamic.Dynamic,
  y: dynamic.Dynamic,
) -> dynamic.Dynamic {
  dynamic.properties([
    #(dynamic.string("reaction"), dynamic.string(reaction)),
    #(dynamic.string("x"), x),
    #(dynamic.string("y"), y),
  ])
}

pub fn supported_reactions_broadcast_test() {
  ["👍", "❤️", "😂", "🎉", "🔥"]
  |> list.each(fn(reaction) {
    let #(_, effects) =
      app.update(
        context(),
        "socket-1",
        "cursor:lobby",
        model(),
        "reaction",
        reaction_payload(reaction, dynamic.float(0.25), dynamic.float(0.75)),
      )

    let assert [
      event.BroadcastFrom("cursor:lobby", "reaction", payload),
    ] = effects
    json.to_string(payload)
    |> should.equal(
      "{\"reaction\":\"" <> reaction <> "\",\"x\":0.25,\"y\":0.75}",
    )
  })
}

pub fn integer_boundary_coordinates_broadcast_test() {
  let #(_, effects) =
    app.update(
      context(),
      "socket-1",
      "cursor:lobby",
      model(),
      "reaction",
      reaction_payload("👍", dynamic.int(0), dynamic.int(1)),
    )

  let assert [
    event.BroadcastFrom("cursor:lobby", "reaction", payload),
  ] = effects
  json.to_string(payload)
  |> should.equal("{\"reaction\":\"👍\",\"x\":0.0,\"y\":1.0}")
}

pub fn invalid_reaction_payloads_are_dropped_test() {
  let missing_y =
    dynamic.properties([
      #(dynamic.string("reaction"), dynamic.string("👍")),
      #(dynamic.string("x"), dynamic.float(0.5)),
    ])
  let invalid_payloads = [
    reaction_payload("👎", dynamic.float(0.5), dynamic.float(0.5)),
    reaction_payload("👍", dynamic.float(-0.1), dynamic.float(0.5)),
    reaction_payload("👍", dynamic.float(0.5), dynamic.float(1.1)),
    reaction_payload("👍", dynamic.string("middle"), dynamic.float(0.5)),
    missing_y,
  ]

  invalid_payloads
  |> list.each(fn(payload) {
    let #(_, effects) =
      app.update(
        context(),
        "socket-1",
        "cursor:lobby",
        model(),
        "reaction",
        payload,
      )
    effects |> should.equal([])
  })
}

pub fn cursor_move_behavior_is_unchanged_test() {
  let payload =
    dynamic.properties([
      #(dynamic.string("x"), dynamic.int(12)),
      #(dynamic.string("y"), dynamic.int(34)),
    ])
  let #(_, effects) =
    app.update(
      context(),
      "socket-1",
      "cursor:lobby",
      model(),
      "cursor_move",
      payload,
    )

  let assert [
    event.BroadcastFrom("cursor:lobby", "cursor_move", broadcast),
  ] = effects
  json.to_string(broadcast)
  |> should.equal(
    "{\"socket_id\":\"socket-1\",\"x\":12,\"y\":34,\"username\":\"Alice\",\"color\":\"#abcdef\"}",
  )
}
```

- [ ] **Step 2: Run the focused tests and confirm failure**

Run:

```bash
cd examples/cursors
gleam test -- --filter "reaction"
```

Expected: `supported_reactions_broadcast_test` fails because `app.update` returns no effects for `reaction`.

- [ ] **Step 3: Implement strict reaction decoding**

In `examples/cursors/src/cursors/app.gleam`, add `gleam/int` to the imports and add the supported set:

```gleam
import gleam/int

const supported_reactions = ["👍", "❤️", "😂", "🎉", "🔥"]
```

Add the `reaction` branch immediately after `cursor_move`:

```gleam
    "reaction" ->
      case decode_reaction(payload) {
        Some(#(reaction, x, y)) -> {
          let reaction_payload =
            json.object([
              #("reaction", json.string(reaction)),
              #("x", json.float(x)),
              #("y", json.float(y)),
            ])
          #(model, [
            event.BroadcastFrom(topic, "reaction", reaction_payload),
          ])
        }
        None -> #(model, [])
      }
```

Add these private helpers above `extract_json_number`:

```gleam
fn decode_reaction(payload: Dynamic) -> Option(#(String, Float, Float)) {
  let reaction_decoder = {
    use reaction <- decode.field("reaction", decode.string)
    decode.success(reaction)
  }

  case
    decode.run(payload, reaction_decoder),
    decode_number(payload, "x"),
    decode_number(payload, "y")
  {
    Ok(reaction), Ok(x), Ok(y) -> {
      let valid =
        list.contains(supported_reactions, reaction)
        && coordinate_in_range(x)
        && coordinate_in_range(y)
      case valid {
        True -> Some(#(reaction, x, y))
        False -> None
      }
    }
    _, _, _ -> None
  }
}

fn decode_number(payload: Dynamic, field_name: String) -> Result(Float, Nil) {
  let float_decoder = {
    use value <- decode.field(field_name, decode.float)
    decode.success(value)
  }
  case decode.run(payload, float_decoder) {
    Ok(value) -> Ok(value)
    Error(_) -> {
      let int_decoder = {
        use value <- decode.field(field_name, decode.int)
        decode.success(value)
      }
      case decode.run(payload, int_decoder) {
        Ok(value) -> Ok(int.to_float(value))
        Error(_) -> Error(Nil)
      }
    }
  }
}

fn coordinate_in_range(value: Float) -> Bool {
  value >= 0.0 && value <= 1.0
}
```

- [ ] **Step 4: Format and run the focused tests**

Run:

```bash
cd examples/cursors
gleam format src test
gleam test -- --filter "reaction"
gleam test -- --filter "cursor_move_behavior_is_unchanged"
```

Expected: all focused tests pass.

- [ ] **Step 5: Commit the server behavior**

```bash
git add examples/cursors/src/cursors/app.gleam examples/cursors/test/cursors_app_test.gleam
git commit -m "feat(cursors): broadcast reactions"
```

---

### Task 2: Add the Toolbar and Local Animation

**Files:**
- Modify: `examples/cursors/src/cursors/router.gleam:55-68`
- Modify: `examples/cursors/priv/static/app.js:7-16`
- Modify: `examples/cursors/priv/static/app.js:63-129`
- Modify: `examples/cursors/priv/static/style.css:21-32`
- Modify: `examples/cursors/priv/static/style.css:79-106`
- Modify: `examples/cursors/e2e/cursors.spec.js:51-96`
- Modify: `examples/cursors/e2e/cursors.spec.js:558-575`

**Interfaces:**
- Consumes: The existing `#canvas` element and Phoenix client setup
- Produces: `#reaction-toolbar`, `.reaction-option`, `setSelectedReaction`, and `spawnReaction(reaction, x, y)`

- [ ] **Step 1: Add failing toolbar and local-animation tests**

Add this describe block after `Page structure` in `examples/cursors/e2e/cursors.spec.js`:

```javascript
  test.describe("Reaction toolbar", () => {
    test("renders five accessible reactions with thumbs up selected", async ({
      page,
    }) => {
      await page.goto("/");

      const toolbar = page.getByRole("toolbar", { name: "Choose reaction" });
      await expect(toolbar).toBeVisible();
      await expect(toolbar.getByRole("button")).toHaveCount(5);
      await expect(
        toolbar.getByRole("button", { name: "Thumbs up" })
      ).toHaveAttribute("aria-pressed", "true");
    });

    test("switches and clears the selected reaction", async ({ page }) => {
      await page.goto("/");

      const heart = page.getByRole("button", { name: "Heart" });
      const thumbsUp = page.getByRole("button", { name: "Thumbs up" });
      await heart.click();
      await expect(heart).toHaveAttribute("aria-pressed", "true");
      await expect(thumbsUp).toHaveAttribute("aria-pressed", "false");

      await heart.click();
      await expect(heart).toHaveAttribute("aria-pressed", "false");
    });

    test("spawns and removes the selected local reaction", async ({ page }) => {
      await page.goto("/");

      await page.locator("#canvas").click({ position: { x: 120, y: 140 } });
      const reaction = page.locator("#canvas .reaction-burst");
      await expect(reaction).toHaveText("👍");
      await expect(reaction).toHaveCount(0, { timeout: 3_000 });
    });

    test("toolbar clicks do not spawn reactions", async ({ page }) => {
      await page.goto("/");

      await page.getByRole("button", { name: "Party popper" }).click();
      await expect(page.locator("#canvas .reaction-burst")).toHaveCount(0);
    });

    test("canvas clicks do nothing after clearing selection", async ({
      page,
    }) => {
      await page.goto("/");

      await page.getByRole("button", { name: "Thumbs up" }).click();
      await page.locator("#canvas").click({ position: { x: 100, y: 100 } });
      await expect(page.locator("#canvas .reaction-burst")).toHaveCount(0);
    });

    test("keeps the selection active across rapid clicks", async ({ page }) => {
      await page.goto("/");

      const canvas = page.locator("#canvas");
      await canvas.click({ position: { x: 100, y: 100 } });
      await canvas.click({ position: { x: 140, y: 140 } });
      await expect(page.locator("#canvas .reaction-burst")).toHaveCount(2);
      await expect(
        page.getByRole("button", { name: "Thumbs up" })
      ).toHaveAttribute("aria-pressed", "true");
    });

    test("keeps the toolbar inside the canvas on mobile", async ({
      browser,
    }) => {
      const context = await browser.newContext({
        viewport: { width: 375, height: 667 },
      });
      const page = await context.newPage();

      try {
        await page.goto("/");
        const canvasBox = await page.locator("#canvas").boundingBox();
        const toolbarBox = await page.locator("#reaction-toolbar").boundingBox();
        expect(toolbarBox.x).toBeGreaterThanOrEqual(canvasBox.x);
        expect(toolbarBox.x + toolbarBox.width).toBeLessThanOrEqual(
          canvasBox.x + canvasBox.width
        );
      } finally {
        await context.close();
      }
    });

    test("uses the reduced-motion fade", async ({ browser }) => {
      const context = await browser.newContext({ reducedMotion: "reduce" });
      const page = await context.newPage();

      try {
        await page.goto("/");
        await page.locator("#canvas").click({ position: { x: 100, y: 100 } });
        const animationName = await page
          .locator("#canvas .reaction-burst")
          .evaluate((el) => getComputedStyle(el).animationName);
        expect(animationName).toBe("reaction-fade");
      } finally {
        await context.close();
      }
    });
  });
```

- [ ] **Step 2: Run the focused browser tests and confirm failure**

Run:

```bash
cd examples/cursors
npx playwright test --grep "Reaction toolbar"
```

Expected: tests fail because the toolbar and reaction nodes do not exist.

- [ ] **Step 3: Add accessible toolbar markup**

Inside `#canvas` in `examples/cursors/src/cursors/router.gleam`, after `#welcome`, add:

```html
      <div id="reaction-toolbar" role="toolbar" aria-label="Choose reaction">
        <button class="reaction-option is-selected" type="button" data-reaction="👍" aria-label="Thumbs up" aria-pressed="true">👍</button>
        <button class="reaction-option" type="button" data-reaction="❤️" aria-label="Heart" aria-pressed="false">❤️</button>
        <button class="reaction-option" type="button" data-reaction="😂" aria-label="Face with tears of joy" aria-pressed="false">😂</button>
        <button class="reaction-option" type="button" data-reaction="🎉" aria-label="Party popper" aria-pressed="false">🎉</button>
        <button class="reaction-option" type="button" data-reaction="🔥" aria-label="Fire" aria-pressed="false">🔥</button>
      </div>
```

- [ ] **Step 4: Implement selection and local reaction rendering**

In `examples/cursors/priv/static/app.js`, add beside the existing timing constants:

```javascript
  const REACTION_DURATION_MS = 1200;
```

After the existing `const canvas = document.getElementById("canvas");`, add:

```javascript
  const reactionToolbar = document.getElementById("reaction-toolbar");
  const reactionButtons = Array.from(
    reactionToolbar.querySelectorAll(".reaction-option")
  );
  let selectedReaction = "👍";
```

Add the toolbar behavior before the cursor `mousemove` listeners:

```javascript
  function setSelectedReaction(reaction) {
    selectedReaction = selectedReaction === reaction ? null : reaction;
    for (const button of reactionButtons) {
      const selected = button.dataset.reaction === selectedReaction;
      button.classList.toggle("is-selected", selected);
      button.setAttribute("aria-pressed", String(selected));
    }
  }

  for (const button of reactionButtons) {
    button.addEventListener("click", (event) => {
      event.stopPropagation();
      setSelectedReaction(button.dataset.reaction);
    });
  }

  canvas.addEventListener("click", (event) => {
    if (!selectedReaction || event.target.closest("#reaction-toolbar")) return;

    const rect = canvas.getBoundingClientRect();
    spawnReaction(
      selectedReaction,
      event.clientX - rect.left,
      event.clientY - rect.top
    );
  });

  function spawnReaction(reaction, x, y) {
    const el = document.createElement("span");
    el.className = "reaction-burst";
    el.textContent = reaction;
    el.style.left = `${x}px`;
    el.style.top = `${y}px`;
    el.style.setProperty(
      "--reaction-drift",
      `${(Math.random() * 32 - 16).toFixed(1)}px`
    );
    el.style.setProperty(
      "--reaction-scale",
      (0.9 + Math.random() * 0.25).toFixed(2)
    );

    const cleanup = () => el.remove();
    el.addEventListener("animationend", cleanup, { once: true });
    setTimeout(cleanup, REACTION_DURATION_MS + 200);
    canvas.appendChild(el);
  }
```

- [ ] **Step 5: Style the toolbar and animation**

Add to `examples/cursors/priv/static/style.css` after the canvas rules:

```css
/* --- Reaction toolbar --- */

#reaction-toolbar {
  position: absolute;
  left: 50%;
  bottom: 24px;
  z-index: 200;
  display: flex;
  gap: 6px;
  max-width: calc(100% - 16px);
  padding: 6px;
  transform: translateX(-50%);
  border: 1px solid rgba(0, 0, 0, 0.08);
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.92);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12);
  backdrop-filter: blur(8px);
}

.reaction-option {
  display: grid;
  width: 38px;
  height: 38px;
  place-items: center;
  border: 0;
  border-radius: 50%;
  background: transparent;
  cursor: pointer;
  font-size: 1.25rem;
  transition: background 120ms ease, transform 120ms ease;
}

.reaction-option:hover {
  background: #f1eef9;
}

.reaction-option.is-selected {
  background: #e8e0f7;
  transform: translateY(-2px) scale(1.08);
}

.reaction-option:focus-visible {
  outline: 3px solid #7c5cbf;
  outline-offset: 2px;
}

@media (max-width: 600px) {
  #reaction-toolbar {
    bottom: 12px;
    gap: 2px;
    padding: 4px;
  }

  .reaction-option {
    width: 28px;
    height: 32px;
    font-size: 1rem;
  }
}
```

Add after the cursor rules:

```css
/* --- Reactions --- */

.reaction-burst {
  position: absolute;
  z-index: 150;
  pointer-events: none;
  font-size: 2rem;
  line-height: 1;
  transform: translate(-50%, -50%);
  animation: reaction-float 1.2s ease-out forwards;
  will-change: opacity, transform;
}

@keyframes reaction-float {
  0% {
    opacity: 0;
    transform: translate(-50%, -40%) scale(0.6);
  }

  15% {
    opacity: 1;
  }

  100% {
    opacity: 0;
    transform:
      translate(calc(-50% + var(--reaction-drift)), -140px)
      scale(var(--reaction-scale));
  }
}

@media (prefers-reduced-motion: reduce) {
  .reaction-burst {
    animation-name: reaction-fade;
    animation-duration: 600ms;
  }
}

@keyframes reaction-fade {
  from {
    opacity: 1;
    transform: translate(-50%, -50%);
  }

  to {
    opacity: 0;
    transform: translate(-50%, -60%);
  }
}
```

- [ ] **Step 6: Run the focused browser tests**

Run:

```bash
cd examples/cursors
npx playwright test --grep "Reaction toolbar"
```

Expected: all Reaction toolbar tests pass.

- [ ] **Step 7: Commit the local interaction**

```bash
git add examples/cursors/src/cursors/router.gleam examples/cursors/priv/static/app.js examples/cursors/priv/static/style.css examples/cursors/e2e/cursors.spec.js
git commit -m "feat(cursors): add reaction toolbar"
```

---

### Task 3: Send and Render Collaborative Reactions

**Files:**
- Modify: `examples/cursors/priv/static/app.js:46-62`
- Modify: `examples/cursors/priv/static/app.js` reaction click handler from Task 2
- Modify: `examples/cursors/e2e/cursors.spec.js` after the Reaction toolbar tests

**Interfaces:**
- Consumes: Task 1's `reaction` channel event and Task 2's `spawnReaction(reaction, x, y)`
- Produces: Normalized outbound payloads and remote reaction rendering

- [ ] **Step 1: Add failing wire and multi-user tests**

Add after the Reaction toolbar describe block:

```javascript
  test.describe("Collaborative reactions", () => {
    test("sends the selected reaction with normalized coordinates", async ({
      page,
    }) => {
      const sentFrames = [];
      page.on("websocket", (ws) => {
        ws.on("framesent", (frame) => {
          try {
            const data = JSON.parse(frame.payload);
            if (Array.isArray(data) && data[3] === "reaction") {
              sentFrames.push(data);
            }
          } catch {
            // ignore non-JSON frames
          }
        });
      });

      await gotoWithUsername(page, "Reactor");
      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });

      const canvas = page.locator("#canvas");
      const box = await canvas.boundingBox();
      await canvas.click({
        position: { x: box.width * 0.25, y: box.height * 0.75 },
      });
      await expect.poll(() => sentFrames.length).toBeGreaterThan(0);

      const payload = sentFrames[0][4];
      expect(payload.reaction).toBe("👍");
      expect(payload.x).toBeCloseTo(0.25, 2);
      expect(payload.y).toBeCloseTo(0.75, 2);
    });

    test("broadcasts a reaction to another user at the same relative point", async ({
      browser,
    }) => {
      const context1 = await browser.newContext();
      const context2 = await browser.newContext();
      const page1 = await context1.newPage();
      const page2 = await context2.newPage();

      try {
        await gotoWithUsername(page1, "Sender");
        await expect(page1.locator("#user-list li")).toHaveCount(1, {
          timeout: 10_000,
        });
        await gotoWithUsername(page2, "Watcher");
        await expect(page1.locator("#user-list li")).toHaveCount(2, {
          timeout: 10_000,
        });

        await page1.getByRole("button", { name: "Party popper" }).click();
        const senderCanvas = page1.locator("#canvas");
        const senderBox = await senderCanvas.boundingBox();
        await senderCanvas.click({
          position: { x: senderBox.width * 0.4, y: senderBox.height * 0.6 },
        });

        const remote = page2.locator("#canvas .reaction-burst");
        await expect(remote).toHaveText("🎉", { timeout: 5_000 });

        const watcherBox = await page2.locator("#canvas").boundingBox();
        const position = await remote.evaluate((el) => ({
          left: Number.parseFloat(el.style.left),
          top: Number.parseFloat(el.style.top),
        }));
        expect(position.left).toBeCloseTo(watcherBox.width * 0.4, 0);
        expect(position.top).toBeCloseTo(watcherBox.height * 0.6, 0);
      } finally {
        await context1.close();
        await context2.close();
      }
    });
  });
```

- [ ] **Step 2: Run the collaborative tests and confirm failure**

Run:

```bash
cd examples/cursors
npx playwright test --grep "Collaborative reactions"
```

Expected: the sender test sees no `reaction` frame, and the second browser sees no reaction.

- [ ] **Step 3: Send normalized reactions**

Replace Task 2's canvas click handler in `examples/cursors/priv/static/app.js` with:

```javascript
  canvas.addEventListener("click", (event) => {
    if (!selectedReaction || event.target.closest("#reaction-toolbar")) return;

    const rect = canvas.getBoundingClientRect();
    const x = event.clientX - rect.left;
    const y = event.clientY - rect.top;
    spawnReaction(selectedReaction, x, y);
    channel.push("reaction", {
      reaction: selectedReaction,
      x: x / rect.width,
      y: y / rect.height,
    });
  });
```

- [ ] **Step 4: Render remote reactions**

Add after the existing `channel.on("cursor_move", ...)` handler:

```javascript
  channel.on("reaction", (payload) => {
    const { reaction, x, y } = payload;
    if (
      !["👍", "❤️", "😂", "🎉", "🔥"].includes(reaction) ||
      !Number.isFinite(x) ||
      !Number.isFinite(y) ||
      x < 0 ||
      x > 1 ||
      y < 0 ||
      y > 1
    ) {
      return;
    }

    const rect = canvas.getBoundingClientRect();
    spawnReaction(reaction, x * rect.width, y * rect.height);
  });
```

- [ ] **Step 5: Run focused and regression browser tests**

Run:

```bash
cd examples/cursors
npx playwright test --grep "Reaction toolbar|Collaborative reactions|Cursor movement|Remote cursor rendering"
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit realtime client integration**

```bash
git add examples/cursors/priv/static/app.js examples/cursors/e2e/cursors.spec.js
git commit -m "feat(cursors): sync reactions"
```

---

### Task 4: Document and Verify the Complete Example

**Files:**
- Modify: `examples/cursors/README.md:1-12`
- Modify: `examples/cursors/README.md:46-76`

**Interfaces:**
- Consumes: The completed toolbar, server event, and browser behavior
- Produces: User-facing run instructions and feature documentation that match the implementation

- [ ] **Step 1: Update the README**

Change the opening description and usage sentence to:

```markdown
A real-time collaborative cursors and reactions demo built with [beryl](https://github.com/tylerbutler/beryl). Move your mouse to share your cursor, then select a reaction and click the canvas to send it to everyone in the room.
```

Replace the PubSub row in **What It Demonstrates** with:

```markdown
| **PubSub** | `broadcast_from` fans out cursor moves and reactions to all other clients |
```

Replace the Browser line in the architecture diagram with:

```text
Browser (vanilla JS + Phoenix client)
  ├── cursor movement
  └── selectable, animated reactions
```

Replace the frontend stack line with:

```markdown
- **Frontend**: Vanilla JS, CSS animations, [Phoenix JS client](https://www.npmjs.com/package/phoenix) (CDN)
```

- [ ] **Step 2: Format and type-check the cursors example**

Run:

```bash
cd examples/cursors
gleam format src test
gleam check
gleam test
```

Expected: formatting completes, the example type-checks, and all Gleam tests pass.

- [ ] **Step 3: Run the complete cursors Playwright suite**

Run:

```bash
cd examples/cursors
npm test
```

Expected: every test in `e2e/cursors.spec.js` passes. Remove any untracked `test-results` or Playwright report artifacts created by the run.

- [ ] **Step 4: Run workspace checks**

Run from the repository root:

```bash
just format-check
just check
just test
```

Expected: all workspace formatting, type checks, and tests pass.

- [ ] **Step 5: Commit documentation and formatting**

```bash
git add examples/cursors/README.md examples/cursors/src examples/cursors/test examples/cursors/priv/static examples/cursors/e2e/cursors.spec.js
git commit -m "docs(cursors): describe reactions"
```
