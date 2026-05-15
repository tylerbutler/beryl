# Collaborative CRDT Documents Example Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `examples/collab_docs`, a runnable Beryl example where browser clients use lattice CRDT packages to merge collaborative document blocks without server sequencing.

**Architecture:** The example has an Erlang-target Gleam server package and a JavaScript-target Gleam client package. Browser clients own CRDT state (`ORMap(MvRegisterSpec)`), Beryl relays serialized states on `document:*:*` topics, and a server actor keeps a merged cache only for late joiners.

**Tech Stack:** Gleam, Beryl, Mist, Phoenix JS client, `lattice_core`, `lattice_maps`, `lattice_registers`, Playwright, pnpm.

---

## File Map

- Create `examples/collab_docs/gleam.toml`: Erlang-target server package config.
- Create `examples/collab_docs/package.json`: scripts for client bundle and Playwright.
- Create `examples/collab_docs/playwright.config.js`: e2e config on port `8002`.
- Create `examples/collab_docs/README.md`: example docs.
- Create `examples/collab_docs/src/collab_docs.gleam`: server entry point.
- Create `examples/collab_docs/src/collab_docs_ffi.erl`: `timestamp_ms/0` and `random_id/0`.
- Create `examples/collab_docs/src/collab_docs/channel.gleam`: Beryl channel callbacks.
- Create `examples/collab_docs/src/collab_docs/doc_store.gleam`: OTP actor cache.
- Create `examples/collab_docs/src/collab_docs/router.gleam`: static router.
- Create `examples/collab_docs/client/gleam.toml`: JS-target client package config.
- Create `examples/collab_docs/client/src/collab_docs_client.gleam`: CRDT API compiled to JS.
- Create `examples/collab_docs/client/test/collab_docs_client_test.gleam`: pure client CRDT tests.
- Create `examples/collab_docs/client/src/browser_exports.mjs`: stable JS re-export shim if Gleam output paths need one.
- Create `examples/collab_docs/priv/static/app.js`: browser UI and Phoenix channel glue.
- Create `examples/collab_docs/priv/static/style.css`: example styles.
- Create `examples/collab_docs/e2e/collab_docs.spec.js`: Playwright acceptance tests.
- Modify `examples/pnpm-workspace.yaml`: add `collab_docs`.
- Modify `justfile`: add collab docs deps/build/client-build/test wiring.
- Modify `README.md`: add example row.
- Modify `website/src/content/docs/examples.mdx`: add example section.
- Modify `website/src/content/docs/index.mdx`: update examples card.
- Create changie fragment with repo workflow.

---

### Task 1: Scaffold Example Packages and Build Hooks

**Files:**
- Create: `examples/collab_docs/gleam.toml`
- Create: `examples/collab_docs/client/gleam.toml`
- Create: `examples/collab_docs/package.json`
- Create: `examples/collab_docs/playwright.config.js`
- Modify: `examples/pnpm-workspace.yaml`
- Modify: `justfile`

- [ ] **Step 1: Create server package config**

Create `examples/collab_docs/gleam.toml`:

```toml
name = "collab_docs"
version = "0.1.0"
description = "Collaborative CRDT document blocks demo for beryl"
gleam = ">= 1.7.0"
target = "erlang"

[dependencies]
beryl = { path = "../.." }
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_erlang = ">= 0.29.0 and < 2.0.0"
gleam_otp = ">= 0.12.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
gleam_http = ">= 4.3.0 and < 5.0.0"
mist = ">= 6.0.0 and < 7.0.0"
lattice_core = ">= 1.0.0 and < 2.0.0"
lattice_maps = ">= 1.0.0 and < 2.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
```

- [ ] **Step 2: Create client package config**

Create `examples/collab_docs/client/gleam.toml`:

```toml
name = "collab_docs_client"
version = "0.1.0"
description = "Browser CRDT client for the beryl collaborative docs example"
gleam = ">= 1.7.0"
target = "javascript"

[javascript]
runtime = "node"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
lattice_core = ">= 1.0.0 and < 2.0.0"
lattice_maps = ">= 1.0.0 and < 2.0.0"
lattice_registers = ">= 1.0.0 and < 2.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
```

- [ ] **Step 3: Create package scripts**

Create `examples/collab_docs/package.json`:

```json
{
  "name": "collab_docs",
  "private": true,
  "description": "Collaborative CRDT document blocks demo built with beryl.",
  "type": "module",
  "scripts": {
    "build:client": "cd client && gleam build && node ../scripts/bundle-client.mjs",
    "test": "playwright test"
  },
  "devDependencies": {
    "@playwright/test": "^1.58.2",
    "esbuild": "^0.27.0"
  }
}
```

- [ ] **Step 4: Add bundler script**

Create `examples/collab_docs/scripts/bundle-client.mjs`:

```js
import { build } from "esbuild";
import { mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const exampleRoot = resolve(here, "..");
const entry = resolve(
  exampleRoot,
  "client/build/dev/javascript/collab_docs_client/collab_docs_client.mjs",
);
const outfile = resolve(exampleRoot, "priv/static/collab_docs_client.mjs");

await mkdir(dirname(outfile), { recursive: true });
await build({
  entryPoints: [entry],
  outfile,
  bundle: true,
  format: "esm",
  platform: "browser",
});
```

- [ ] **Step 5: Create Playwright config**

Create `examples/collab_docs/playwright.config.js`:

```js
// @ts-check
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  retries: 0,
  use: {
    baseURL: "http://localhost:8002",
    headless: true,
  },
  webServer: {
    command: "gleam run",
    url: "http://localhost:8002",
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
  },
  projects: [
    { name: "chromium", use: { browserName: "chromium" } },
  ],
});
```

- [ ] **Step 6: Wire workspace and justfile**

Update `examples/pnpm-workspace.yaml`:

```yaml
packages:
  - "cursors"
  - "chatrooms"
  - "collab_docs"
```

Update `justfile` example recipes:

```just
# Build all examples
examples-build: examples-client-build
    cd examples/cursors && gleam build
    cd examples/chatrooms && gleam build
    cd examples/collab_docs && gleam build

# Build JavaScript clients used by examples
examples-client-build:
    pnpm -C examples/collab_docs build:client

# Run example Playwright tests
examples-test: examples-build
    pnpm -C examples/cursors test
    pnpm -C examples/chatrooms test
    pnpm -C examples/collab_docs test
```

Also add these lines to the existing `deps` recipe:

```just
    cd examples/collab_docs && gleam deps download
    cd examples/collab_docs/client && gleam deps download
```

- [ ] **Step 7: Install deps and verify scaffold**

Run:

```bash
just deps
pnpm -C examples/collab_docs build:client
```

Expected: dependency manifests and lockfile update. Do not run `pnpm -C examples/collab_docs build:client` again until Task 2 creates `collab_docs_client.gleam`.

- [ ] **Step 8: Commit scaffold**

```bash
git add examples/pnpm-workspace.yaml justfile examples/collab_docs examples/pnpm-lock.yaml
git commit -m "build(examples): scaffold collab docs example"
```

---

### Task 2: Implement Client CRDT Module with Tests

**Files:**
- Create: `examples/collab_docs/client/src/collab_docs_client.gleam`
- Create: `examples/collab_docs/client/test/collab_docs_client_test.gleam`

- [ ] **Step 1: Write failing client tests**

Create `examples/collab_docs/client/test/collab_docs_client_test.gleam`:

```gleam
import collab_docs_client as docs
import gleeunit/should
import gleam/list

pub fn independent_adds_converge_test() {
  let a =
    docs.new_document("client-a")
    |> docs.add_block("{\"id\":\"a\",\"kind\":\"todo\",\"text\":\"A\",\"done\":false,\"position\":\"a0\"}")
  let b =
    docs.new_document("client-b")
    |> docs.add_block("{\"id\":\"b\",\"kind\":\"todo\",\"text\":\"B\",\"done\":false,\"position\":\"b0\"}")

  let assert Ok(a2) = docs.merge_json(a, docs.to_json(b))
  let assert Ok(b2) = docs.merge_json(b, docs.to_json(a))

  docs.blocks(a2) |> list.length |> should.equal(2)
  docs.blocks(b2) |> list.length |> should.equal(2)
}

pub fn concurrent_edits_create_conflict_test() {
  let base =
    docs.new_document("client-a")
    |> docs.add_block("{\"id\":\"shared\",\"kind\":\"todo\",\"text\":\"Original\",\"done\":false,\"position\":\"a0\"}")

  let assert Ok(a) = docs.merge_json(docs.new_document("client-a"), docs.to_json(base))
  let assert Ok(b) = docs.merge_json(docs.new_document("client-b"), docs.to_json(base))

  let a = docs.edit_block(a, "shared", "{\"id\":\"shared\",\"kind\":\"todo\",\"text\":\"Alice\",\"done\":false,\"position\":\"a0\"}")
  let b = docs.edit_block(b, "shared", "{\"id\":\"shared\",\"kind\":\"todo\",\"text\":\"Bob\",\"done\":false,\"position\":\"a0\"}")

  let assert Ok(merged) = docs.merge_json(a, docs.to_json(b))
  let [block] = docs.blocks(merged)
  block.values |> list.length |> should.equal(2)
}

pub fn duplicate_merge_is_idempotent_test() {
  let a =
    docs.new_document("client-a")
    |> docs.add_block("{\"id\":\"a\",\"kind\":\"todo\",\"text\":\"A\",\"done\":false,\"position\":\"a0\"}")
  let json = docs.to_json(a)

  let assert Ok(merged_once) = docs.merge_json(docs.new_document("client-b"), json)
  let assert Ok(merged_twice) = docs.merge_json(merged_once, json)

  docs.blocks(merged_twice) |> list.length |> should.equal(1)
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
cd examples/collab_docs/client && gleam test
```

Expected: FAIL because `collab_docs_client` module is missing.

- [ ] **Step 3: Implement client module**

Create `examples/collab_docs/client/src/collab_docs_client.gleam`:

```gleam
import gleam/json
import gleam/list
import gleam/result
import gleam/dynamic/decode
import lattice_core/replica_id
import lattice_maps/crdt
import lattice_maps/or_map
import lattice_registers/mv_register

pub opaque type Document {
  Document(replica_id: replica_id.ReplicaId, state: or_map.ORMap)
}

pub type RenderBlock {
  RenderBlock(id: String, values: List(String))
}

pub fn new_document(replica: String) -> Document {
  let id = replica_id.new(replica)
  Document(replica_id: id, state: or_map.new(id, crdt.MvRegisterSpec))
}

pub fn from_json(replica: String, encoded: String) -> Result(Document, String) {
  case or_map.from_json(encoded) {
    Ok(state) -> Ok(Document(replica_id: replica_id.new(replica), state: state))
    Error(_) -> Error("invalid_state")
  }
}

pub fn to_json(document: Document) -> String {
  let Document(_, state) = document
  state
  |> or_map.to_json
  |> json.to_string
}

pub fn add_block(document: Document, block_json: String) -> Document {
  upsert_block(document, block_json)
}

pub fn edit_block(
  document: Document,
  block_id: String,
  block_json: String,
) -> Document {
  case string_id_matches(block_json, block_id) {
    True -> upsert_block(document, block_json)
    False -> document
  }
}

pub fn remove_block(document: Document, block_id: String) -> Document {
  let Document(replica_id, state) = document
  Document(replica_id:, state: or_map.remove(state, block_id))
}

pub fn merge_json(
  document: Document,
  remote_json: String,
) -> Result(Document, String) {
  let Document(replica_id, state) = document
  use remote <- result.try(or_map.from_json(remote_json) |> result.map_error(fn(_) { "invalid_state" }))
  case or_map.merge(state, remote) {
    Ok(merged) -> Ok(Document(replica_id:, state: merged))
    Error(_) -> Error("merge_failed")
  }
}

pub fn blocks(document: Document) -> List(RenderBlock) {
  let Document(_, state) = document
  state
  |> or_map.keys
  |> list.map(fn(key) {
    let values = case or_map.get(state, key) {
      Ok(crdt.CrdtMvRegister(register)) -> mv_register.value(register)
      _ -> []
    }
    RenderBlock(id: key, values: values)
  })
}

pub fn blocks_json(document: Document) -> String {
  let block_values =
    blocks(document)
    |> list.map(fn(block) {
      json.object([
        #("id", json.string(block.id)),
        #("values", json.array(block.values, json.string)),
      ])
    })
  json.array(block_values, fn(value) { value })
  |> json.to_string
}

pub fn merge_json_or_keep(document: Document, remote_json: String) -> Document {
  case merge_json(document, remote_json) {
    Ok(merged) -> merged
    Error(_) -> document
  }
}

fn upsert_block(document: Document, block_json: String) -> Document {
  let Document(replica_id, state) = document
  let id = extract_json_string(block_json, "id")
  case id {
    "" -> document
    block_id -> {
      let state =
        or_map.update(state, block_id, fn(value) {
          case value {
            crdt.CrdtMvRegister(register) ->
              crdt.CrdtMvRegister(mv_register.set(register, block_json))
            other -> other
          }
        })
      Document(replica_id:, state:)
    }
  }
}

fn string_id_matches(block_json: String, block_id: String) -> Bool {
  extract_json_string(block_json, "id") == block_id
}

fn extract_json_string(block_json: String, field: String) -> String {
  let decoder = {
    use value <- decode.field(field, decode.string)
    decode.success(value)
  }
  case json.parse(block_json, decoder) {
    Ok(found) -> found
    Error(_) -> ""
  }
}
```

- [ ] **Step 4: Run client tests**

Run:

```bash
cd examples/collab_docs/client && gleam test
```

Expected: PASS.

- [ ] **Step 5: Build browser bundle**

Run:

```bash
pnpm -C examples/collab_docs build:client
```

Expected: `examples/collab_docs/priv/static/collab_docs_client.mjs` exists.

- [ ] **Step 6: Commit client CRDT module**

```bash
git add examples/collab_docs/client examples/collab_docs/priv/static/collab_docs_client.mjs examples/collab_docs/manifest.toml examples/collab_docs/client/manifest.toml
git commit -m "feat(examples): add collab docs CRDT client"
```

---

### Task 3: Implement Server Cache Actor

**Files:**
- Create: `examples/collab_docs/src/collab_docs/doc_store.gleam`
- Create: `examples/collab_docs/test/doc_store_test.gleam`

- [ ] **Step 1: Write failing doc store tests**

Create `examples/collab_docs/test/doc_store_test.gleam`:

```gleam
import collab_docs/doc_store
import gleam/json
import gleeunit/should
import lattice_core/replica_id
import lattice_maps/crdt
import lattice_maps/or_map

pub fn put_and_get_state_test() {
  let assert Ok(store) = doc_store.start()
  let state =
    or_map.new(replica_id.new("server"), crdt.MvRegisterSpec)
    |> or_map.to_json
    |> json.to_string

  doc_store.merge_state(store, "demo/welcome", state)
  let assert Ok(found) = doc_store.get_state(store, "demo/welcome")

  found |> should.equal(state)
}

pub fn missing_state_returns_error_test() {
  let assert Ok(store) = doc_store.start()
  doc_store.get_state(store, "demo/missing") |> should.be_error
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
cd examples/collab_docs && gleam test -- --filter doc_store
```

Expected: FAIL because `collab_docs/doc_store` is missing.

- [ ] **Step 3: Implement doc store actor**

Create `examples/collab_docs/src/collab_docs/doc_store.gleam`:

```gleam
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import lattice_maps/or_map

pub opaque type Store {
  Store(subject: Subject(Message))
}

type Message {
  Get(key: String, reply: Subject(Result(String, Nil)))
  Merge(key: String, encoded: String)
}

type State {
  State(docs: Dict(String, or_map.ORMap))
}

pub fn start() -> Result(Store, actor.StartError) {
  actor.new(State(docs: dict.new()))
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { Store(started.data) })
}

pub fn get_state(store: Store, key: String) -> Result(String, Nil) {
  let Store(subject) = store
  let reply = process.new_subject()
  process.send(subject, Get(key, reply))
  process.receive(reply, 1000)
  |> result.unwrap(Error(Nil))
}

pub fn merge_state(store: Store, key: String, encoded: String) -> Nil {
  let Store(subject) = store
  process.send(subject, Merge(key, encoded))
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Get(key, reply) -> {
      let response = case dict.get(state.docs, key) {
        Ok(doc) -> Ok(doc |> or_map.to_json |> json.to_string)
        Error(_) -> Error(Nil)
      }
      process.send(reply, response)
      actor.continue(state)
    }
    Merge(key, encoded) -> {
      let docs = case or_map.from_json(encoded) {
        Ok(remote) -> {
          let merged = case dict.get(state.docs, key) {
            Ok(local) ->
              case or_map.merge(local, remote) {
                Ok(value) -> value
                Error(_) -> local
              }
            Error(_) -> remote
          }
          dict.insert(state.docs, key, merged)
        }
        Error(_) -> state.docs
      }
      actor.continue(State(docs: docs))
    }
  }
}
```

- [ ] **Step 4: Run doc store tests**

Run:

```bash
cd examples/collab_docs && gleam test -- --filter doc_store
```

Expected: PASS.

- [ ] **Step 5: Commit doc store**

```bash
git add examples/collab_docs/src/collab_docs/doc_store.gleam examples/collab_docs/test/doc_store_test.gleam
git commit -m "feat(examples): add collab docs state cache"
```

---

### Task 4: Implement Beryl Channel, Router, and Server Entry Point

**Files:**
- Create: `examples/collab_docs/src/collab_docs/channel.gleam`
- Create: `examples/collab_docs/src/collab_docs/router.gleam`
- Create: `examples/collab_docs/src/collab_docs.gleam`
- Create: `examples/collab_docs/src/collab_docs_ffi.erl`

- [ ] **Step 1: Implement channel**

Create `examples/collab_docs/src/collab_docs/channel.gleam`:

```gleam
import beryl
import beryl/channel.{type Channel, type HandleResult, type JoinResult}
import beryl/socket.{type Socket}
import beryl/topic
import collab_docs/doc_store.{type Store}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}

pub type Assigns {
  Assigns(
    channels: beryl.Channels,
    store: Store,
    topic_name: String,
    document_key: String,
  )
}

pub fn new_handler(channels: beryl.Channels, store: Store) -> Channel(Assigns) {
  channel.new(fn(topic_name, _payload, socket) {
    join(channels, store, topic_name, socket)
  })
  |> channel.with_handle_in(handle_in)
}

fn join(
  channels: beryl.Channels,
  store: Store,
  topic_name: String,
  socket: Socket(Assigns),
) -> JoinResult(Assigns) {
  let pattern = topic.parse_pattern("document:*:*")
  let assert Ok([tenant, doc_id]) = topic.extract_wildcards(pattern, topic_name)
  let document_key = tenant <> "/" <> doc_id
  let socket = socket.set_assigns(socket, Assigns(channels:, store:, topic_name:, document_key:))
  let cached_state = case doc_store.get_state(store, document_key) {
    Ok(state) -> json.string(state)
    Error(_) -> json.null()
  }
  channel.JoinOk(
    reply: Some(json.object([
      #("tenant", json.string(tenant)),
      #("document", json.string(doc_id)),
      #("state", cached_state),
    ])),
    socket:,
  )
}

fn handle_in(
  event: String,
  payload: json.Json,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  let assigns = socket.get_assigns(socket)
  case event {
    "sync_state" -> {
      case decode.run(payload, decode.field("state", decode.string)) {
        Ok(state) -> {
          doc_store.merge_state(assigns.store, assigns.document_key, state)
          beryl.broadcast_from(
            assigns.channels,
            socket.id(socket),
            assigns.topic_name,
            "doc_state",
            json.object([#("state", json.string(state))]),
          )
          channel.NoReply(socket)
        }
        Error(_) ->
          channel.Reply(
            event: "state_error",
            payload: json.object([#("code", json.string("invalid_state"))]),
            socket:,
          )
      }
    }
    _ ->
      channel.Reply(
        event: "state_error",
        payload: json.object([#("code", json.string("unknown_event"))]),
        socket:,
      )
  }
}
```

- [ ] **Step 2: Implement router**

Create `examples/collab_docs/src/collab_docs/router.gleam` by copying the static serving helper structure from `examples/cursors/src/cursors/router.gleam`, changing `priv_directory("cursors")` to `priv_directory("collab_docs")`, and using this index page:

```gleam
fn index_page() -> Response(ResponseData) {
  let html =
    "<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>Collaborative CRDT Docs — beryl demo</title>
  <link rel=\"stylesheet\" href=\"/static/style.css\">
</head>
<body>
  <main id=\"app\">
    <header>
      <h1>Collaborative CRDT Docs</h1>
      <p>Client-side CRDT document blocks synced over beryl channels.</p>
    </header>
    <section id=\"toolbar\">
      <button id=\"add-todo\">Add todo</button>
      <button id=\"add-note\">Add note</button>
      <span id=\"status\">Connecting...</span>
    </section>
    <section id=\"blocks\" aria-label=\"Document blocks\"></section>
  </main>
  <script src=\"https://unpkg.com/phoenix@1.7.20/priv/static/phoenix.js\"></script>
  <script type=\"module\" src=\"/static/app.js\"></script>
</body>
</html>"

  html_response(html)
}
```

- [ ] **Step 3: Implement FFI**

Create `examples/collab_docs/src/collab_docs_ffi.erl`:

```erlang
-module(collab_docs_ffi).
-export([timestamp_ms/0, random_id/0]).

timestamp_ms() ->
    erlang:system_time(millisecond).

random_id() ->
    integer_to_binary(erlang:unique_integer([positive, monotonic]), 36).
```

- [ ] **Step 4: Implement main**

Create `examples/collab_docs/src/collab_docs.gleam`:

```gleam
import beryl
import beryl/transport/mist as mist_transport
import beryl/wire
import collab_docs/channel
import collab_docs/doc_store
import collab_docs/router
import gleam/erlang/process
import gleam/io
import mist

pub fn main() {
  let assert Ok(store) = doc_store.start()
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let handler = channel.new_handler(channels, store)
  let assert Ok(_) = beryl.register(channels, "document:*:*", handler)

  io.println("Collaborative CRDT Docs")
  io.println("Open http://localhost:8002")

  let ctx = router.Context()
  let assert Ok(_) =
    fn(req) {
      mist_transport.upgrade(
        req,
        channels.coordinator,
        mist_transport.default_config("/socket/websocket"),
        fn() { router.handle_request(req, ctx) },
      )
    }
    |> mist.new
    |> mist.port(8002)
    |> mist.start

  process.sleep_forever()
}
```

- [ ] **Step 5: Build server**

Run:

```bash
cd examples/collab_docs && gleam build
```

Expected: PASS.

- [ ] **Step 6: Commit server**

```bash
git add examples/collab_docs/src
git commit -m "feat(examples): add collab docs server"
```

---

### Task 5: Build Browser UI

**Files:**
- Create: `examples/collab_docs/priv/static/app.js`
- Create: `examples/collab_docs/priv/static/style.css`

- [ ] **Step 1: Create browser app**

Create `examples/collab_docs/priv/static/app.js`:

```js
import * as crdt from "./collab_docs_client.mjs";

const { Socket } = window.Phoenix;
const replicaId = `client-${crypto.randomUUID()}`;
let doc = crdt.new_document(replicaId);
let channel;

const blocksEl = document.getElementById("blocks");
const statusEl = document.getElementById("status");

function blockFromJson(value) {
  return JSON.parse(value);
}

function render() {
  blocksEl.innerHTML = "";
  const blocks = JSON.parse(crdt.blocks_json(doc)).sort((a, b) => {
    const av = blockFromJson(a.values[0] || "{}").position || "";
    const bv = blockFromJson(b.values[0] || "{}").position || "";
    return av.localeCompare(bv);
  });

  for (const block of blocks) {
    if (block.values.length > 1) {
      renderConflict(block);
    } else if (block.values.length === 1) {
      renderBlock(blockFromJson(block.values[0]));
    }
  }
}

function renderBlock(block) {
  const el = document.createElement("article");
  el.className = "block";
  el.dataset.blockId = block.id;
  el.innerHTML = `
    <label>
      <input class="done" type="checkbox" ${block.done ? "checked" : ""}>
      <textarea class="text">${escapeHtml(block.text)}</textarea>
    </label>
    <button class="delete">Delete</button>
  `;
  el.querySelector(".text").addEventListener("change", (event) => {
    block.text = event.target.value;
    applyLocal(crdt.edit_block(doc, block.id, JSON.stringify(block)));
  });
  el.querySelector(".done").addEventListener("change", (event) => {
    block.done = event.target.checked;
    applyLocal(crdt.edit_block(doc, block.id, JSON.stringify(block)));
  });
  el.querySelector(".delete").addEventListener("click", () => {
    applyLocal(crdt.remove_block(doc, block.id));
  });
  blocksEl.appendChild(el);
}

function renderConflict(block) {
  const el = document.createElement("article");
  el.className = "block conflict";
  el.dataset.blockId = block.id;
  el.innerHTML = `<h2>Conflict: ${escapeHtml(block.id)}</h2>`;
  block.values.forEach((value, index) => {
    const parsed = blockFromJson(value);
    const option = document.createElement("div");
    option.className = "conflict-option";
    option.innerHTML = `
      <p>${escapeHtml(parsed.text)}</p>
      <button>Use version ${index + 1}</button>
    `;
    option.querySelector("button").addEventListener("click", () => {
      applyLocal(crdt.edit_block(doc, parsed.id, JSON.stringify(parsed)));
    });
    el.appendChild(option);
  });
  blocksEl.appendChild(el);
}

function applyLocal(nextDoc) {
  doc = nextDoc;
  render();
  channel.push("sync_state", { state: crdt.to_json(doc) });
}

function addBlock(kind) {
  const id = `block-${crypto.randomUUID()}`;
  const block = {
    id,
    kind,
    text: kind === "todo" ? "New todo" : "New note",
    done: false,
    position: `${Date.now()}-${id}`,
  };
  applyLocal(crdt.add_block(doc, JSON.stringify(block)));
}

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

document.getElementById("add-todo").addEventListener("click", () => addBlock("todo"));
document.getElementById("add-note").addEventListener("click", () => addBlock("note"));

const socket = new Socket("/socket", {});
socket.connect();
channel = socket.channel("document:demo:welcome", {});
channel.join()
  .receive("ok", (reply) => {
    statusEl.textContent = "Connected";
    if (reply.state) {
      doc = crdt.merge_json_or_keep(doc, reply.state);
    }
    render();
  })
  .receive("error", () => {
    statusEl.textContent = "Join failed";
  });

channel.on("doc_state", (payload) => {
  doc = crdt.merge_json_or_keep(doc, payload.state);
  render();
});

channel.on("state_error", (payload) => {
  statusEl.textContent = `State error: ${payload.code}`;
});
```

- [ ] **Step 2: Create styles**

Create `examples/collab_docs/priv/static/style.css`:

```css
:root {
  color-scheme: light dark;
  font-family: Inter, system-ui, sans-serif;
}

body {
  margin: 0;
  background: #101827;
  color: #f8fafc;
}

#app {
  max-width: 900px;
  margin: 0 auto;
  padding: 2rem;
}

header {
  margin-bottom: 1.5rem;
}

#toolbar {
  display: flex;
  gap: 0.75rem;
  align-items: center;
  margin-bottom: 1rem;
}

button {
  border: 0;
  border-radius: 0.5rem;
  padding: 0.6rem 0.9rem;
  background: #38bdf8;
  color: #082f49;
  font-weight: 700;
  cursor: pointer;
}

#status {
  color: #a7f3d0;
}

.block {
  background: #1e293b;
  border: 1px solid #334155;
  border-radius: 0.75rem;
  padding: 1rem;
  margin-bottom: 0.75rem;
}

.block label {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 0.75rem;
}

textarea {
  min-height: 4rem;
  border-radius: 0.5rem;
  border: 1px solid #475569;
  background: #0f172a;
  color: #f8fafc;
  padding: 0.75rem;
}

.delete {
  margin-top: 0.75rem;
  background: #fb7185;
  color: #4c0519;
}

.conflict {
  border-color: #facc15;
}

.conflict-option {
  border-top: 1px solid #475569;
  padding-top: 0.75rem;
  margin-top: 0.75rem;
}
```

- [ ] **Step 3: Build and smoke-test**

Run:

```bash
pnpm -C examples/collab_docs build:client
cd examples/collab_docs && gleam build
```

Expected: both commands pass.

- [ ] **Step 4: Commit UI**

```bash
git add examples/collab_docs/priv/static
git commit -m "feat(examples): add collab docs browser UI"
```

---

### Task 6: Add Playwright Acceptance Tests

**Files:**
- Create: `examples/collab_docs/e2e/collab_docs.spec.js`

- [ ] **Step 1: Write e2e tests**

Create `examples/collab_docs/e2e/collab_docs.spec.js`:

```js
import { expect, test } from "@playwright/test";

test("two clients converge after independent block additions", async ({ browser }) => {
  const a = await browser.newPage();
  const b = await browser.newPage();

  await a.goto("/");
  await b.goto("/");

  await expect(a.locator("#status")).toHaveText("Connected");
  await expect(b.locator("#status")).toHaveText("Connected");

  await a.locator("#add-todo").click();
  await b.locator("#add-note").click();

  await expect(a.locator(".block")).toHaveCount(2);
  await expect(b.locator(".block")).toHaveCount(2);
});

test("late joiner receives cached state", async ({ browser }) => {
  const first = await browser.newPage();
  await first.goto("/");
  await expect(first.locator("#status")).toHaveText("Connected");
  await first.locator("#add-todo").click();
  await expect(first.locator(".block")).toHaveCount(1);

  const late = await browser.newPage();
  await late.goto("/");
  await expect(late.locator("#status")).toHaveText("Connected");
  await expect(late.locator(".block")).toHaveCount(1);
});

test("same-block concurrent edits render conflict", async ({ browser }) => {
  const a = await browser.newPage();
  const b = await browser.newPage();

  await a.goto("/");
  await b.goto("/");
  await expect(a.locator("#status")).toHaveText("Connected");
  await expect(b.locator("#status")).toHaveText("Connected");

  await a.locator("#add-todo").click();
  await expect(b.locator(".block")).toHaveCount(1);

  await a.locator("textarea").fill("Alice edit");
  await b.locator("textarea").fill("Bob edit");
  await Promise.all([
    a.locator("textarea").blur(),
    b.locator("textarea").blur(),
  ]);

  await expect(a.locator(".conflict")).toHaveCount(1);
  await expect(b.locator(".conflict")).toHaveCount(1);
});

test("document topics are isolated", async ({ browser }) => {
  const one = await browser.newPage();
  const two = await browser.newPage();

  await one.goto("/");
  await two.goto("/?doc=two");

  await expect(one.locator("#status")).toHaveText("Connected");
  await expect(two.locator("#status")).toHaveText("Connected");

  await one.locator("#add-todo").click();
  await expect(one.locator(".block")).toHaveCount(1);
  await expect(two.locator(".block")).toHaveCount(0);
});
```

- [ ] **Step 2: Update app.js topic from URL**

Modify `examples/collab_docs/priv/static/app.js` channel setup:

```js
const params = new URLSearchParams(window.location.search);
const docId = params.get("doc") || "welcome";
channel = socket.channel(`document:demo:${docId}`, {});
```

- [ ] **Step 3: Run e2e tests**

Run:

```bash
pnpm -C examples/collab_docs test
```

Expected: PASS with the tests as written.

- [ ] **Step 4: Run all example tests**

Run:

```bash
just examples-test
```

Expected: cursors, chatrooms, and collab_docs tests pass.

- [ ] **Step 5: Commit e2e tests**

```bash
git add examples/collab_docs/e2e examples/collab_docs/priv/static/app.js
git commit -m "test(examples): cover collab docs convergence"
```

---

### Task 7: Documentation and Changelog

**Files:**
- Create: `examples/collab_docs/README.md`
- Modify: `README.md`
- Modify: `website/src/content/docs/examples.mdx`
- Modify: `website/src/content/docs/index.mdx`
- Create: changie fragment under configured changie directory

- [ ] **Step 1: Create example README**

Create `examples/collab_docs/README.md`:

```markdown
# Collaborative CRDT Docs

A runnable beryl example showing client-side CRDT document blocks synced over realtime channels.

## What it demonstrates

- `document:*:*` segment wildcard topics
- Client-side lattice CRDT package merge with `ORMap(MVRegister(String))`
- Beryl as unordered realtime transport
- Server cache for late joiners
- Explicit conflict UI for concurrent block edits

## Run

```bash
cd examples/collab_docs
gleam run
```

Open http://localhost:8002 in two browser windows.

## Test

```bash
pnpm -C examples/collab_docs test
```
```

- [ ] **Step 2: Update root README example table**

In `README.md`, change "Two runnable demos" to "Three runnable demos" and add:

```markdown
| [`examples/collab_docs`](examples/collab_docs/) | Client-side CRDT document blocks, segment wildcards, conflict resolution |
```

- [ ] **Step 3: Update website examples page**

In `website/src/content/docs/examples.mdx`, add a `## Collaborative CRDT Docs` section after Chat Rooms:

```mdx
## Collaborative CRDT Docs

Source: [`examples/collab_docs`](https://github.com/tylerbutler/beryl/tree/main/examples/collab_docs)

This example shows browser clients running lattice CRDT packages locally while beryl channels relay serialized CRDT state. It uses `document:*:*` topics to isolate tenants and documents, and it renders conflicts when clients concurrently edit the same block.

| Feature | Demonstrated by |
|---|---|
| Segment wildcard topics | `document:*:*` |
| CRDT state sync | `ORMap(MVRegister(String))` |
| Conflict handling | Multiple MV-register values render as a conflict card |
| Late join cache | Server merges received states for join replies |
```

- [ ] **Step 4: Update docs index card**

In `website/src/content/docs/index.mdx`, update the examples description to mention three demos and CRDT documents.

- [ ] **Step 5: Add changie fragment**

Run:

```bash
just change
```

Choose kind `Added` and body:

```text
Added a collaborative CRDT documents example using lattice CRDT packages and Beryl channels.
```

- [ ] **Step 6: Run docs/example validation**

Run:

```bash
just format
just examples-test
```

Expected: PASS.

- [ ] **Step 7: Commit docs**

```bash
git add README.md website/src/content/docs/examples.mdx website/src/content/docs/index.mdx examples/collab_docs/README.md .changes
git commit -m "docs(examples): document collab docs demo"
```

---

### Task 8: Final Validation

**Files:**
- No new files; validation only.

- [ ] **Step 1: Run focused checks**

Run:

```bash
cd examples/collab_docs/client && gleam test
cd ../ && gleam test
pnpm -C examples/collab_docs build:client
pnpm -C examples/collab_docs test
```

Expected: all pass.

- [ ] **Step 2: Run repo CI path**

Run:

```bash
just ci
```

Expected: format, check, test, build-strict, and all example tests pass.

- [ ] **Step 3: Inspect git status**

Run:

```bash
git --no-pager status --short
```

Expected: no untracked Playwright artifacts; only intended source/docs/manifest/lock/changie files are committed.

- [ ] **Step 4: Commit validation corrections**

When validation finds a formatting or test correction, make the smallest correction and commit it:

```bash
git add examples/collab_docs docs README.md website/src/content/docs
git commit -m "fix(examples): stabilize collab docs validation"
```

When validation finds no correction, leave git history unchanged.

---

## Self-Review Notes

- Spec coverage: plan includes scaffolding, client CRDT module, server cache, Beryl channel, browser UI, Playwright tests, docs, changie, and validation.
- Placeholder scan: no `TBD`, `TODO`, or unspecified implementation steps remain.
- Type consistency: server `doc_store` stores JSON-compatible ORMap state; browser client exposes `Document` and `RenderBlock`; channel relays `sync_state`/`doc_state` with `state` string payloads.
