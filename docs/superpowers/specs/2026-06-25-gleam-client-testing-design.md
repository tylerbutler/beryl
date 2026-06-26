# Gleam Client Contract Testing Design

## Problem

Beryl has strong unit and coordinator-level tests, but many of them drive the server through mock socket functions or direct coordinator messages. Those tests are fast and precise, but they do not prove that a real Gleam client can connect over WebSocket and observe the Phoenix/Beryl protocol contract through the public transport path.

Aquamarine and Gluegun already provide the missing client side. Aquamarine gives a Beryl-compatible channel runtime using the Phoenix codec. Gluegun gives raw WebSocket access for cases that a typed channel client should hide.

## Goals

- Add Beryl-owned integration tests that exercise a real Beryl server over WebSocket from Gleam.
- Use Aquamarine as the normal client API for join, push, receive, close, and heartbeat scenarios.
- Use Gluegun only for raw malformed-frame cases that Aquamarine should not expose.
- Keep tests isolated with dynamic localhost ports, bounded receives, explicit cleanup, and mailbox discipline.
- Assert server behavior at the contract level, not Aquamarine implementation details.

## Non-goals

- Rebuild a Phoenix channel client inside Beryl tests.
- Replace coordinator unit tests or pure wire codec tests.
- Move Beryl server-contract responsibility into Aquamarine.
- Add browser, Playwright, or JavaScript-target coverage for this suite.
- Turn the suite into a broad load test.

## Architecture

Add a Beryl integration test module, likely `test/client_contract_test.gleam`, plus small test support helpers if needed. Each test starts a real Beryl coordinator and a Mist WebSocket handler in the same BEAM VM, then connects with Aquamarine over `ws://127.0.0.1:<port>/socket/websocket`.

The harness owns the server lifecycle:

```gleam
let assert Ok(server) = start_test_server(register_channels)
let assert Ok(channel) =
  aquamarine.connect(
    host: "127.0.0.1",
    port: server.port,
    path: "/socket/websocket",
    topic: "test:lobby",
    payload: json.object([]),
    codec: phoenix.codec(),
  )
```

`start_test_server` should:

1. Start Beryl with `beryl.config(wire.phoenix_codec())`.
2. Register purpose-built test channels.
3. Start Mist with `beryl/transport/mist.default_config("/socket/websocket")`.
4. Bind to a dynamic localhost port.
5. Return the Beryl channels, selected port, and a cleanup handle.

Prefer an OS-assigned port if Mist exposes the bound port. If Mist does not expose it, add a small test-only helper that asks the OS for an available localhost port before starting Mist. The helper should fail loudly on bind races rather than silently retrying in ways that hide flaky test behavior.

## Test Scenarios

The initial suite should stay compact and contract-focused.

| Scenario | Client path | Server behavior asserted |
|---|---|---|
| Join success | Aquamarine connect | Client receives an accepted join and decoded join reply payload. |
| Join rejection | Aquamarine connect | Client receives the expected join rejection error. |
| Push reply | Aquamarine push/receive | Client push reaches `handle_in`, and the server reply preserves topic, event, ref, status, and response payload. |
| Server push/broadcast | Aquamarine receive | A joined client receives server-initiated broadcast payloads over the real WebSocket. |
| Heartbeat | Aquamarine heartbeat support, if exposed cleanly | Server replies to heartbeat frames and preserves heartbeat contract. |
| Leave/close cleanup | Aquamarine close | Closing the client removes its server subscription and avoids later broadcast delivery. |
| Malformed or unsupported frame | Gluegun raw WebSocket | Beryl surfaces the intended error behavior without crashing the socket coordinator. |

Aquamarine should cover normal protocol behavior. Gluegun should appear only in tests that intentionally bypass the typed client and send invalid frames.

## Data Flow

Normal tests follow this path:

```text
test process
  -> start Beryl coordinator
  -> start Mist WebSocket handler
  -> Aquamarine connects via Gluegun
  -> Beryl Mist transport decodes the frame
  -> coordinator routes to test channel
  -> response/push returns through the same WebSocket
  -> Aquamarine decodes incoming frames for assertions
```

This path exercises the public Beryl API, Mist transport, wire codec, coordinator routing, channel callbacks, outbound encoding, and WebSocket send path together.

## Test Channel Fixtures

Use small channels with one purpose each:

- `test:lobby` accepts joins and returns a known welcome payload.
- `test:echo` accepts joins and replies to a `say` event with the received body.
- `test:rejected` rejects joins with a stable error reason.
- `test:broadcast` accepts joins and lets the test process trigger `beryl.broadcast`.
- `test:cleanup` accepts joins and exposes enough state to assert close/subscription cleanup.

The channels should avoid sleeps where possible. When the server must have time to process subscription state, prefer an observable acknowledgment or bounded receive. Use short timeouts and exact message selectors to avoid stale mailbox interference.

## Error Handling and Cleanup

Every test must close its Aquamarine channel and stop its Mist server. If a test opens a raw Gluegun socket, it must send a close frame or close the connection explicitly.

Failures should be visible. The harness should not swallow server start errors, connection failures, decode failures, or bind failures. Invalid input tests should assert the specific contract Beryl promises, such as an error reply, closed socket, or ignored malformed frame, depending on the existing transport behavior.

## Dependencies

Add Aquamarine as a dev dependency in Beryl. Aquamarine brings Gluegun transitively for normal channel use. If raw malformed-frame tests need direct Gluegun imports, add Gluegun as an explicit dev dependency too.

Pin git dependencies to stable commits until these packages are published or versioned for Hex use. Update `gleam.toml` and `manifest.toml` through Gleam tooling so dependency metadata stays consistent.

If the suite needs normal client behavior that Aquamarine does not expose yet, file an issue in `tylerbutler/aquamarine` and keep the Beryl test focused on the currently available contract. Do not add one-off Aquamarine workarounds to Beryl unless the scenario requires raw protocol access.

## Open Design Decisions

The implementation plan should resolve these details before coding:

- Whether Mist exposes the bound port when started with port `0`.
- Whether Aquamarine exposes heartbeat send/receive helpers directly enough for heartbeat contract tests.
- Whether Beryl currently exposes a clean server shutdown handle through Mist in tests.
- Which malformed-frame behavior Beryl currently promises and should preserve.
- Which Aquamarine gaps should become upstream issues before or during Beryl implementation.

These decisions affect helper shape, not the overall design.

## Success Criteria

- `gleam test` runs the new client contract suite without requiring external services.
- Tests use dynamic local ports and can run repeatedly without fixed-port collisions.
- Normal scenarios use Aquamarine rather than raw frame strings.
- Raw Gluegun use is limited to negative protocol cases.
- The suite catches regressions in Beryl's real WebSocket protocol contract that coordinator-only tests would miss.
