---
title: Build a Live Poll
description: Learn Beryl by building a live poll from raw dispatch through channels, runtime boundaries, and supervision.
---

This tutorial introduces Beryl through one live-poll application. If you want
the short version first, start with the [Quick Start](/quick-start/). The prose
and excerpts use the runnable
[`examples/live_poll/`](https://github.com/tylerbutler/beryl/tree/main/examples/live_poll)
project as the source of truth. Beryl is pre-1.0, so treat the API as evolving
rather than stable.

## Sequence

1. [The Elm architecture, without a DOM](/tutorial/the-elm-architecture-without-a-dom/)
2. [One update function, many socket events](/tutorial/one-update-function-many-socket-events/)
3. [Typed messages from the rest of your Gleam system](/tutorial/typed-messages-from-your-gleam-system/)
4. [Composition: raw dispatch and `beryl/channel`](/tutorial/composition-raw-dispatch-and-channels/)
5. [Where the analogy ends](/tutorial/where-the-analogy-ends/)
6. [Supervising Beryl](/tutorial/supervising-beryl/)

Each chapter stands on its own, but the checkpoints build from read-only raw
dispatch to a production-shaped channel system.

## Runnable checkpoints

Run each command from the repository root:

| Chapter | Command | URL |
|---|---|---|
| 1 | `cd examples/live_poll && gleam run -m live_poll/step_01` | `http://localhost:8101` |
| 2 | `cd examples/live_poll && gleam run -m live_poll/step_02` | `http://localhost:8102` |
| 3 | `cd examples/live_poll && gleam run -m live_poll/step_03` | `http://localhost:8103` |
| 4 | `cd examples/live_poll && gleam run -m live_poll/step_04` | `http://localhost:8104` |
| 5 | `cd examples/live_poll && gleam run -m live_poll/step_05` | `http://localhost:8105` |
| 6 | `cd examples/live_poll && gleam run -m live_poll/step_05` | `http://localhost:8105` |

Stop a checkpoint with Ctrl-C before starting the next one. The browser client
loads Phoenix JavaScript 1.7.20 from unpkg, so the first page load needs
internet access. The Gleam server and Beryl runtime stay local.

## Example layout

The five `step_0N.gleam` files are short entry modules, not complete
applications. They select a configuration and assemble shared modules:

- `raw.gleam` contains the raw `init`, `Model`, `Message`, `socket.Input` router,
  and ordered `socket.Effect` lists used by steps 1 through 3.
- `channels.gleam` contains the two heterogeneous `channel.Handler` values
  used by steps 4 and 5.
- `poll.gleam` defines the typed poll domain and decodes client `Dynamic`
  payloads into domain commands.
- `store.gleam` owns poll state in a Gleam OTP actor.
- `timer.gleam` runs delayed callbacks from its own actor.
- `server.gleam` starts the Beryl child specification and Mist transport,
  serves the browser client, and optionally serves `/healthz`.
- `test/live_poll_test.gleam` checks the poll domain and protocol decoder.

Read the shared files with the step module. A step file shows which behavior is
enabled. It does not duplicate the runtime, domain, or browser code.

## Terminology

The tutorial keeps Beryl's terms distinct:

- A **socket** is one client connection known to the Beryl runtime.
- A **topic** is a string subscription within a socket, such as `poll:demo`.
- Raw dispatch uses an app-defined **Model**, `socket.Input`, `socket.Next`,
  `socket.Effect`, and a socket-scoped `socket.Sender`.
- A **channel** is one accepted topic instance managed by
  `beryl/channel`. A **handler** matches a topic pattern and constructs that
  channel's private **state**, callbacks, and typed info path.
- A channel callback returns ordered **actions** scoped to its own topic.
- The **runtime** uses one router actor and one actor for each connected
  socket. The socket actor stores its model and interprets effects. The router
  maintains the socket index and handles broadcast fan-out.
- A Gleam OTP `process.Subject` is a typed address for a process mailbox. A
  Beryl `socket.Sender` is narrower. It delivers typed `Info` only to its
  owning socket update. The runtime ignores delivery after disconnect.
Do not substitute `Subject`, `Sender`, `socket`, `topic`, `channel`, or
`handler` for one another. They name different boundaries.

Raw dispatch is the clearest teaching example and Beryl's core. For
multi-channel and Phoenix-shaped applications, `beryl/channel` is the
recommended default.

## Official comparison material

- [Lustre](https://lustre.hexdocs.pm/index.html)
- [Lustre for Elm developers](https://lustre.hexdocs.pm/cheatsheets/elm.html)
- [Gleam OTP actors](https://gleam-otp.hexdocs.pm/gleam/otp/actor.html)
- [Gleam Erlang processes and subjects](https://gleam-erlang.hexdocs.pm/gleam/erlang/process.html)
