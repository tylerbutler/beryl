# k6 workloads

## Overview

These workloads exercise Phoenix connections against an explicitly supplied
target. The [entry point](../run.js) passes validated configuration to them;
the [client library](../lib/README.md) owns connection and reply lifecycle.
[workloads.js:connectedClient]

## Interface

The [workload module](./workloads.js) exports:

| Export | Operation |
|---|---|
| `protocolSmoke(config)` | Connect, join, verify an echo marker, then shut down. [workloads.js:protocolSmoke] |
| `idleConnections(config)` | Hold a joined connection for the session duration. [workloads.js:idleConnections] |
| `connectionRate(config)` | Open and close a connection without joining. [workloads.js:connectionRate] |
| `pushRoundTrip(config)` | Repeat marker-checked pushes on a joined topic. [workloads.js:pushRoundTrip] |
| `broadcastFanout(config)` | Exchange broadcasts and acknowledgements within a generated participant group. [workloads.js:broadcastFanout] |
| `presenceChurn(config)` | Track/untrack and require flat presence snapshots showing the session key's arrival/removal. [workloads.js:presenceChurn] |
| `mixedWsHttp(config)` | Pair marker-checked pushes with HTTP GETs. [workloads.js:mixedWsHttp] |
| `guardrailValidation(config)` | Require a join rejection with reason `forbidden`. [workloads.js:guardrailValidation] |

`connectedClient`, `delay`, and `messagePromise` are also exported helpers.
`messagePromise` waits for a matching client message with a deadline.
[workloads.js:connectedClient] [workloads.js:delay]
[workloads.js:messagePromise]

## Invariants

- Success checks account for shutdown failures and unexpected asynchronous
  client errors. Push, broadcast, presence, and mixed workloads require at
  least one successful operation. [workloads.js:includeShutdown]
  [workloads.js:includeClientErrors] [workloads.js:pushRoundTrip]
  [workloads.js:broadcastFanout] [workloads.js:presenceChurn]
  [workloads.js:mixedWsHttp]
- Guardrail validation allows the expected join-rejected error while still
  requiring the forbidden reason. [workloads.js:guardrailValidation]
  [workloads.js:clientFor]
- Presence churn observes its unique key in a `presence_list` snapshot before
  untracking, then requires a snapshot without that key. Other sessions can
  remain in the roster. [workloads.js:presenceChurn]
- Workloads depend on the target's echo, broadcast/ack, presence, and
  forbidden-join behavior. See the [suite guide](../../README.md) for target
  setup and profile-specific inputs. [workloads.js:protocolSmoke]
  [workloads.js:broadcastFanout] [workloads.js:presenceChurn]
  [workloads.js:guardrailValidation]

## Side effects

Workloads create WebSocket traffic, timers, k6 checks, and metric samples.
They send pushes, joins/leaves, broadcast acknowledgements, and presence
operations as appropriate. `mixedWsHttp` also sends HTTP GETs to
`config.httpTargetUrl`. Execution changes target state and consumes target
and generator resources. [workloads.js:clientFor] [workloads.js:delay]
[workloads.js:broadcastFanout] [workloads.js:presenceChurn]
[workloads.js:mixedWsHttp]

## Verification

From the repository root, run `just load-syntax` and `just load-helpers`
for local parsing/helper checks. These do not validate a live target's
workload behavior. `just load-check` adds Docker/k6 inspection without
target traffic and may pull the pinned image.
[justfile:load-syntax] [justfile:load-helpers] [justfile:load-check]

Use `just load-run <profile> <target> <transport>` only for an intentional
load run after the [suite prerequisites](../../README.md#k6-setup).
It requires Docker host networking or an equivalent native k6 setup and a
reachable compatible server. [justfile:load-run]
