# Protocol proof pilot

This development-only pilot proves selected rules in a Bend model, then compares
that model with `beryl_protocol` on Erlang and JavaScript. It does not prove that
the Gleam implementation is equivalent to the model.

## Run the checks

Use the root Gleam and Node.js toolchain and prepare the protocol dependencies
with `just deps-gleam`. From the repository root:

```sh
just protocol-pilot-deps
just protocol-pilot
```

The local mise configuration pins Bend 2.0.40 and Lean 4.34.0. Bend builds and
caches its BendTT kernel on the first `--verdict` check. These tools are not
required by default builds, tests, or CI. The Gleam development host is
type-checked by normal package builds.

`protocol-pilot` checks `PROOF.bend --verdict`, verifies that two intentionally
broken models fail the proof gate, and exports `model.bend` to JavaScript.
It then runs the same generated traces through both Gleam targets and compares
their observations with the exported model. Build outputs stay in ignored
`build/` directories; temporary mutation fixtures are removed after each check.

## What is checked

`LAWS.bend` states eleven transition laws. `PROOF.bend` supplies their proofs:
foreign handles are no-ops; replies and discards are single-use; empty or
mismatched reply handles cannot consume work; authorization requests admission;
successful admission establishes the channel before its reply; unadmitted
channels cannot push; replacement joins wait for cleanup; cleanup emits the
terminal message before replacement authorization; and completed drain clears
pending replies and disables pushes.

The conformance host retains the exact opaque Gleam handles from returned
actions. It does not reconstruct capabilities from wire references. The model
uses fresh natural-number identifiers and distinguishes local from foreign
handles. Both hosts exercise current, first-issued, and foreign handles,
including reference reuse across requests and channel generations.

Each transition compares the pending count, established-channel status,
push eligibility, and ordered action names. Payloads, wire metadata, concrete
identifier values, and routine `Deadline` actions are outside this projection.
The corpus covers every pair of 28 commands from six lifecycle prefixes, five
focused regression traces, and 64 deterministic longer traces. Failure output
includes the target and command sequence.

## Read a failing trace

Commands `0`, `2`, `3`, and `5` mean join, accept with drain mode, reject join,
and receive a referenced message. The other commands select a stored handle:

| Operation | Latest local | First local | Foreign |
| --- | --- | --- | --- |
| Accept with immediate invalidation | 1 | 12 | 20 |
| Finish successful admission | 4 | 13 | 21 |
| Reply | 6 | 14 | 22 |
| Discard reply | 7 | 15 | 23 |
| Begin close | 8 | 16 | 24 |
| Push | 9 | 17 | 25 |
| Finish drain | 10 | 18 | 26 |
| Finish cleanup | 11 | 19 | 27 |

A command with no stored handle is skipped. First-issued handles become stale
after replacement or reference reuse; they are not assumed stale from the start.

## Limits and maintenance

The model covers one topic, one repeated wire request reference, a fixed valid
clock, successful admission, normal closure, and both close modes. It does not
cover capacity exhaustion, heartbeat expiry, snapshots, codec behavior, failed
admission, transport I/O, or OTP recovery. Keep `just protocol-test` and existing
runtime and transport tests.

The proofs quantify over model values, but the differential tests cover only
the generated corpus and its observation projection. Numeric representation
limits, identifier freshness over complete traces, the Bend source-to-kernel
translation, and compiled-backend correctness are not proved by this pilot.

Review changes to `LAWS.bend` separately from implementation and proof changes.
Do not weaken a law to make an implementation pass. When relevant Gleam behavior
changes, run this optional check and review both the model and its test adapters.
There are no release dependencies, changelog fragments, or automatic CI gates
for this pilot.
