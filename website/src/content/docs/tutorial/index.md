---
title: Build a Live Poll
description: Build a live poll with raw dispatch, channel handlers, typed messages, and supervised processes.
---

This tutorial teaches Beryl by building one app: a live poll. If you want a
shorter path, start with the [Quick Start](/quick-start/). All prose and code
excerpts come from the runnable
[`examples/live_poll/`](https://github.com/tylerbutler/beryl/tree/main/examples/live_poll)
project. Beryl is pre-1.0. Expect the API to change.

## Chapters

1. [The Elm architecture, without a DOM](/tutorial/the-elm-architecture-without-a-dom/)
2. [One update function, many socket events](/tutorial/one-update-function-many-socket-events/)
3. [Typed messages from the rest of your Gleam system](/tutorial/typed-messages-from-your-gleam-system/)
4. [Composition: raw dispatch and `beryl/channel`](/tutorial/composition-raw-dispatch-and-channels/)
5. [Where the analogy ends](/tutorial/where-the-analogy-ends/)
6. [Supervising Beryl](/tutorial/supervising-beryl/)

You can read each chapter on its own. The checkpoints build on each other. They
start with a read-only poll and end with a supervised channel system.

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

Stop a checkpoint with Ctrl-C before you start the next one. The browser client
loads Phoenix JavaScript 1.7.20 from unpkg, so the first page load needs
internet access. The Gleam server and the Beryl runtime run on your machine.

## Files used by every chapter

The five `step_0N.gleam` files are short entry modules. Each one picks a
configuration and starts the shared modules:

- `raw.gleam` has the raw `init`, `Model`, `Message`, and `update` function
  used by steps 1 through 3.
- `channels.gleam` has the two `channel.Handler` values used by steps 4 and 5.
- `poll.gleam` defines the poll types and turns client `Dynamic` payloads into
  poll commands.
- `store.gleam` keeps poll state in a Gleam OTP actor.
- `timer.gleam` runs delayed callbacks from its own actor.
- `server.gleam` starts the Beryl child specification and the Mist transport,
  serves the browser client, and can serve `/healthz`.
- `test/live_poll_test.gleam` tests the poll types and the protocol decoder.

Read each step module together with the shared files. A step file shows which
behavior is on. It does not repeat the runtime, poll, or browser code.

## Terms used in this tutorial

The tutorial uses these terms, and keeps them separate:

- A **socket** is one client connection that the Beryl runtime knows about.
- A **topic** is a string that a socket subscribes to, such as `poll:demo`.
- **Raw dispatch** is the core API. Your app defines a **Model** and an update
  function. The update function receives a `socket.Input`, and returns a
  `socket.Next` with a list of `socket.Effect` values. A `socket.Sender` lets
  other code send typed messages to one socket.
- A **channel** is one accepted topic on one socket, managed by
  `beryl/channel`. A **handler** matches a topic pattern and builds that
  channel: its private **state**, its callbacks, and its typed info messages.
- A channel callback returns a list of **actions**. Each action applies to the
  callback's own topic.
- The **runtime** has one router actor and one actor for each connected socket.
  The socket actor holds the model and runs effects. The router keeps the
  socket index and sends broadcasts to subscribers.
- A Gleam OTP `process.Subject` is a typed address for a process mailbox. A
  Beryl `socket.Sender` is narrower. It delivers typed `Info` only to the
  socket that owns it. After the socket disconnects, the runtime drops the
  message.

Do not use `Subject`, `Sender`, `socket`, `topic`, `channel`, or `handler` in
place of one another. Each term names a different part of the system.

Raw dispatch is Beryl's core, and the clearest way to learn it. For apps with
many channels, or apps shaped like Phoenix, use `beryl/channel`.

## Related Gleam concepts

- [Lustre](https://lustre.hexdocs.pm/index.html)
- [Lustre for Elm developers](https://lustre.hexdocs.pm/cheatsheets/elm.html)
- [Gleam OTP actors](https://gleam-otp.hexdocs.pm/gleam/otp/actor.html)
- [Gleam Erlang processes and subjects](https://gleam-erlang.hexdocs.pm/gleam/erlang/process.html)
