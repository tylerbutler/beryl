# Beryl introduction series

Status: draft

Audience: Gleam developers who know basic OTP and have not used Beryl.

Beryl version: `0.2.0` (pre-1.0)

Source baseline: `ea5dc5391fa17c4d8107ce0cc482c3f1d295b40f`, plus the
uncommitted example and drafts in this change

These publication-neutral drafts introduce Beryl through one live-poll
application. The prose and excerpts use the runnable example under
[`examples/blog_series/`](../../examples/blog_series/) as the source of truth.
Replace the source baseline with the final commit before publication. Beryl is
pre-1.0, so treat the API as evolving rather than stable.

## Sequence

1. [The Elm architecture, without a DOM](01-the-elm-architecture-without-a-dom.md)
2. [One update function, many socket events](02-one-update-function-many-socket-events.md)
3. [Typed messages from the rest of your Gleam system](03-typed-messages-from-your-gleam-system.md)
4. [Composition: raw dispatch and `beryl/channel`](04-composition-raw-dispatch-and-channels.md)
5. [Where the analogy ends](05-where-the-analogy-ends.md)

Each post stands on its own, but the checkpoints build from read-only raw
dispatch to a production-shaped channel system.

## Runnable checkpoints

Run each command from the repository root:

| Post | Command | URL |
|---|---|---|
| 1 | `cd examples/blog_series && gleam run -m blog_series/step_01` | <http://localhost:8101> |
| 2 | `cd examples/blog_series && gleam run -m blog_series/step_02` | <http://localhost:8102> |
| 3 | `cd examples/blog_series && gleam run -m blog_series/step_03` | <http://localhost:8103> |
| 4 | `cd examples/blog_series && gleam run -m blog_series/step_04` | <http://localhost:8104> |
| 5 | `cd examples/blog_series && gleam run -m blog_series/step_05` | <http://localhost:8105> |

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
- `test/blog_series_test.gleam` checks the poll domain and protocol decoder.

Read the shared files with the step module. A step file shows which behavior is
enabled; it does not duplicate the runtime, domain, or browser code.

## Terminology

The series keeps Beryl's terms distinct:

- A **socket** is one client connection known to the Beryl runtime.
- A **topic** is a string subscription within a socket, such as `poll:demo`.
- Raw dispatch uses an app-defined **Model**, `socket.Input`, `socket.Next`,
  `socket.Effect`, and a socket-scoped `socket.Sender`.
- A **channel** is one accepted topic instance managed by
  `beryl/channel`. A **handler** matches a topic pattern and constructs that
  channel's private **state**, callbacks, and typed info path.
- A channel callback returns ordered **actions** scoped to its own topic.
- The **runtime** is Beryl's shared OTP actor. It stores the logical
  per-socket models and interprets effects.
- A Gleam OTP `process.Subject` is a typed address for a process mailbox. A
  Beryl `socket.Sender` is narrower: it can only deliver typed `Info` to its
  owning socket update, and delivery after disconnect is ignored.
Do not substitute `Subject`, `Sender`, `socket`, `topic`, `channel`, or
`handler` for one another. They name different boundaries.

Raw dispatch is the clearest teaching lens and Beryl's core. For
multi-channel and Phoenix-shaped applications, `beryl/channel` is the
recommended default.

## Official comparison material

- [Lustre](https://lustre.hexdocs.pm/index.html)
- [Lustre for Elm developers](https://lustre.hexdocs.pm/cheatsheets/elm.html)
- [Gleam OTP actors](https://gleam-otp.hexdocs.pm/gleam/otp/actor.html)
- [Gleam Erlang processes and subjects](https://gleam-erlang.hexdocs.pm/gleam/erlang/process.html)
