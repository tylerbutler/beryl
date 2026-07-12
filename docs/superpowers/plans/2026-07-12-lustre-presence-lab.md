# Lustre Presence Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one interactive Lustre-powered presence lab to the Starlight examples page, backed by a hardened Mist and beryl demo service.

**Architecture:** Keep Astro and Starlight as the static documentation shell. Build a nested JavaScript-targeted Gleam project that registers a `beryl-presence-lab` Web Component, and connect it through the Phoenix JavaScript client to a separate Erlang-targeted Gleam demo service. Keep the component model and protocol decoding pure; isolate browser and socket work behind Lustre effects and one JavaScript FFI module.

**Tech Stack:** Gleam 1.16.0, Erlang/OTP 27.2.1, Lustre 5.7, Lustre Dev Tools 2.3, Astro 6, Starlight 0.39, Phoenix JavaScript client 1.7, Mist 6, gleeunit, Playwright, pnpm 10, Docker.

## Global Constraints

- Keep `website/src/content/docs/` as the canonical Markdown and MDX source.
- Keep the production documentation output static and deployable by Netlify.
- Register interactive UI as a Web Component; Gleam modules must not import Astro APIs.
- Use the Phoenix JavaScript client through a small Gleam FFI boundary; do not create a browser beryl client.
- The first slice implements only the presence lab and shared event transcript.
- Do not compile arbitrary Gleam in the browser.
- Use compatibility version `1` and scenario identifier `presence-v1`.
- Use `https://demos.beryl.tylerbutler.com` as the production demo service URL.
- Treat every demo client as hostile: enforce an origin allow-list, frame limits, connection limits, join limits, message limits, bounded topics, and explicit cleanup.
- Preserve readable static content when JavaScript or the demo service is unavailable.
- Use pnpm for JavaScript dependencies.
- Use `ref = "main"` for new Gleam git dependencies.
- Generate and commit each nested Gleam project's `manifest.toml` with Gleam tooling.
- Build the demo service as a provider-neutral Docker image; do not add provider-specific deployment files.

---

## File Map

### Interactive client

- `website/interactive/gleam.toml` — JavaScript-targeted Lustre project and build configuration.
- `website/interactive/manifest.toml` — generated dependency lock file.
- `website/interactive/src/beryl_site.gleam` — registers the custom element.
- `website/interactive/src/beryl_site/component/presence_lab.gleam` — Lustre component lifecycle and effect wiring.
- `website/interactive/src/beryl_site/presence/model.gleam` — pure model, messages, commands, and state transitions.
- `website/interactive/src/beryl_site/presence/protocol.gleam` — join/diff decoders and Phoenix Presence merge logic.
- `website/interactive/src/beryl_site/presence/reconnect.gleam` — bounded reconnect schedule shared with the Phoenix bridge.
- `website/interactive/src/beryl_site/presence/transcript.gleam` — bounded event transcript.
- `website/interactive/src/beryl_site/presence/view.gleam` — accessible component markup and component-local CSS.
- `website/interactive/src/beryl_site/phoenix.gleam` — Lustre effects that wrap the JavaScript bridge.
- `website/interactive/src/beryl_site/phoenix_ffi.mjs` — Phoenix Socket and Channel lifecycle.
- `website/interactive/test/presence_model_test.gleam` — pure state transition tests.
- `website/interactive/test/presence_protocol_test.gleam` — decoder and merge tests.
- `website/interactive/test/presence_reconnect_test.gleam` — bounded reconnect schedule tests.
- `website/interactive/test/presence_transcript_test.gleam` — transcript bound tests.
- `website/interactive/test/presence_view_test.gleam` — static rendered markup tests.

### Static site integration

- `website/scripts/build-interactive.mjs` — builds the Lustre entry and copies its bundle into `public/interactive/`.
- `website/src/components/PresenceLab.astro` — static fallback, component attributes, and bundle loader.
- `website/src/content/docs/examples.mdx` — embeds the first lab.
- `website/package.json` — Phoenix dependency and build/test scripts.
- `website/pnpm-lock.yaml` — generated pnpm lock changes.
- `website/.gitignore` — ignores nested build output and copied bundles.

### Demo service

- `website/demo_server/gleam.toml` — Erlang-targeted demo service.
- `website/demo_server/manifest.toml` — generated dependency lock file.
- `website/demo_server/src/beryl_demo.gleam` — production entrypoint.
- `website/demo_server/src/beryl_demo/config.gleam` — constants and environment configuration.
- `website/demo_server/src/beryl_demo/expiry.gleam` — absolute scenario expiry and bounded tombstones.
- `website/demo_server/src/beryl_demo/presence_channel.gleam` — validated presence channel.
- `website/demo_server/src/beryl_demo/router.gleam` — `/healthz` and `/v1/status`.
- `website/demo_server/src/beryl_demo/server.gleam` — starts beryl, presence, transport, and Mist.
- `website/demo_server/test/config_test.gleam` — configuration tests.
- `website/demo_server/test/expiry_test.gleam` — absolute expiry actor tests.
- `website/demo_server/test/presence_channel_test.gleam` — topic and join payload tests.
- `website/demo_server/test/server_integration_test.gleam` — coordinator-path join/diff/leave test.
- `website/demo_server/test/beryl_demo_test_ffi.erl` — raw WebSocket client and listener cleanup for integration tests.
- `website/demo_server/Dockerfile` — provider-neutral Erlang shipment image.
- `website/demo_server/Dockerfile.dockerignore` — root-context Docker exclusions for this Dockerfile.
- `website/demo_server/README.md` — local and container operation.

### Browser and CI

- `website/playwright.config.js` — starts Astro and the demo service.
- `website/e2e/presence-lab.spec.js` — progressive enhancement and live presence tests.
- `.github/workflows/ci.yml` — website client, server, browser, and build checks.
- `justfile` — focused website recipes.

---

### Task 1: Create the Lustre project and deterministic bundle pipeline

**Files:**
- Create: `website/interactive/gleam.toml`
- Create: `website/interactive/src/beryl_site.gleam`
- Create: `website/interactive/src/beryl_site/component/presence_lab.gleam`
- Create: `website/interactive/test/presence_view_test.gleam`
- Create: `website/scripts/build-interactive.mjs`
- Modify: `website/package.json`
- Modify: `website/.gitignore`
- Create via tooling: `website/interactive/manifest.toml`

**Interfaces:**
- Produces: `presence_lab.app() -> lustre.App(Nil, Model, Message)`
- Produces: `presence_lab.tag == "beryl-presence-lab"`
- Produces: `pnpm -C website build:interactive`
- Produces: `website/public/interactive/beryl_site.mjs`

- [ ] **Step 1: Add the nested Gleam project and a failing view test**

Create `website/interactive/gleam.toml`:

```toml
name = "beryl_site"
version = "0.1.0"
description = "Lustre components for the beryl documentation site"
gleam = ">= 1.16.0"
target = "javascript"

[dependencies]
gleam_json = ">= 3.1.0 and < 4.0.0"
gleam_stdlib = ">= 1.0.0 and < 2.0.0"
lustre = ">= 5.7.0 and < 6.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
lustre_dev_tools = ">= 2.3.6 and < 3.0.0"
```

Create `website/interactive/test/presence_view_test.gleam`:

```gleam
import beryl_site/component/presence_lab
import gleam/string
import gleeunit
import gleeunit/should
import lustre/element

pub fn main() {
  gleeunit.main()
}

pub fn static_component_names_the_presence_lab_test() {
  presence_lab.view(presence_lab.initial_model())
  |> element.to_readable_string
  |> string.contains("Presence lab")
  |> should.be_true
}
```

- [ ] **Step 2: Download dependencies and verify the test fails**

Run:

```bash
cd website/interactive
gleam deps download
gleam test --target javascript
```

Expected: dependency download creates `manifest.toml`; the test fails because `beryl_site/component/presence_lab` does not exist.

- [ ] **Step 3: Add the smallest registerable component**

Create `website/interactive/src/beryl_site/component/presence_lab.gleam`:

```gleam
import lustre
import lustre/effect
import lustre/element.{type Element}
import lustre/element/html

pub const tag = "beryl-presence-lab"

pub type Model {
  Model
}

pub type Message {
  NoOp
}

pub fn initial_model() -> Model {
  Model
}

fn init(_arguments: Nil) {
  #(initial_model(), effect.none())
}

fn update(model: Model, _message: Message) {
  #(model, effect.none())
}

pub fn view(_model: Model) -> Element(Message) {
  html.section([], [
    html.h2([], [html.text("Presence lab")]),
    html.p([], [html.text("Interactive client loading.")]),
  ])
}

pub fn app() {
  lustre.component(init:, update:, view:, options: [])
}
```

Create `website/interactive/src/beryl_site.gleam`:

```gleam
import beryl_site/component/presence_lab
import lustre

pub fn main() {
  let assert Ok(Nil) = lustre.register(presence_lab.app(), presence_lab.tag)
}
```

- [ ] **Step 4: Run the JavaScript-targeted test**

Run:

```bash
cd website/interactive
gleam format src test
gleam test --target javascript
```

Expected: `1 passed, no failures`.

- [ ] **Step 5: Add a deterministic build-and-copy script**

Create `website/scripts/build-interactive.mjs`:

```js
import { copyFile, mkdir, rm } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const websiteRoot = path.resolve(scriptDir, "..");
const projectRoot = path.join(websiteRoot, "interactive");
const bundle = path.join(projectRoot, "dist", "beryl_site.mjs");
const outputDir = path.join(websiteRoot, "public", "interactive");
const output = path.join(outputDir, "beryl_site.mjs");

const build = spawnSync(
  "gleam",
  [
    "run",
    "-m",
    "lustre/dev",
    "build",
    "--minify",
    "--no-html",
    "beryl_site",
  ],
  { cwd: projectRoot, stdio: "inherit" },
);

if (build.status !== 0) process.exit(build.status ?? 1);

await rm(outputDir, { force: true, recursive: true });
await mkdir(outputDir, { recursive: true });
await copyFile(bundle, output);
```

Modify `website/package.json` scripts:

```json
{
  "scripts": {
    "build:interactive": "node scripts/build-interactive.mjs",
    "build:site": "pnpm run generate:og && pnpm run build:interactive && astro build",
    "test:interactive": "cd interactive && gleam test --target javascript"
  }
}
```

Add to `website/.gitignore`:

```gitignore
interactive/build/
interactive/dist/
interactive/.lustre/
public/interactive/
```

- [ ] **Step 6: Build the bundle and verify the exact output**

Run:

```bash
pnpm -C website build:interactive
test -f website/public/interactive/beryl_site.mjs
```

Expected: both commands exit `0`.

- [ ] **Step 7: Commit**

```bash
git add website/interactive website/scripts/build-interactive.mjs website/package.json website/.gitignore
git commit -m "build(site): add Lustre component pipeline"
```

---

### Task 2: Implement the pure presence model, protocol, and transcript

**Files:**
- Create: `website/interactive/src/beryl_site/presence/model.gleam`
- Create: `website/interactive/src/beryl_site/presence/protocol.gleam`
- Create: `website/interactive/src/beryl_site/presence/reconnect.gleam`
- Create: `website/interactive/src/beryl_site/presence/transcript.gleam`
- Create: `website/interactive/test/presence_model_test.gleam`
- Create: `website/interactive/test/presence_protocol_test.gleam`
- Create: `website/interactive/test/presence_reconnect_test.gleam`
- Create: `website/interactive/test/presence_transcript_test.gleam`

**Interfaces:**
- Produces: `protocol.decode_join(String) -> Result(JoinReply, String)`
- Produces: `protocol.decode_diff(String) -> Result(PresenceDiff, String)`
- Produces: `protocol.apply_diff(PresenceState, PresenceDiff) -> PresenceState`
- Produces: `reconnect.delay(Int) -> Option(Int)` with no attempts after five retries
- Produces: `model.initial() -> Model`
- Produces: `model.update(Model, Message) -> #(Model, List(Command))`
- Produces: `transcript.add(List(Entry), Entry) -> List(Entry)` capped at 100 entries

- [ ] **Step 1: Write failing protocol tests**

Create `website/interactive/test/presence_protocol_test.gleam` with these cases:

```gleam
import beryl_site/presence/protocol
import gleam/dict
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn decodes_join_reply_test() {
  let encoded =
    "{\"compatibility_version\":1,\"client_id\":\"client-a\",\"presence_state\":{\"client-a\":{\"metas\":[{\"name\":\"Alice\",\"color\":\"emerald\",\"phx_ref\":\"ref-a\"}]}}}"
  let assert Ok(reply) = protocol.decode_join(encoded)
  reply.compatibility_version |> should.equal(1)
  reply.client_id |> should.equal("client-a")
  dict.size(reply.presence_state) |> should.equal(1)
}

pub fn rejects_join_reply_without_compatibility_version_test() {
  protocol.decode_join("{\"client_id\":\"client-a\",\"presence_state\":{}}")
  |> should.equal(Error("invalid_join_reply"))
}

pub fn applies_join_and_leave_diff_by_phx_ref_test() {
  let state =
    protocol.state([
      #("client-a", [protocol.Meta("Alice", "emerald", "ref-a")]),
    ])
  let diff =
    protocol.PresenceDiff(
      joins: protocol.state([
        #("client-b", [protocol.Meta("Bob", "magenta", "ref-b")]),
      ]),
      leaves: protocol.state([
        #("client-a", [protocol.Meta("Alice", "emerald", "ref-a")]),
      ]),
    )

  let updated = protocol.apply_diff(state, diff)
  dict.has_key(updated, "client-a") |> should.be_false
  dict.has_key(updated, "client-b") |> should.be_true
}
```

- [ ] **Step 2: Run the protocol test and verify failure**

Run:

```bash
cd website/interactive
gleam test --target javascript -- --filter "presence_protocol"
```

Expected: FAIL because `beryl_site/presence/protocol` does not exist.

- [ ] **Step 3: Implement protocol decoding and merge**

Create `website/interactive/src/beryl_site/presence/protocol.gleam` with these public types and functions:

```gleam
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result

pub type Meta {
  Meta(name: String, color: String, phx_ref: String)
}

pub type PresenceState =
  Dict(String, List(Meta))

pub type PresenceDiff {
  PresenceDiff(joins: PresenceState, leaves: PresenceState)
}

pub type JoinReply {
  JoinReply(
    compatibility_version: Int,
    client_id: String,
    presence_state: PresenceState,
  )
}

pub fn state(entries: List(#(String, List(Meta)))) -> PresenceState {
  dict.from_list(entries)
}

fn meta_decoder() {
  use name <- decode.field("name", decode.string)
  use color <- decode.field("color", decode.string)
  use phx_ref <- decode.field("phx_ref", decode.string)
  decode.success(Meta(name:, color:, phx_ref:))
}

fn state_decoder() {
  decode.dict({
    use metas <- decode.field("metas", decode.list(meta_decoder()))
    decode.success(metas)
  })
}

pub fn decode_join(encoded: String) -> Result(JoinReply, String) {
  let decoder = {
    use compatibility_version <- decode.field("compatibility_version", decode.int)
    use client_id <- decode.field("client_id", decode.string)
    use presence_state <- decode.field("presence_state", state_decoder())
    decode.success(JoinReply(compatibility_version:, client_id:, presence_state:))
  }

  json.parse(encoded, decoder)
  |> result.replace_error("invalid_join_reply")
}

pub fn decode_diff(encoded: String) -> Result(PresenceDiff, String) {
  let decoder = {
    use joins <- decode.field("joins", state_decoder())
    use leaves <- decode.field("leaves", state_decoder())
    decode.success(PresenceDiff(joins:, leaves:))
  }

  json.parse(encoded, decoder)
  |> result.replace_error("invalid_presence_diff")
}

pub fn apply_diff(state: PresenceState, diff: PresenceDiff) -> PresenceState {
  let with_joins =
    diff.joins
    |> dict.to_list
    |> list.fold(state, fn(current, entry) {
      let #(key, joined) = entry
      let existing = dict.get(current, key) |> result.unwrap([])
      dict.insert(current, key, append_unique_refs(existing, joined))
    })

  diff.leaves
  |> dict.to_list
  |> list.fold(with_joins, fn(current, entry) {
    let #(key, left) = entry
    let leaving_refs = list.map(left, fn(meta) { meta.phx_ref })
    let remaining =
      dict.get(current, key)
      |> result.unwrap([])
      |> list.filter(fn(meta) { !list.contains(leaving_refs, meta.phx_ref) })

    case remaining {
      [] -> dict.delete(current, key)
      _ -> dict.insert(current, key, remaining)
    }
  })
}

fn append_unique_refs(existing: List(Meta), joined: List(Meta)) -> List(Meta) {
  list.fold(joined, existing, fn(current, meta) {
    case list.any(current, fn(item) { item.phx_ref == meta.phx_ref }) {
      True -> current
      False -> list.append(current, [meta])
    }
  })
}
```

- [ ] **Step 4: Add failing transcript and model tests**

Create `website/interactive/test/presence_reconnect_test.gleam`:

```gleam
import beryl_site/presence/reconnect
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn reconnect_schedule_is_bounded_test() {
  reconnect.delay(1) |> should.equal(Some(1_000))
  reconnect.delay(2) |> should.equal(Some(2_000))
  reconnect.delay(3) |> should.equal(Some(5_000))
  reconnect.delay(4) |> should.equal(Some(10_000))
  reconnect.delay(5) |> should.equal(Some(10_000))
  reconnect.delay(6) |> should.equal(None)
}
```

Create `website/interactive/test/presence_transcript_test.gleam`:

```gleam
import beryl_site/presence/transcript
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn transcript_keeps_newest_one_hundred_entries_test() {
  let entries =
    list.range(1, 101)
    |> list.fold([], fn(current, index) {
      transcript.add(current, transcript.Entry(index, "event", "payload"))
    })

  list.length(entries) |> should.equal(100)
  let assert [newest, ..] = entries
  newest.sequence |> should.equal(101)
}
```

Create `website/interactive/test/presence_model_test.gleam` with these state transitions:

```gleam
import beryl_site/presence/model
import beryl_site/presence/protocol
import gleam/dict
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn connect_requests_a_fresh_scenario_test() {
  let #(updated, commands) =
    model.update(model.initial(), model.ConnectRequested)
  updated.status |> should.equal(model.Connecting)
  commands |> should.equal([model.GenerateScenario])
}

pub fn scenario_creation_opens_primary_client_test() {
  let connecting =
    model.Model(..model.initial(), status: model.Connecting, name: "Alice")
  let #(updated, commands) =
    model.update(
      connecting,
      model.ScenarioCreated("0123456789abcdef0123456789abcdef"),
    )

  updated.topic
  |> should.equal("demo:presence:0123456789abcdef0123456789abcdef")
  commands
  |> should.equal([
    model.OpenClient(
      role: model.Primary,
      service_url: "https://demos.beryl.tylerbutler.com",
      topic: "demo:presence:0123456789abcdef0123456789abcdef",
      name: "Alice",
      compatibility_version: 1,
    ),
  ])
}

pub fn incompatible_join_disconnects_all_clients_test() {
  let reply =
    protocol.JoinReply(
      compatibility_version: 99,
      client_id: "client-a",
      presence_state: dict.new(),
    )
  let current =
    model.Model(
      ..model.initial(),
      topic: "demo:presence:0123456789abcdef0123456789abcdef",
    )
  let #(updated, commands) =
    model.update(current, model.JoinSucceeded(model.Primary, reply))

  updated.status |> should.equal(model.Incompatible)
  commands
  |> should.equal([
    model.CloseAll("demo:presence:0123456789abcdef0123456789abcdef"),
  ])
}

pub fn offline_close_preserves_client_for_phoenix_reconnect_test() {
  let connected =
    model.Model(..model.initial(), status: model.Connected)
  let #(updated, commands) =
    model.update(
      connected,
      model.TransportClosed(model.Primary, "offline"),
    )

  updated.status |> should.equal(model.Offline)
  commands |> should.equal([])
}

pub fn expired_session_stops_reconnects_test() {
  let connected =
    model.Model(
      ..model.initial(),
      status: model.Connected,
      topic: "demo:presence:0123456789abcdef0123456789abcdef",
    )
  let #(updated, commands) =
    model.update(
      connected,
      model.TransportClosed(model.Primary, "session_expired"),
    )

  updated.status |> should.equal(model.Failed("session_expired"))
  commands
  |> should.equal([
    model.CloseAll("demo:presence:0123456789abcdef0123456789abcdef"),
  ])
}
```

- [ ] **Step 5: Implement the bounded transcript**

Create `website/interactive/src/beryl_site/presence/reconnect.gleam`:

```gleam
import gleam/option.{type Option, None, Some}

pub fn delay(attempt: Int) -> Option(Int) {
  case attempt {
    1 -> Some(1_000)
    2 -> Some(2_000)
    3 -> Some(5_000)
    4 | 5 -> Some(10_000)
    _ -> None
  }
}
```

Create `website/interactive/src/beryl_site/presence/transcript.gleam`:

```gleam
import gleam/list

const max_entries = 100

pub type Entry {
  Entry(sequence: Int, event: String, payload: String)
}

pub fn add(entries: List(Entry), entry: Entry) -> List(Entry) {
  [entry, ..entries]
  |> list.take(max_entries)
}
```

- [ ] **Step 6: Implement the pure model and command boundary**

Create `website/interactive/src/beryl_site/presence/model.gleam`. Use these exact public variants:

```gleam
pub type Status {
  Static
  Connecting
  Connected
  Reconnecting
  Offline
  Incompatible
  Failed(String)
}

pub type ClientRole {
  Primary
  Secondary
}

pub type Command {
  GenerateScenario
  OpenClient(
    role: ClientRole,
    service_url: String,
    topic: String,
    name: String,
    compatibility_version: Int,
  )
  CloseClient(topic: String, role: ClientRole)
  CloseAll(topic: String)
}

pub type Message {
  ServiceUrlChanged(String)
  CompatibilityVersionChanged(Int)
  NameChanged(String)
  ConnectRequested
  ScenarioCreated(String)
  TransportOpened(ClientRole)
  JoinSucceeded(ClientRole, protocol.JoinReply)
  JoinFailed(ClientRole, String)
  PresenceDiffReceived(protocol.PresenceDiff)
  AddSecondaryRequested
  DisconnectSecondaryRequested
  TransportClosed(ClientRole, String)
  ProtocolFailed(String)
  ResetRequested
  ComponentDisconnected
}
```

Define `Model` with:

```gleam
pub type Model {
  Model(
    service_url: String,
    expected_compatibility_version: Int,
    status: Status,
    topic: String,
    name: String,
    secondary_name: String,
    primary_client_id: String,
    secondary_connected: Bool,
    presences: protocol.PresenceState,
    transcript: List(transcript.Entry),
    next_sequence: Int,
  )
}
```

Implement `initial()` with production URL, compatibility version `1`, status
`Static`, name `"Alice"`, secondary name `"Bob"`, and empty state.

Implement `update()` so:

- `ServiceUrlChanged` and `CompatibilityVersionChanged` update configuration
  only while status is `Static`.
- `ConnectRequested` is accepted only from `Static` or `Failed`; it clears prior
  presence state, sets `Connecting`, and returns `[GenerateScenario]`. Other
  statuses return the model unchanged with no commands.
- `ScenarioCreated(id)` sets `topic` to `"demo:presence:" <> id` and returns
  `OpenClient(Primary, model.service_url, topic, model.name,
  model.expected_compatibility_version)`.
- `JoinSucceeded` rejects version mismatches with `Incompatible` and `[CloseAll(model.topic)]`.
- A compatible primary join replaces state with `reply.presence_state`, stores
  `reply.client_id` in `primary_client_id`, and sets `Connected`.
- A compatible secondary join sets `secondary_connected: True`.
- `PresenceDiffReceived` applies `protocol.apply_diff`.
- `AddSecondaryRequested` opens
  `OpenClient(Secondary, model.service_url, model.topic, model.secondary_name,
  model.expected_compatibility_version)` only when the primary is connected and
  no secondary exists.
- `DisconnectSecondaryRequested` clears `secondary_connected` and returns `[CloseClient(model.topic, Secondary)]`.
- `ResetRequested` sets `Connecting`, clears presence, `primary_client_id`, and
  secondary state, and returns `[CloseAll(model.topic), GenerateScenario]`.
- `ComponentDisconnected` returns `[CloseAll(model.topic)]`.
- `JoinFailed` enters `Failed(reason)` and returns `[CloseClient(model.topic, role)]`.
- `TransportClosed(Primary, "reconnect_exhausted")` enters
  `Failed("reconnect_exhausted")` and returns `[CloseAll(model.topic)]`.
- `TransportClosed(Primary, "session_expired")` enters
  `Failed("session_expired")` and returns `[CloseAll(model.topic)]`.
- `TransportClosed(Primary, "offline")` enters `Offline`; any other unexpected
  primary close from `Connected` enters `Reconnecting`. Match
  `"reconnect_exhausted"` before these broader cases.
- Offline and reconnecting transitions do not close the Phoenix client because
  Phoenix owns the bounded retry schedule.
- `TransportOpened(Primary)` moves `Offline` or `Reconnecting` back to
  `Connecting`; the following compatible join returns to `Connected`.
- `TransportClosed(Secondary, _)` clears `secondary_connected` without changing
  the primary status.
- `ProtocolFailed` enters `Failed(reason)` and returns `[CloseAll(model.topic)]`.
- Every transport or presence event appends one transcript entry with `next_sequence` and increments the sequence.
- Use transcript event names `socket_open`, `phx_reply`, `join_error`,
  `presence_diff`, `socket_close`, and `protocol_error`. Store
  `string.inspect` output for decoded replies/diffs and the explicit reason for
  failures so the browser test can distinguish joins from leaves.

- [ ] **Step 7: Run the pure tests**

Run:

```bash
cd website/interactive
gleam format src test
gleam test --target javascript
```

Expected: all protocol, transcript, model, and initial view tests pass.

- [ ] **Step 8: Commit**

```bash
git add website/interactive/src/beryl_site/presence website/interactive/test
git commit -m "feat(site): model presence lab state"
```

---

### Task 3: Add the Phoenix bridge and complete the Lustre component

**Files:**
- Create: `website/interactive/src/beryl_site/phoenix.gleam`
- Create: `website/interactive/src/beryl_site/phoenix_ffi.mjs`
- Create: `website/interactive/src/beryl_site/presence/view.gleam`
- Modify: `website/interactive/src/beryl_site/component/presence_lab.gleam`
- Modify: `website/interactive/test/presence_view_test.gleam`
- Modify via pnpm: `website/package.json`
- Modify via pnpm: `website/pnpm-lock.yaml`

**Interfaces:**
- Consumes: `model.Command` and dispatches `model.Message`
- Produces: `phoenix.run(List(model.Command)) -> lustre/effect.Effect(model.Message)`
- Produces: custom attributes `service-url` and `compatibility-version`
- Produces: test IDs `presence-status`, `scenario-topic`, `primary-name`, `connect-primary`, `add-secondary`, `disconnect-secondary`, `reset-scenario`, `presence-list`, and `event-transcript`

- [ ] **Step 1: Add Phoenix with pnpm**

Run:

```bash
pnpm -C website add phoenix@^1.7.20
```

Expected: `website/package.json` and `website/pnpm-lock.yaml` change; no npm or yarn lock file appears.

- [ ] **Step 2: Extend the failing view tests**

Add assertions to `website/interactive/test/presence_view_test.gleam`:

```gleam
pub fn disconnected_view_has_progressive_controls_test() {
  let rendered =
    presence_lab.view(presence_lab.initial_model())
    |> element.to_readable_string

  rendered |> string.contains("data-testid=\"primary-name\"") |> should.be_true
  rendered |> string.contains("data-testid=\"connect-primary\"") |> should.be_true
  rendered |> string.contains("aria-live=\"polite\"") |> should.be_true
}
```

- [ ] **Step 3: Run the view test and verify failure**

Run:

```bash
cd website/interactive
gleam test --target javascript -- --filter "presence_view"
```

Expected: FAIL because the minimal view has no controls.

- [ ] **Step 4: Implement the JavaScript Phoenix bridge**

Create `website/interactive/src/beryl_site/phoenix_ffi.mjs`:

```js
import { Socket } from "phoenix";

const clients = new Map();

function clientMap(topic) {
  let current = clients.get(topic);
  if (!current) {
    current = new Map();
    clients.set(topic, current);
  }
  return current;
}

export function scenarioId() {
  return crypto.randomUUID().replaceAll("-", "");
}

export function connect(
  role,
  serviceUrl,
  topic,
  name,
  compatibilityVersion,
  reconnectDelay,
  onOpen,
  onJoin,
  onJoinError,
  onPresenceDiff,
  onClose,
) {
  const map = clientMap(topic);
  disconnect(topic, role);

  const clientId = crypto.randomUUID();
  let client;
  const socket = new Socket(`${serviceUrl}/socket`, {
    params: { vsn: "2.0.0" },
    reconnectAfterMs(tries) {
      const delay = reconnectDelay(tries);
      if (delay >= 0) return delay;

      queueMicrotask(() => {
        if (!client.manual && !client.exhausted) {
          client.exhausted = true;
          client.manual = true;
          socket.disconnect();
          onClose("reconnect_exhausted");
        }
      });
      return 60_000;
    },
  });
  const channel = socket.channel(topic, {
    client_id: clientId,
    compatibility_version: compatibilityVersion,
    name,
    color: role === "primary" ? "emerald" : "magenta",
  });
  client = { socket, channel, manual: false, exhausted: false };

  socket.onOpen(onOpen);
  socket.onClose(() => {
    if (!client.manual) {
      onClose(navigator.onLine ? "socket_closed" : "offline");
    }
  });
  socket.onError(() => {
    if (!client.manual) {
      onClose(navigator.onLine ? "socket_error" : "offline");
    }
  });
  channel.on("presence_diff", (payload) => {
    onPresenceDiff(JSON.stringify(payload));
  });
  channel.onClose(() => {
    if (!client.manual) onClose("session_expired");
  });

  map.set(role, client);
  socket.connect();
  channel
    .join()
    .receive("ok", (payload) => onJoin(JSON.stringify(payload)))
    .receive("error", (payload) => onJoinError(JSON.stringify(payload)))
    .receive("timeout", () => onJoinError("join_timeout"));
}

export function disconnect(topic, role) {
  const map = clients.get(topic);
  const client = map?.get(role);
  if (!client) return;
  client.manual = true;
  client.channel.leave();
  client.socket.disconnect();
  map.delete(role);
  if (map.size === 0) clients.delete(topic);
}

export function disconnectAll(topic) {
  const map = clients.get(topic);
  if (!map) return;
  for (const role of [...map.keys()]) disconnect(topic, role);
  clients.delete(topic);
}
```

- [ ] **Step 5: Wrap the bridge in managed Lustre effects**

Create `website/interactive/src/beryl_site/phoenix.gleam`:

```gleam
import beryl_site/presence/model
import beryl_site/presence/protocol
import beryl_site/presence/reconnect
import gleam/list
import gleam/option
import lustre/effect.{type Effect}
import lustre/effect

@external(javascript, "./phoenix_ffi.mjs", "scenarioId")
fn scenario_id() -> String

@external(javascript, "./phoenix_ffi.mjs", "connect")
fn connect_ffi(
  role: String,
  service_url: String,
  topic: String,
  name: String,
  compatibility_version: Int,
  reconnect_delay: fn(Int) -> Int,
  on_open: fn() -> Nil,
  on_join: fn(String) -> Nil,
  on_join_error: fn(String) -> Nil,
  on_presence_diff: fn(String) -> Nil,
  on_close: fn(String) -> Nil,
) -> Nil

@external(javascript, "./phoenix_ffi.mjs", "disconnect")
fn disconnect_ffi(topic: String, role: String) -> Nil

@external(javascript, "./phoenix_ffi.mjs", "disconnectAll")
fn disconnect_all_ffi(topic: String) -> Nil

pub fn run(commands: List(model.Command)) -> Effect(model.Message) {
  commands
  |> list.map(run_one)
  |> effect.batch
}
```

Implement `run_one` with `effect.from` for every command. The Phoenix bridge does
not read the DOM, and synchronous effects also run during component disconnect,
which makes socket cleanup reliable:

```gleam
fn run_one(command: model.Command) -> Effect(model.Message) {
  case command {
    model.GenerateScenario ->
      effect.from(fn(dispatch) {
        dispatch(model.ScenarioCreated(scenario_id()))
      })
    model.OpenClient(role, service_url, topic, name, compatibility_version) ->
      effect.from(fn(dispatch) {
        connect_ffi(
          role_to_string(role),
          service_url,
          topic,
          name,
          compatibility_version,
          fn(attempt) {
            reconnect.delay(attempt)
            |> option.unwrap(-1)
          },
          fn() { dispatch(model.TransportOpened(role)) },
          fn(encoded) {
            case protocol.decode_join(encoded) {
              Ok(reply) -> dispatch(model.JoinSucceeded(role, reply))
              Error(reason) -> dispatch(model.ProtocolFailed(reason))
            }
          },
          fn(reason) { dispatch(model.JoinFailed(role, reason)) },
          fn(encoded) {
            case protocol.decode_diff(encoded) {
              Ok(diff) -> dispatch(model.PresenceDiffReceived(diff))
              Error(reason) -> dispatch(model.ProtocolFailed(reason))
            }
          },
          fn(reason) { dispatch(model.TransportClosed(role, reason)) },
        )
      })
    model.CloseClient(topic, role) ->
      effect.from(fn(_dispatch) {
        disconnect_ffi(topic, role_to_string(role))
      })
    model.CloseAll(topic) ->
      effect.from(fn(_dispatch) {
        disconnect_all_ffi(topic)
      })
  }
}

fn role_to_string(role: model.ClientRole) -> String {
  case role {
    model.Primary -> "primary"
    model.Secondary -> "secondary"
  }
}
```

- [ ] **Step 6: Implement the accessible view**

Create `website/interactive/src/beryl_site/presence/view.gleam`.

The view must render:

```text
section[aria-labelledby=presence-lab-title]
  h2#presence-lab-title
  div[role=status][aria-live=polite][data-testid=presence-status]
  code[data-testid=scenario-topic]
  label + input[data-testid=primary-name]
  button[data-testid=connect-primary]
  button[data-testid=add-secondary]
  button[data-testid=disconnect-secondary]
  button[data-testid=reset-scenario]
  ul[data-testid=presence-list]
  ol[data-testid=event-transcript]
  slot[name=fallback] when Static, Offline, Incompatible, or Failed
```

Render a component-local `<style>` element. Use the existing site variables
with safe fallbacks:

```css
:host {
  display: block;
  color: var(--sl-color-gray-1, #e8f2ed);
}
.lab {
  border: 1px solid var(--beryl-hairline, #48665a);
  border-radius: 16px;
  background: var(--beryl-surface, #173126);
  padding: clamp(1rem, 3vw, 1.5rem);
}
button:focus-visible,
input:focus-visible {
  outline: 2px solid var(--beryl-ring, #65d99b);
  outline-offset: 2px;
}
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { transition: none !important; }
}
```

Render these exact status messages in the live region:

```text
Static -> Ready to connect
Connecting -> Connecting
Connected -> Connected
Reconnecting -> Connection lost; reconnecting
Offline -> Offline; reconnecting when the network returns
Incompatible -> Incompatible demo version; refresh the documentation page
Failed(reason) -> Demo failed: <reason>
```

Render each presence as visible text containing its name and color, for example
`Alice — emerald`; a color swatch may supplement this text but must be
`aria-hidden="true"`. Render transcript event names and payload text, newest
first, so join and leave changes remain inspectable without relying on color.
Use `component.named_slot("fallback", [], [])` for the conditional fallback
slot.

Disable controls according to the model:

- Name disabled during `Connecting`, `Connected`, `Reconnecting`, `Offline`, or
  `Incompatible`.
- Connect enabled only during `Static` or `Failed`.
- Add secondary enabled only during `Connected` with no secondary.
- Disconnect secondary enabled only while secondary is connected.
- Reset enabled after a scenario topic exists.

- [ ] **Step 7: Wire lifecycle, attributes, update, and view**

Replace the minimal `presence_lab.gleam` with:

```gleam
import beryl_site/phoenix
import beryl_site/presence/model
import beryl_site/presence/view as presence_view
import gleam/int
import gleam/result
import lustre
import lustre/component
import lustre/effect

pub const tag = "beryl-presence-lab"

pub type Model =
  model.Model

pub type Message =
  model.Message

pub fn initial_model() -> Model {
  model.initial()
}

fn init(_arguments: Nil) {
  #(initial_model(), effect.none())
}

fn update(current: Model, message: Message) {
  let #(next, commands) = model.update(current, message)
  #(next, phoenix.run(commands))
}

pub fn view(current: Model) {
  presence_view.view(current)
}

pub fn app() {
  lustre.component(
    init:,
    update:,
    view:,
    options: [
      component.on_attribute_change("service-url", fn(value) {
        Ok(model.ServiceUrlChanged(value))
      }),
      component.on_attribute_change("compatibility-version", fn(value) {
        int.parse(value)
        |> result.map(model.CompatibilityVersionChanged)
        |> result.replace_error(Nil)
      }),
      component.on_disconnect(model.ComponentDisconnected),
      component.adopt_styles(False),
    ],
  )
}
```

`CompatibilityVersionChanged(Int)` is already part of `model.Message`; keep the
attribute handler consistent with that exact variant.

- [ ] **Step 8: Run tests and build**

Run:

```bash
cd website/interactive
gleam format src test
gleam test --target javascript
cd ../..
pnpm -C website build:interactive
```

Expected: all tests pass and `website/public/interactive/beryl_site.mjs` exists.

- [ ] **Step 9: Commit**

```bash
git add website/interactive website/package.json website/pnpm-lock.yaml
git commit -m "feat(site): add Lustre presence component"
```

---

### Task 4: Build the hardened Mist and beryl demo service

**Files:**
- Create: `website/demo_server/gleam.toml`
- Create: `website/demo_server/src/beryl_demo.gleam`
- Create: `website/demo_server/src/beryl_demo/config.gleam`
- Create: `website/demo_server/src/beryl_demo/expiry.gleam`
- Create: `website/demo_server/src/beryl_demo/presence_channel.gleam`
- Create: `website/demo_server/src/beryl_demo/router.gleam`
- Create: `website/demo_server/src/beryl_demo/server.gleam`
- Create: `website/demo_server/test/config_test.gleam`
- Create: `website/demo_server/test/expiry_test.gleam`
- Create: `website/demo_server/test/presence_channel_test.gleam`
- Create: `website/demo_server/test/server_integration_test.gleam`
- Create: `website/demo_server/test/beryl_demo_test_ffi.erl`
- Create via tooling: `website/demo_server/manifest.toml`

**Interfaces:**
- Produces: WebSocket path `/socket/websocket`
- Produces: topic pattern `demo:presence:*`
- Produces: `GET /healthz -> 200 "ok"`
- Produces: `GET /v1/status -> {"status":"ok","compatibility_version":1,"beryl_version":...,"scenarios":["presence-v1"]}`
- Produces: idle eviction after 60 seconds without a Phoenix heartbeat and absolute scenario expiry after 10 minutes
- Join payload: `{client_id, compatibility_version, name, color}`
- Join reply: `{client_id, compatibility_version, presence_state}`
- Broadcast event: `presence_diff`

- [ ] **Step 1: Add the server project and dependencies**

Create `website/demo_server/gleam.toml`:

```toml
name = "beryl_demo"
version = "0.1.0"
description = "Public realtime demo service for the beryl documentation site"
gleam = ">= 1.16.0"
target = "erlang"

[dependencies]
beryl = { path = "../.." }
envoy = ">= 1.2.0 and < 2.0.0"
gleam_erlang = ">= 1.3.0 and < 2.0.0"
gleam_http = ">= 4.3.0 and < 5.0.0"
gleam_json = ">= 3.1.0 and < 4.0.0"
gleam_otp = ">= 1.2.0 and < 2.0.0"
gleam_stdlib = ">= 1.0.0 and < 2.0.0"
mist = ">= 6.0.0 and < 7.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
```

Run:

```bash
cd website/demo_server
gleam deps download
```

Expected: `manifest.toml` is generated.

- [ ] **Step 2: Write failing configuration and validation tests**

Create `website/demo_server/test/config_test.gleam`:

```gleam
import beryl_demo/config
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn parses_comma_separated_origins_test() {
  config.parse_origins("https://beryl.tylerbutler.com,http://127.0.0.1:4321")
  |> should.equal([
    "https://beryl.tylerbutler.com",
    "http://127.0.0.1:4321",
  ])
}

pub fn default_config_is_locked_to_documentation_origins_test() {
  config.default().allowed_origins
  |> should.equal([
    "https://beryl.tylerbutler.com",
    "http://127.0.0.1:4321",
    "http://localhost:4321",
  ])
}

pub fn default_session_ttl_is_ten_minutes_test() {
  config.default().session_ttl_ms
  |> should.equal(600_000)
}
```

Create `website/demo_server/test/presence_channel_test.gleam` with:

```gleam
pub fn accepts_randomized_demo_topic_test() {
  presence_channel.valid_topic(
    "demo:presence:0123456789abcdef0123456789abcdef",
  )
  |> should.be_true
}

pub fn rejects_short_or_cross_scenario_topics_test() {
  presence_channel.valid_topic("demo:presence:short") |> should.be_false
  presence_channel.valid_topic("room:lobby") |> should.be_false
}

pub fn validates_join_fields_test() {
  presence_channel.validate_join(
    client_id: "0d784f76-ae17-4812-98cc-f4339efac343",
    compatibility_version: 1,
    name: "Alice",
    color: "emerald",
  )
  |> should.be_ok
}
```

Create `website/demo_server/test/expiry_test.gleam`:

```gleam
import beryl_demo/expiry
import gleam/erlang/process
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn expires_a_tracked_topic_test() {
  let expired = process.new_subject()
  let assert Ok(manager) = expiry.start(100)
  expiry.initialize(manager, fn(socket_id, topic) {
    process.send(expired, #(socket_id, topic))
  })
  expiry.track(manager, "demo:presence:test", "socket-1")

  process.receive(expired, 500)
  |> should.equal(Ok(#("socket-1", "demo:presence:test")))
  expiry.is_expired(manager, "demo:presence:test")
  |> should.be_true
  expiry.stop(manager)
}
```

- [ ] **Step 3: Run tests and verify failure**

Run:

```bash
cd website/demo_server
gleam test
```

Expected: FAIL because the server modules do not exist.

- [ ] **Step 4: Implement configuration constants**

Create `website/demo_server/src/beryl_demo/config.gleam`:

```gleam
import envoy
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub const compatibility_version = 1
pub const scenario = "presence-v1"
pub const socket_path = "/socket/websocket"

pub type Config {
  Config(
    port: Int,
    bind_address: String,
    allowed_origins: List(String),
    beryl_version: String,
    session_ttl_ms: Int,
  )
}

pub fn default() -> Config {
  Config(
    port: 4100,
    bind_address: "127.0.0.1",
    allowed_origins: [
      "https://beryl.tylerbutler.com",
      "http://127.0.0.1:4321",
      "http://localhost:4321",
    ],
    beryl_version: "development",
    session_ttl_ms: 600_000,
  )
}

pub fn parse_origins(value: String) -> List(String) {
  value
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(origin) { origin != "" })
}

pub fn from_env() -> Config {
  let defaults = default()
  Config(
    port:
      envoy.get("PORT")
      |> result.try(int.parse)
      |> result.unwrap(defaults.port),
    bind_address:
      envoy.get("BIND_ADDRESS")
      |> result.unwrap(defaults.bind_address),
    allowed_origins:
      envoy.get("ALLOWED_ORIGINS")
      |> result.map(parse_origins)
      |> result.unwrap(defaults.allowed_origins),
    beryl_version:
      envoy.get("BERYL_VERSION")
      |> result.unwrap(defaults.beryl_version),
    session_ttl_ms: defaults.session_ttl_ms,
  )
}
```

- [ ] **Step 5: Implement absolute scenario expiry**

Create `website/demo_server/src/beryl_demo/expiry.gleam` as an OTP actor with
this public boundary:

```gleam
pub opaque type Expiry

pub fn start(ttl_ms: Int) -> Result(Expiry, actor.StartError)

pub fn initialize(
  expiry: Expiry,
  expire_channel: fn(String, String) -> Nil,
) -> Nil

pub fn track(expiry: Expiry, topic: String, socket_id: String) -> Nil

pub fn untrack(expiry: Expiry, topic: String, socket_id: String) -> Nil

pub fn is_expired(expiry: Expiry, topic: String) -> Bool

pub fn stop(expiry: Expiry) -> Nil
```

Use this exact message and state shape:

```gleam
type Message {
  Initialize(fn(String, String) -> Nil)
  Track(topic: String, socket_id: String)
  Untrack(topic: String, socket_id: String)
  IsExpired(topic: String, reply: process.Subject(Bool))
  ExpireTopic(String)
  ForgetTopic(String)
  Stop
}

type State {
  State(
    ttl_ms: Int,
    expire_channel: Option(fn(String, String) -> Nil),
    sockets: Dict(String, List(String)),
    scheduled: Set(String),
    expired: Set(String),
  )
}
```

On the first `Track` for a topic, call
`process.send_after(subject, state.ttl_ms, ExpireTopic(topic))`. On
`ExpireTopic`, add the topic to `expired`, invoke `expire_channel(socket_id,
topic)` for every tracked socket, clear the socket list, and schedule
`ForgetTopic(topic)` after another `ttl_ms`. `ForgetTopic` removes the topic from
both `expired` and `scheduled`, which bounds tombstone memory. Implement
`is_expired` with `process.call(..., 5_000, ...)`. Handle `Stop` with
`actor.stop()` and expose it through `stop`.

- [ ] **Step 6: Implement validated presence joins**

Create `website/demo_server/src/beryl_demo/presence_channel.gleam`.

Define:

```gleam
pub type Assigns {
  Assigns(
    presence: presence.Presence,
    expiry: expiry.Expiry,
    topic: String,
  )
}

pub type Info {
  Expire
}

pub fn valid_topic(topic: String) -> Bool

pub fn validate_join(
  client_id client_id: String,
  compatibility_version compatibility_version: Int,
  name name: String,
  color color: String,
) -> Result(Nil, json.Json)

pub fn new(
  channels: beryl.Channels,
  presence_actor: presence.Presence,
  expiry_actor: expiry.Expiry,
) -> channel.Channel(Assigns, Info)
```

Validation rules:

- topic is exactly `demo:presence:` plus 32 lowercase hexadecimal characters
- `client_id` length is 36
- compatibility version equals `config.compatibility_version`
- name length is `1..40`
- color is exactly `"emerald"` or `"magenta"`

Implement `valid_topic` without a regex dependency:

```gleam
pub fn valid_topic(topic: String) -> Bool {
  case string.split(topic, ":") {
    ["demo", "presence", id] ->
      string.length(id) == 32
      && id
      |> string.to_graphemes
      |> list.all(fn(character) {
        string.contains("0123456789abcdef", character)
      })
    _ -> False
  }
}
```

On join:

1. Reject an expired topic with
   `JoinError(channel.error_with_code(410, "scenario expired"))`.
2. Decode all four fields with `channel.decode_payload`.
3. Return `JoinError(channel.error_with_code(422, "invalid join payload"))` on decode failure.
4. Return the specific validation error on invalid values.
5. Track with key `client_id`, session ID `socket.id(socket)`, and meta:

```gleam
json.object([
  #("name", json.string(name)),
  #("color", json.string(color)),
])
```

6. Call `expiry.track(expiry_actor, topic, socket.id(socket))`.
7. Reply with:

```gleam
json.object([
  #("client_id", json.string(client_id)),
  #("compatibility_version", json.int(config.compatibility_version)),
  #(
    "presence_state",
    presence_wire.encode_state(presence.list(presence_actor, topic)),
  ),
])
```

On `Info.Expire`, return `channel.Stop(channel.Shutdown)`. On terminate, call
`expiry.untrack(expiry_actor, topic, socket.id(socket))` and
`presence.untrack_all(presence_actor, socket.id(socket))`.
Unknown inbound events return `channel.ReplyError` with code `404`.

- [ ] **Step 7: Implement status routes and the server**

Create `website/demo_server/src/beryl_demo/router.gleam`:

```gleam
pub fn handle_request(
  request: request.Request(mist.Connection),
  service_config: config.Config,
) -> response.Response(mist.ResponseData) {
  case request.path_segments(request) {
    ["healthz"] -> text_response(200, "ok")
    ["v1", "status"] ->
      json_response(200, json.object([
        #("status", json.string("ok")),
        #("compatibility_version", json.int(config.compatibility_version)),
        #("beryl_version", json.string(service_config.beryl_version)),
        #("scenarios", json.array([config.scenario], json.string)),
      ]))
    _ -> text_response(404, "not found")
  }
}
```

Create `website/demo_server/src/beryl_demo/server.gleam` with:

```gleam
pub type OriginMode {
  AllowOrigins(List(String))
  TestOnlyAllowAll
}

pub type Started {
  Started(
    port: Int,
    channels: beryl.Channels,
    expiry: expiry.Expiry,
    supervisor: actor.Started(static_supervisor.Supervisor),
  )
}

pub fn start(
  service_config: config.Config,
  origin_mode: OriginMode,
) -> Result(Started, Nil)
```

Inside `start`:

1. Start beryl with:

```gleam
beryl.config(wire.phoenix_codec())
|> beryl.with_heartbeat(interval_ms: 30_000, timeout_ms: 60_000)
|> beryl.with_max_connections(max_connections: 200)
|> beryl.with_max_connections_per_ip(max_connections: 8)
|> beryl.with_max_inbound_frame_bytes(max_bytes: 16 * 1024)
|> beryl.with_max_joined_topics_per_socket(max_topics: 2)
|> beryl.with_join_rate(per_second: 4, burst: 8)
|> beryl.with_message_rate(per_second: 10, burst: 20)
```

2. Start presence with `presence.with_on_diff`, iterate
   `presence.diff_topics(diff)`, and call
   `beryl.broadcast_presence_diff(channels, topic, diff)`.
3. Start `expiry.start(service_config.session_ttl_ms)`.
4. Register `presence_channel.new(channels, presence_actor, expiry_actor)` on
   `demo:presence:*`, retaining the returned `RegisteredChannel`.
5. Call `expiry.initialize(expiry_actor, fn(socket_id, topic) {
   beryl.send_info(registered, socket_id, topic, presence_channel.Expire)
   })`.
6. Build the transport config with `with_allowed_origins` in production and
   `with_allow_all_origins` only for `TestOnlyAllowAll`.
7. Use `mist_transport.handler`.
8. Bind the configured address and port.
9. Use `mist.after_start` to return the actual port when the configured port is
   `0`.

Create `website/demo_server/src/beryl_demo.gleam`:

```gleam
import beryl_demo/config
import beryl_demo/server
import gleam/erlang/process

pub fn main() {
  let service_config = config.from_env()
  let assert Ok(_) =
    server.start(
      service_config,
      server.AllowOrigins(service_config.allowed_origins),
    )
  process.sleep_forever()
}
```

- [ ] **Step 8: Add real coordinator-path integration tests**

Create `website/demo_server/test/beryl_demo_test_ffi.erl` by copying the exact
HTTP and raw WebSocket implementation from
`test/beryl_mist_transport_test_ffi.erl:1-247`. Rename the module to
`beryl_demo_test_ffi`, keep exports for `http_get/2`, `connect_websocket/2`,
`connect_websocket_with_origin/3`, `websocket_upgrade_status/2`,
`websocket_upgrade_status_with_origin/3`, `send_text/2`, `receive_text/2`, and
`close/1`, add `stop/1` to the export list, and add:

```erlang
stop(Pid) ->
    exit(Pid, shutdown),
    nil.
```

Create `website/demo_server/test/server_integration_test.gleam` that:

1. Starts `server.start(Config(..config.default(), port: 0), TestOnlyAllowAll)`.
2. Connects a primary raw WebSocket client to a unique topic
   `demo:presence:11111111111111111111111111111111`.
3. Sends this Phoenix V2 join frame:

```gleam
json.preprocessed_array([
  json.string("1"),
  json.string("1"),
  json.string(topic),
  json.string("phx_join"),
  json.object([
    #("client_id", json.string("11111111-1111-1111-1111-111111111111")),
    #("compatibility_version", json.int(1)),
    #("name", json.string("Alice")),
    #("color", json.string("emerald")),
  ]),
])
```

4. Selects the exact `phx_reply` frame for ref `"1"` and asserts compatibility
   version `1` and one presence.
5. Connects a secondary raw client and sends the same frame with ref `"2"`,
   client ID `22222222-2222-2222-2222-222222222222`, name `Bob`, and color
   `magenta`.
6. Selects `presence_diff` on the primary and asserts it contains Bob's join.
7. Closes the secondary.
8. Selects the next `presence_diff` and asserts it contains Bob's leave.
9. Closes the primary and calls `stop_started(started)`.

Copy the `Frame`, `encode_json_frame`, `decode_json_frame`, `result_nil`,
`assert_json_string`, and `dynamic_field` helpers exactly from
`test/phoenix_contract_test.gleam:44-169`. Add this selector so the test never
accepts the first arbitrary socket message:

```gleam
fn receive_frame(
  client: WebsocketClient,
  event: String,
  expected_ref: Option(String),
  remaining: Int,
) -> Frame {
  let assert True = remaining > 0
  let assert Ok(raw) = receive_text(client, 500)
  let assert Ok(frame) = decode_json_frame(raw)
  let reference_matches = case expected_ref {
    None -> True
    Some(reference) -> frame.ref == Some(reference)
  }

  case frame.event == event && reference_matches {
    True -> frame
    False -> receive_frame(client, event, expected_ref, remaining - 1)
  }
}
```

Use `receive_frame(primary, "phx_reply", Some("1"), 10)` for the first join
reply and `receive_frame(primary, "presence_diff", None, 10)` for each diff.

Add these service-hardening integration tests to the same module:

```gleam
pub fn status_routes_are_available_test() {
  let started = start_test_server(server.TestOnlyAllowAll)
  http_get(started.port, "/healthz") |> should.equal(Ok(200))
  http_get(started.port, "/v1/status") |> should.equal(Ok(200))
  stop_started(started)
}

pub fn production_origin_policy_rejects_other_sites_test() {
  let service_config =
    config.Config(
      ..config.default(),
      port: 0,
      allowed_origins: ["https://beryl.tylerbutler.com"],
    )
  let assert Ok(started) =
    server.start(
      service_config,
      server.AllowOrigins(service_config.allowed_origins),
    )

  websocket_upgrade_status_with_origin(
    started.port,
    config.socket_path,
    "https://evil.example",
  )
  |> should.equal(Ok(403))
  websocket_upgrade_status_with_origin(
    started.port,
    config.socket_path,
    "https://beryl.tylerbutler.com",
  )
  |> should.equal(Ok(101))
  stop_started(started)
}

pub fn ninth_same_ip_connection_is_rejected_test() {
  let started = start_test_server(server.TestOnlyAllowAll)
  let clients = connect_clients(started.port, 8, [])
  websocket_upgrade_status(started.port, config.socket_path)
  |> should.equal(Ok(429))
  list.each(clients, close)
  stop_started(started)
}

pub fn oversized_frame_closes_connection_test() {
  let started = start_test_server(server.TestOnlyAllowAll)
  let assert Ok(client) =
    connect_websocket(started.port, config.socket_path)
  let assert Ok(_) = send_text(client, string.repeat("a", 16 * 1024 + 1))
  receive_text(client, 200) |> should.equal(Error(Nil))
  close(client)
  stop_started(started)
}

pub fn expired_scenario_closes_channels_and_rejects_rejoin_test() {
  let service_config =
    config.Config(..config.default(), port: 0, session_ttl_ms: 100)
  let assert Ok(started) =
    server.start(service_config, server.TestOnlyAllowAll)
  let topic = "demo:presence:33333333333333333333333333333333"
  let assert Ok(primary) =
    connect_websocket(started.port, config.socket_path)
  let assert Ok(_) =
    send_text(primary, join_frame("1", topic, "Alice", "emerald"))
  let _reply = receive_frame(primary, "phx_reply", Some("1"), 10)
  let _close = receive_frame(primary, "phx_close", None, 10)
  close(primary)

  let assert Ok(rejoin) =
    connect_websocket(started.port, config.socket_path)
  let assert Ok(_) =
    send_text(rejoin, join_frame("2", topic, "Alice", "emerald"))
  let rejected = receive_frame(rejoin, "phx_reply", Some("2"), 10)
  assert_json_string(rejected.payload, "status", "error")
  rejected.payload
  |> dynamic_field("response")
  |> assert_json_int("code", 410)
  close(rejoin)
  stop_started(started)
}
```

Use these helpers:

```gleam
fn start_test_server(origin_mode: server.OriginMode) -> server.Started {
  let service_config = config.Config(..config.default(), port: 0)
  let assert Ok(started) = server.start(service_config, origin_mode)
  started
}

fn join_frame(
  reference: String,
  topic: String,
  name: String,
  color: String,
) -> String {
  json.preprocessed_array([
    json.string(reference),
    json.string(reference),
    json.string(topic),
    json.string("phx_join"),
    json.object([
      #("client_id", json.string("33333333-3333-3333-3333-333333333333")),
      #("compatibility_version", json.int(1)),
      #("name", json.string(name)),
      #("color", json.string(color)),
    ]),
  ])
  |> json.to_string
}

fn connect_clients(
  port: Int,
  remaining: Int,
  clients: List(WebsocketClient),
) -> List(WebsocketClient) {
  case remaining {
    0 -> clients
    _ -> {
      let assert Ok(client) =
        connect_websocket(port, config.socket_path)
      connect_clients(port, remaining - 1, [client, ..clients])
    }
  }
}

fn stop_started(started: server.Started) {
  expiry.stop(started.expiry)
  beryl.stop(started.channels)
  stop(started.supervisor.pid)
}

fn assert_json_int(
  payload: dynamic.Dynamic,
  field: String,
  expected: Int,
) {
  let decoder = {
    use actual <- decode.field(field, decode.int)
    decode.success(actual)
  }
  let assert Ok(actual) = decode.run(payload, decoder)
  actual |> should.equal(expected)
}
```

- [ ] **Step 9: Run server tests**

Run:

```bash
cd website/demo_server
gleam format src test
gleam test
gleam build --warnings-as-errors
```

Expected: all tests pass and the strict build succeeds.

- [ ] **Step 10: Commit**

```bash
git add website/demo_server
git commit -m "feat(site): add presence demo service"
```

---

### Task 5: Embed the lab in Starlight with a static fallback

**Files:**
- Create: `website/src/components/PresenceLab.astro`
- Modify: `website/src/content/docs/examples.mdx`
- Modify: `website/package.json`

**Interfaces:**
- Consumes: `/interactive/beryl_site.mjs`
- Consumes: `PUBLIC_BERYL_DEMO_URL`
- Produces: `<beryl-presence-lab service-url="..." compatibility-version="1">`
- Preserves explanatory content without JavaScript

- [ ] **Step 1: Create the Astro host**

Create `website/src/components/PresenceLab.astro`:

```astro
---
const serviceUrl =
  import.meta.env.PUBLIC_BERYL_DEMO_URL ??
  "https://demos.beryl.tylerbutler.com";
---

<beryl-presence-lab
  service-url={serviceUrl}
  compatibility-version="1"
>
  <section
    slot="fallback"
    class="presence-lab-fallback"
    aria-label="Presence lab explanation"
  >
    <p>
      This lab connects two short-lived Phoenix clients to an isolated beryl
      topic and shows the resulting presence state and diffs.
    </p>
    <p>
      Enable JavaScript to run the live scenario. The Presence guide below
      describes the same join, track, diff, and leave flow.
    </p>
  </section>
</beryl-presence-lab>

<script is:inline type="module" src="/interactive/beryl_site.mjs"></script>

<style>
  beryl-presence-lab {
    display: block;
    margin-block: 1.5rem 2.5rem;
  }
  .presence-lab-fallback {
    border: 1px solid var(--beryl-hairline);
    border-radius: 16px;
    background: var(--beryl-surface);
    padding: 1.25rem;
  }
</style>
```

The fallback remains visible before upgrade. The Lustre view projects it while
the scenario is static or unavailable and hides it while the live scenario is
running.

- [ ] **Step 2: Embed it at the top of the examples page**

Modify `website/src/content/docs/examples.mdx`:

```mdx
import PresenceLab from '../../components/PresenceLab.astro';

## Live presence lab

Connect a primary participant, add a second participant, and inspect the
Phoenix-compatible presence state and diffs that beryl emits.

<PresenceLab />
```

Place this section after the pre-1.0 caution and before “Collaborative Cursors.”
Keep all existing example documentation.

- [ ] **Step 3: Ensure every site build creates the component bundle**

Confirm `website/package.json` contains:

```json
{
  "scripts": {
    "build:site": "pnpm run generate:og && pnpm run build:interactive && astro build",
    "check:astro": "pnpm run build:interactive && astro check"
  }
}
```

- [ ] **Step 4: Build and inspect the output**

Run:

```bash
pnpm -C website check:astro
pnpm -C website build:site
test -f website/dist/interactive/beryl_site.mjs
grep -q "beryl-presence-lab" website/dist/examples/index.html
grep -q "Enable JavaScript to run the live scenario" website/dist/examples/index.html
grep -q 'compatibility-version="1"' website/dist/examples/index.html
! grep -q "/interactive/beryl_site.mjs" website/dist/index.html
```

Expected: all commands exit `0`.

- [ ] **Step 5: Commit**

```bash
git add website/src/components/PresenceLab.astro website/src/content/docs/examples.mdx website/package.json
git commit -m "feat(site): embed live presence lab"
```

---

### Task 6: Add browser tests and CI coverage

**Files:**
- Create: `website/playwright.config.js`
- Create: `website/e2e/presence-lab.spec.js`
- Modify via pnpm: `website/package.json`
- Modify via pnpm: `website/pnpm-lock.yaml`
- Modify: `justfile`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: `pnpm -C website test:e2e`
- Produces: `just site-interactive-test`
- Produces: `just site-demo-test`
- Produces: `just site-e2e`
- Produces: `just site-ci`

- [ ] **Step 1: Add Playwright to the website package**

Run:

```bash
pnpm -C website add -D @playwright/test@^1.58.2
```

Add:

```json
{
  "scripts": {
    "test:e2e": "playwright test"
  }
}
```

- [ ] **Step 2: Configure the two local servers**

Create `website/playwright.config.js`:

```js
// @ts-check
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  retries: 0,
  use: {
    baseURL: "http://127.0.0.1:4321",
    headless: true,
  },
  webServer: [
    {
      command: "gleam run",
      cwd: "./demo_server",
      url: "http://127.0.0.1:4100/healthz",
      reuseExistingServer: !process.env.CI,
      timeout: 60_000,
      env: {
        ...process.env,
        PORT: "4100",
        BIND_ADDRESS: "127.0.0.1",
        ALLOWED_ORIGINS: "http://127.0.0.1:4321",
        BERYL_VERSION: "test",
      },
    },
    {
      command:
        "pnpm run build:interactive && pnpm exec astro dev --host 127.0.0.1 --port 4321",
      url: "http://127.0.0.1:4321/examples/",
      reuseExistingServer: !process.env.CI,
      timeout: 60_000,
      env: {
        ...process.env,
        PUBLIC_BERYL_DEMO_URL: "http://127.0.0.1:4100",
      },
    },
  ],
  projects: [
    {
      name: "chromium",
      grepInvert: /static fallback/,
      use: { browserName: "chromium" },
    },
    {
      name: "no-javascript",
      use: { browserName: "chromium", javaScriptEnabled: false },
      grep: /static fallback/,
    },
  ],
});
```

- [ ] **Step 3: Write failing browser tests**

Create `website/e2e/presence-lab.spec.js`:

```js
import { expect, test } from "@playwright/test";

test("static fallback remains readable without JavaScript", async ({ page }) => {
  await page.goto("/examples/");
  await expect(page.getByText("Enable JavaScript to run the live scenario")).toBeVisible();
});

test("connects two clients and records join and leave diffs", async ({ page }) => {
  await page.goto("/examples/");
  const lab = page.locator("beryl-presence-lab");
  const control = (testId) => lab.getByTestId(testId);

  await control("primary-name").fill("Alice");
  await control("connect-primary").click();
  await expect(control("presence-status")).toContainText("Connected");
  await expect(control("presence-list").locator("li")).toHaveCount(1);

  await control("add-secondary").click();
  await expect(control("presence-list").locator("li")).toHaveCount(2);
  await expect(control("event-transcript")).toContainText("presence_diff");

  await control("disconnect-secondary").click();
  await expect(control("presence-list").locator("li")).toHaveCount(1);
  await expect(control("event-transcript")).toContainText("leave");
});

test("reset creates a fresh isolated scenario", async ({ page }) => {
  await page.goto("/examples/");
  const lab = page.locator("beryl-presence-lab");
  const control = (testId) => lab.getByTestId(testId);
  await control("connect-primary").click();
  await expect(control("presence-status")).toContainText("Connected");
  const firstTopic = await control("scenario-topic").textContent();

  await control("reset-scenario").click();
  await expect(control("presence-status")).toContainText("Connected");
  const secondTopic = await control("scenario-topic").textContent();

  expect(secondTopic).not.toBe(firstTopic);
});

test("recovers after the browser goes offline", async ({ page, context }) => {
  await page.goto("/examples/");
  const lab = page.locator("beryl-presence-lab");
  const control = (testId) => lab.getByTestId(testId);
  await control("connect-primary").click();
  await expect(control("presence-status")).toContainText("Connected");

  await context.setOffline(true);
  await expect(control("presence-status")).toContainText("Offline");
  await expect(
    page.getByText("This lab connects two short-lived Phoenix clients"),
  ).toBeVisible();

  await context.setOffline(false);
  await expect(control("presence-status")).toContainText("Connected", {
    timeout: 20_000,
  });
});

test("blocks incompatible component versions", async ({ page }) => {
  await page.goto("/examples/");
  const lab = page.locator("beryl-presence-lab");
  const control = (testId) => lab.getByTestId(testId);
  await lab.evaluate((element) => {
    element.setAttribute("compatibility-version", "99");
  });

  await control("connect-primary").click();
  await expect(control("presence-status")).toContainText("Incompatible");
  await expect(control("connect-primary")).toBeDisabled();
});

test("supports keyboard operation at a mobile width", async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 812 });
  await page.goto("/examples/");
  const lab = page.locator("beryl-presence-lab");
  const control = (testId) => lab.getByTestId(testId);

  await control("connect-primary").focus();
  await page.keyboard.press("Enter");
  await expect(control("presence-status")).toContainText("Connected");

  const hasHorizontalOverflow = await page.evaluate(
    () => document.documentElement.scrollWidth > window.innerWidth,
  );
  expect(hasHorizontalOverflow).toBe(false);
});
```

Playwright locators pierce open shadow roots, so chaining `getByTestId` from the
component host keeps selectors scoped and stable.

- [ ] **Step 4: Run the browser tests and fix only implementation defects**

Run:

```bash
pnpm -C website exec playwright install chromium
pnpm -C website test:e2e
```

Expected: both Chromium projects pass. If a test exposes a race, fix the
component's explicit state transition or callback ordering; do not add sleeps.

- [ ] **Step 5: Add focused Just recipes**

Add to `justfile`:

```just
site-interactive-deps:
    cd website/interactive && gleam deps download

site-interactive-test:
    cd website/interactive && gleam test --target javascript

site-demo-deps:
    cd website/demo_server && gleam deps download

site-demo-test:
    cd website/demo_server && gleam test

site-e2e:
    pnpm -C website test:e2e

site-ci: site-reference-test site-interactive-test site-demo-test site-check site-build site-e2e
```

Extend `site-deps`:

```just
site-deps:
    pnpm -C website install
    cd website/interactive && gleam deps download
    cd website/demo_server && gleam deps download
```

- [ ] **Step 6: Extend the website CI job**

Modify `.github/workflows/ci.yml` `docs` job:

1. After `Setup environment`, add:

```yaml
- name: Install rebar3
  uses: ./.github/actions/install-rebar3
```

2. After pnpm install, run:

```yaml
- name: Install interactive client dependencies
  run: cd website/interactive && gleam deps download

- name: Install demo server dependencies
  run: cd website/demo_server && gleam deps download
```

3. Add:

```yaml
- name: Test Lustre interactive client
  run: just site-interactive-test

- name: Test demo server
  run: just site-demo-test

- name: Check website
  run: just site-check

- name: Build website
  run: just site-build

- name: Install Playwright browser
  run: pnpm -C website exec playwright install --with-deps chromium

- name: Test interactive website
  run: just site-e2e
```

- [ ] **Step 7: Run the focused site gate**

Run:

```bash
just site-ci
```

Expected: reference generator, both Gleam projects, Astro check, static build,
and browser tests pass.

- [ ] **Step 8: Commit**

```bash
git add website/playwright.config.js website/e2e website/package.json website/pnpm-lock.yaml justfile .github/workflows/ci.yml
git commit -m "test(site): cover presence lab end to end"
```

---

### Task 7: Package the service, document operation, and finish the change

**Files:**
- Create: `website/demo_server/Dockerfile`
- Create: `website/demo_server/Dockerfile.dockerignore`
- Create: `website/demo_server/README.md`
- Modify: `website/netlify.toml`
- Create via changie: `.changes/unreleased/*.yaml`

**Interfaces:**
- Produces: `docker build -f website/demo_server/Dockerfile -t beryl-demo .`
- Runtime environment: `PORT`, `BIND_ADDRESS`, `ALLOWED_ORIGINS`, `BERYL_VERSION`
- Health check: `/healthz`

- [ ] **Step 1: Add the provider-neutral Docker image**

Create `website/demo_server/Dockerfile` by adapting the proven
`examples/cursors/Dockerfile` pattern:

```dockerfile
FROM erlang:27.2.1-alpine AS build

ARG GLEAM_VERSION=v1.16.0

RUN apk add --no-cache git rebar3 curl ca-certificates \
 && case "$(uname -m)" in \
      aarch64) GLEAM_ARCH=aarch64-unknown-linux-musl ;; \
      x86_64)  GLEAM_ARCH=x86_64-unknown-linux-musl ;; \
      *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/${GLEAM_VERSION}/gleam-${GLEAM_VERSION}-${GLEAM_ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin gleam

WORKDIR /src
COPY . .
RUN test -f /src/gleam.toml && grep -q '^name = "beryl"' /src/gleam.toml

WORKDIR /src/website/demo_server
RUN gleam deps download \
 && gleam export erlang-shipment

FROM erlang:27.2.1-alpine AS runtime

RUN apk add --no-cache libstdc++ ncurses-libs openssl ca-certificates

WORKDIR /app
COPY --from=build /src/website/demo_server/build/erlang-shipment ./

ENV BIND_ADDRESS=0.0.0.0
ENV PORT=4100
EXPOSE 4100

CMD ["./entrypoint.sh", "run"]
```

Create `website/demo_server/Dockerfile.dockerignore`:

```dockerignore
**/build/
**/_build/
**/node_modules/
**/.git/
**/test-results/
**/playwright-report/
**/.lustre/
*.log
erl_crash.dump
```

- [ ] **Step 2: Document local and container operation**

Create `website/demo_server/README.md`:

````markdown
# Beryl documentation demo service

This service runs the public realtime scenarios embedded in the beryl
documentation. It is intentionally separate from the static site: every client
is untrusted, joins only randomized `demo:presence:*` topics, and receives no
access to application data.

## Run locally

```bash
PORT=4100 \
BIND_ADDRESS=127.0.0.1 \
ALLOWED_ORIGINS=http://127.0.0.1:4321 \
BERYL_VERSION=development \
gleam run
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `4100` | HTTP and WebSocket listener port |
| `BIND_ADDRESS` | `127.0.0.1` | Listener interface |
| `ALLOWED_ORIGINS` | Documentation and local origins | Comma-separated exact WebSocket Origin allow-list |
| `BERYL_VERSION` | `development` | Version reported by `/v1/status` |

Production must set:

```text
ALLOWED_ORIGINS=https://beryl.tylerbutler.com
```

## Container

Build from the repository root because the nested project uses the root beryl
package as a path dependency:

```bash
docker build -f website/demo_server/Dockerfile -t beryl-demo .
docker run --rm \
  -p 4100:4100 \
  -e ALLOWED_ORIGINS=https://beryl.tylerbutler.com \
  -e BERYL_VERSION=0.1.0 \
  beryl-demo
```

## Health and compatibility

```bash
curl --fail http://127.0.0.1:4100/healthz
curl --fail http://127.0.0.1:4100/v1/status
```

`/v1/status` returns:

```json
{
  "status": "ok",
  "compatibility_version": 1,
  "beryl_version": "0.1.0",
  "scenarios": ["presence-v1"]
}
```

The service stores no user data. Presence state is ephemeral and is removed when
the owning socket disconnects.
````

- [ ] **Step 3: Make Netlify rebuild when interactive sources change**

The current `website/netlify.toml` already diffs the whole `website/` directory.
Add this line immediately above `ignore`; do not change the command:

```toml
  # The website-wide diff includes interactive/ sources and bundle inputs.
```

- [ ] **Step 4: Build and smoke-test the image**

Run:

```bash
docker build -f website/demo_server/Dockerfile -t beryl-demo .
container_id=$(docker run --rm -d \
  --name beryl-demo-smoke \
  -p 4100:4100 \
  -e ALLOWED_ORIGINS=http://127.0.0.1:4321 \
  -e BERYL_VERSION=test \
  beryl-demo)
trap 'docker rm -f "$container_id" >/dev/null 2>&1 || true' EXIT
curl --fail --retry 10 --retry-connrefused --retry-delay 1 \
  http://127.0.0.1:4100/healthz
status=$(curl --fail http://127.0.0.1:4100/v1/status)
printf '%s' "$status" | grep -Fq '"compatibility_version":1'
printf '%s' "$status" | grep -Fq '"scenarios":["presence-v1"]'
docker stop "$container_id"
trap - EXIT
```

Expected: image builds, health check returns `ok`, and the named container
stops cleanly. If port `4100` is occupied, choose a free host port while
preserving container port `4100`.

- [ ] **Step 5: Add the changie entry**

Run:

```bash
just change
```

Choose the repository's user-visible “Added” kind and enter:

```text
Add an interactive Lustre-powered presence lab and deployable demo service to the documentation site.
```

- [ ] **Step 6: Run final validation**

Run:

```bash
just format-check
just check
just test
just build-strict
just site-ci
git diff --check
git status --short
```

Expected:

- root Gleam checks pass
- nested interactive and demo server tests pass
- Astro check and build pass
- browser tests pass
- no generated `website/public/interactive/`, Playwright artifacts, or temporary
  logs are staged
- only intended source, tests, manifests, lockfile, docs, CI, Docker, and
  changie files remain

- [ ] **Step 7: Commit**

```bash
git add website/demo_server/Dockerfile website/demo_server/Dockerfile.dockerignore website/demo_server/README.md website/netlify.toml .changes/unreleased
git commit -m "docs(site): package presence demo service"
```

---

## Out of Scope for This Plan

Create separate specifications and plans for:

- cursor, chat, and collaborative-state labs
- message-lifecycle and CRDT visualizers
- guided configuration playgrounds
- shareable URL-state encoding for future guided scenarios
- generated API JSON and the API explorer
- a parallel `lustre_ssg` site shell
- compiler-backed Gleam execution
- provider-specific hosting and DNS provisioning
