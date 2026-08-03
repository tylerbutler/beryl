# Handoff: promote the example router into beryl + collapse the transport SPI hops

**Target: PR #220** (branch `docs/propose-app-side-dispatch`). Both changes land
in this PR — do not open separate PRs. Work directly on this branch and commit
with the repo's conventional-commit style.

## Context

A `/simplify` review of PR #220 landed cleanups in commit `393cc13`. Two larger
findings were deferred to this handoff:

1. **Router promotion** — the topic-namespace router in
   `examples/example_helpers/src/example_helpers/router.gleam` is exactly the
   "union-and-router boilerplate" ADR 0002 accepted as a cost, now proven
   generic across four example apps, but it lives in unpublished example code.
   Promote it into the `beryl` package as public API.
2. **Transport SPI hop collapse** — five pairs of pure forwarding wrappers
   (`transport.socket_connected` → `beryl.transport_socket_connected` →
   `AppHandle.socket_connected`, etc.) mean every SPI addition edits three
   places. Collapse to one internal accessor.

**Out of scope:** issue #251 (presence blocking calls in the runtime actor,
double message-rate-limit semantics). Those need a design discussion first —
do not touch them here.

Do the SPI collapse (Task 1) first: it is mechanical and shrinks the surface
Task 2 documents.

---

## Task 1 — Collapse the transport SPI forwarding hops

### Current state

- `packages/beryl/src/beryl.gleam:513` — private `type AppHandle` with fields
  `socket_connected`, `register_closer`, `socket_disconnected`,
  `route_decoded`, `route_binary`, `broadcast`, `stop`, `runtime_owner`.
- `packages/beryl/src/beryl.gleam` ~1110–1160 — five `@internal pub fn
  transport_*` forwarders (`transport_socket_connected`,
  `transport_register_closer`, `transport_socket_disconnected`,
  `transport_route_decoded`, `transport_route_binary`), each one line of
  delegation to `channels.app.<field>`.
- `packages/beryl/src/beryl/transport.gleam` — the public SPI:
  `socket_connected` (:25), `register_closer` (:38), `socket_disconnected`
  (:47), `route_decoded` (:59), `route_binary` (:71), `active_codec` (:83),
  `runtime_pid` (:110). The first five call the `beryl.transport_*`
  forwarders.

### Target

- Add one accessor in `beryl.gleam`:
  `@internal pub fn app_dispatch(channels: Sockets) -> AppHandle`.
- `transport.gleam` calls fields directly:
  `beryl.app_dispatch(sockets).route_decoded(socket_id, message)` etc.
- Delete the five `transport_*` forwarders.
- Keep `beryl/transport` itself unchanged in signature and docs — it remains
  the documented public contract consumed by `beryl_mist`/`beryl_ewe`.

### Gotchas

- `AppHandle` is currently a **private** type. To return it from a pub fn it
  must become `pub type`. It must **not** be `opaque` — field access from
  `transport.gleam` (a different module) requires visible constructors. Mark
  the type `@internal` so it stays out of generated docs, and add the
  house-style `// nolint: unused_exports` comment if glinter complains.
- Check whether `active_codec`/`runtime_pid` in `transport.gleam` go through
  other `beryl` accessors (`runtime_pid` uses `app_runtime_pid` at
  `beryl.gleam:1061`); fold them into `app_dispatch` only if it simplifies —
  don't force it.
- Import direction is safe: `transport.gleam` already imports `beryl`;
  `beryl.gleam` never imports `transport`.

### Verify

- `cd packages/beryl && gleam test` (249 tests), then `beryl_mist` (26) and
  `beryl_ewe` (18).
- `trellis run build --strict` and `trellis run lint` (see "Workspace notes"
  for pre-existing lint failures you should ignore).
- Changelog fragment: probably covered by amending the existing
  `.changes/unreleased/beryl-transport-spi-trim.toml` narrative or a small
  `Changed` fragment — internal-only, so use judgment.

---

## Task 2 — Promote the router into beryl

### Phase A: API design — **confirm open decisions with Tyler before writing code**

Proposed new public module `packages/beryl/src/beryl/socket/router.gleam`
(module `beryl/socket/router`), porting from
`examples/example_helpers/src/example_helpers/router.gleam` (as of `393cc13`
it holds: `Namespace`, `accept_only`, `stateful`, `unknown_topic`, `route`,
`Standalone(sub)`, `standalone_init`, `standalone_namespace`).

Key upgrade over the example version: key `Namespace` on the library's
`beryl/topic` pattern language instead of an ad-hoc `matches` closure, and
expose captured wildcard segments to handlers. This also closes the
two-vocabulary gap where routing used `string.starts_with` while
`beryl.with_topic_rate` used patterns like `"room:*"` for the same
namespaces, and it deletes the hand-rolled `string.split(topic, ":")`
extraction in chatrooms (`app.gleam` join) and collab_docs (`app.gleam`
join's `["document", tenant, document]` match).

Sketch (adjust to `beryl/topic`'s real API — `topic.parse_pattern` exists,
used at `beryl.gleam` ~1082; verify the wildcard-extraction function name
before relying on it):

```gleam
pub type Match {
  /// The concrete topic plus the segments captured by the pattern's
  /// wildcards, in order.
  Match(topic: String, params: List(String))
}

pub type Namespace(model) {
  Namespace(
    pattern: TopicPattern,
    join: fn(model, Match, Dynamic, Ref) -> #(model, List(Effect)),
    message: fn(model, Match, String, Dynamic, Option(Ref)) ->
      #(model, List(Effect)),
    closed: fn(model, Match) -> #(model, List(Effect)),
  )
}
```

`route` keeps first-match-wins and the fail-closed conventions (unknown-topic
joins rejected with `unknown_topic()`-style payload; other unclaimed inputs
ignored; `Binary`/`Info` pass through as `Next(model, [])`).

Open decisions to confirm:

1. **Module name**: `beryl/socket/router` vs `beryl/router`.
2. **Does `Standalone(sub)` ship in the library?** It's the single-namespace
   quick-start shape; real apps define their own socket-wide model. Lean yes,
   but confirm.
3. **Escape hatch**: keep a `matches: fn(String) -> Bool` constructor variant
   for routing that patterns can't express, or patterns only?
4. **Ref-gated reply helper**: promote `examples/example_helpers/src/
   example_helpers/reply.gleam`'s `ok(Option(Ref), Json) -> List(Effect)`
   into `beryl/socket` (naming: `reply_ok`? `reply_if`?). It's universal under
   the new API (`Message` carries `Option(Ref)` but `ReplyOk` demands `Ref`).
5. Whether `stateful` keeps the `socket_id` projection parameter or drops it
   now that `Match` carries more context.

### Phase B: implement and migrate

1. Write the module with `///` docs on every public item, plus unit tests in
   `packages/beryl/test/` (port the routing assertions from
   `examples/chatrooms/test/chatrooms_app_test.gleam`: fail-closed unknown
   joins, ignored unclaimed messages, lobby `accept_only`, dict projection
   round-trip, first-match ordering; add wildcard-capture tests).
2. Migrate consumers (all currently import `example_helpers/router`):
   - `examples/cursors/src/cursors/app.gleam` (+ `cursors.gleam` uses
     `topic_router.standalone_init`)
   - `examples/chatrooms/src/chatrooms/app.gleam` (+ `chatrooms.gleam`;
     test file imports `example_helpers/router` for `Standalone`)
   - `examples/collab_docs/src/collab_docs/app.gleam` (+ `collab_docs.gleam`)
   - `examples/showcase/src/showcase.gleam` (aliased as `topic_router`)
   All four build their namespace lists once in factories
   (`standalone_update(...)` / showcase's `update(ctx)`) — keep that shape.
3. Delete `examples/example_helpers/src/example_helpers/router.gleam` (the
   other helpers — `color`, `payload`, `presence`, `reply` — stay unless
   decision 4 moves `reply`).
4. Wire behavior must not change: example gleam tests + the collab_docs/
   chatrooms/cursors suites are the check (see e2e caveat below).

### Phase C: docs and release metadata

- `just docs` after any doc-comment change (CI's docs job fails if
  `website/src/content/docs/reference/api/` is stale; the generator adds a
  page for the new module — check `website/astro.config.mjs` /
  `reference/index.md` for whether sidebar entries need manual addition).
- Rewrite `website/src/content/docs/guides/dispatch.md` sections that show
  hand-rolled routing to use the new module; check `examples.mdx` mentions.
- Changelog fragment via `just change beryl Added "<body>"` (TOML fragments in
  `.changes/unreleased/`, fields `project`/`kind`/`body`; kinds seen:
  `Added`, `Changed`, `Removed`).
- Note in `docs/adr/0002-app-side-dispatch.md` that the router boilerplate
  cost is now absorbed by the library (amend the "consequences"/costs
  section), or add a short ADR if the design discussion prefers.
- Delete this plan file in the final cleanup commit (repo convention:
  planning docs are removed once superseded).

---

## Workspace notes for the next session

- Commands: `just build` / `just test` / `just check` / `just lint` /
  `trellis run format` / `just docs`. Run gleam commands from inside a
  package dir, or trellis from the root.
- **Pre-existing, not yours to fix**: `trellis run lint` fails in
  `beryl_mist` (src lines ~144/148) and `beryl_ewe` with
  `discarded_result` on `let _ = <server>.send_*_frame(...)` — these
  reproduce on a clean checkout and CI does not run lint.
- glinter enforces `deep_nesting` (max ~5 levels) on `beryl` — extract
  helpers rather than nesting case expressions.
- Local e2e caveat: port 8000 is held by a paperless-ngx container on this
  machine, which breaks the cursors example's Playwright tests locally; rely
  on CI for e2e.
- Formatting: always finish with `trellis run format`; CI checks it.
