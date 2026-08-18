//// What the process-per-channel prototype (#337) actually does, pinned
//// against the shipped shared-runtime layer.
////
//// The interesting assertions are the ones that *differ* from
//// `channel_crash_test`: those are the parity costs of moving a channel
//// into its own process, and they are the reason this spike exists.

import beryl
import beryl/channel
import beryl/socket
import beryl/transport
import beryl/wire
import channel_dispatch_helper as helper
import gleam/erlang/process
import gleam/json
import gleam/option
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should
import spike_channel_worker as spike

/// A channel's server-side message type.
pub type Note {
  Announce(String)
}

// --- systems ---------------------------------------------------------------

fn start(handlers: List(channel.Handler)) -> beryl.Sockets {
  let assert Ok(#(sockets, spec)) =
    spike.child_spec(beryl.config(wire.phoenix_codec()), handlers: handlers)
    as "the spike config is valid"
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
    as "the spike supervision tree starts"
  sockets
}

// --- test channels ---------------------------------------------------------

/// A counting channel that reports the pid it runs in, replies to
/// `"ping"`, and traces its termination.
fn room(
  pids: process.Subject(process.Pid),
  trace: process.Subject(String),
) -> channel.Handler {
  channel.handler("room:*", fn(context) {
    process.send(pids, process.self())
    let callbacks =
      channel.callbacks()
      |> channel.on_message(fn(count, message) {
        channel.next(count + 1, [
          channel.reply_ok(message.reply, json.int(count + 1)),
          channel.push("pong", json.int(count + 1)),
        ])
      })
      |> channel.on_terminate(fn(_count, reason) {
        process.send(
          trace,
          "terminate:" <> context.topic <> ":" <> helper.reason_name(reason),
        )
        []
      })
    channel.accept(0, callbacks)
    |> channel.with_reply(json.object([#("handler", json.string("room"))]))
  })
}

/// A channel that hands its typed sender out and pushes what it receives.
fn mailbox(senders: process.Subject(channel.Sender(Note))) -> channel.Handler {
  channel.handler("mail:*", fn(context) {
    process.send(senders, context.self)
    let callbacks =
      channel.callbacks()
      |> channel.on_info(fn(state, note) {
        let Announce(text) = note
        channel.next(state, [channel.push("announce", json.string(text))])
      })
    channel.accept(Nil, callbacks)
  })
}

/// A channel whose `join` panics.
fn join_panics() -> channel.Handler {
  channel.handler("crash_join:*", fn(_context) { panic as "join exploded" })
}

/// A channel whose `on_message` panics, and which traces its termination
/// so the test can prove it never runs.
fn message_panics(trace: process.Subject(String)) -> channel.Handler {
  channel.handler("crash_msg:*", fn(context) {
    let callbacks =
      channel.callbacks()
      |> channel.on_message(fn(_state, _message) { panic as "message exploded" })
      |> channel.on_terminate(fn(_state, _reason) {
        process.send(trace, "terminate:" <> context.topic)
        []
      })
    channel.accept(Nil, callbacks)
  })
}

/// A channel whose `on_terminate` panics, taking the worker down before it
/// can answer the router's synchronous `Finish`.
fn terminate_panics() -> channel.Handler {
  channel.handler("crash_term:*", fn(_context) {
    let callbacks =
      channel.callbacks()
      |> channel.on_terminate(fn(_state, _reason) {
        panic as "terminate exploded"
      })
    channel.accept(Nil, callbacks)
  })
}

// --- helpers ---------------------------------------------------------------

fn next_pid(pids: process.Subject(process.Pid)) -> process.Pid {
  let assert Ok(pid) = process.receive(pids, 500) as "a channel opened"
  pid
}

/// Wait for `pid` to exit, up to roughly a second.
fn await_exit(pid: process.Pid, attempts: Int) -> Bool {
  case process.is_alive(pid), attempts {
    False, _ -> True
    True, 0 -> False
    True, _ -> {
      process.sleep(20)
      await_exit(pid, attempts - 1)
    }
  }
}

// --- topology --------------------------------------------------------------

pub fn each_channel_runs_in_its_own_process_test() -> Nil {
  let pids = process.new_subject()
  let trace = process.new_subject()
  let channels = start([room(pids, trace)])
  let frames = helper.connect(channels, "s1")
  let assert Ok(runtime) = transport.runtime_pid(channels)
    as "the runtime is running"

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  helper.recv(frames)
  |> string.contains("\"handler\":\"room\"")
  |> should.be_true
  let channel_a = next_pid(pids)

  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _join_b = helper.recv(frames)
  let channel_b = next_pid(pids)

  // Two joins on one socket: three distinct processes.
  { channel_a == runtime } |> should.be_false
  { channel_b == runtime } |> should.be_false
  { channel_a == channel_b } |> should.be_false

  // ...and the callbacks still work, through the same wire contract.
  helper.push(channels, "s1", "room:a", "ping", "r-3")
  helper.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
  helper.recv(frames) |> string.contains("\"pong\",1") |> should.be_true
}

pub fn a_typed_sender_reaches_its_own_worker_test() -> Nil {
  let senders = process.new_subject()
  let channels = start([mailbox(senders)])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "mail:a", "jr-1", "r-1")
  let _join = helper.recv(frames)
  let assert Ok(sender) = process.receive(senders, 500)
    as "the channel handed out its sender"

  channel.notify(sender, Announce("hello"))

  // Mail goes straight to the worker that sealed it; the batch it
  // produces comes back through the socket.
  let push = helper.recv(frames)
  push |> string.contains("\"announce\"") |> should.be_true
  push |> string.contains("hello") |> should.be_true
}

pub fn a_rejoin_gets_a_fresh_worker_test() -> Nil {
  let pids = process.new_subject()
  let trace = process.new_subject()
  let channels = start([room(pids, trace)])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join = helper.recv(frames)
  let first = next_pid(pids)

  helper.push(channels, "s1", "room:a", "ping", "r-2")
  let _reply = helper.recv(frames)
  helper.recv(frames) |> string.contains("\"pong\",1") |> should.be_true

  helper.leave(channels, "s1", "room:a", "jr-1", "r-3")
  helper.next_trace(trace) |> should.equal("terminate:room:a:normal")
  { await_exit(first, 50) } |> should.be_true
  let _leave_reply = helper.recv(frames)
  let _close = helper.recv(frames)

  helper.join(channels, "s1", "room:a", "jr-2", "r-4")
  let _rejoin = helper.recv(frames)
  let second = next_pid(pids)
  { first == second } |> should.be_false

  // A new worker means new state: the count starts over, and nothing the
  // old worker held leaked into it.
  helper.push(channels, "s1", "room:a", "ping", "r-5")
  let _reply = helper.recv(frames)
  helper.recv(frames) |> string.contains("\"pong\",1") |> should.be_true
}

// --- crash containment -----------------------------------------------------

pub fn a_panic_in_join_rejects_that_join_test() -> Nil {
  let pids = process.new_subject()
  let trace = process.new_subject()
  let channels = start([join_panics(), room(pids, trace)])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "crash_join:a", "jr-1", "r-1")
  let reply = helper.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("{\"reason\":\"join crashed\"}") |> should.be_true

  // The socket is untouched: a worker that never started took nothing
  // with it.
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  helper.recv(frames)
  |> string.contains("\"handler\":\"room\"")
  |> should.be_true
}

pub fn a_panic_handling_a_message_closes_only_that_topic_test() -> Nil {
  let pids = process.new_subject()
  let trace = process.new_subject()
  let channels = start([message_panics(trace), room(pids, trace)])
  let frames = helper.connect(channels, "s1")
  let assert Ok(runtime) = transport.runtime_pid(channels)
    as "the runtime is running"

  helper.join(channels, "s1", "crash_msg:a", "jr-1", "r-1")
  let _join_a = helper.recv(frames)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _join_b = helper.recv(frames)
  let survivor = next_pid(pids)

  helper.push(channels, "s1", "crash_msg:a", "boom", "r-3")

  // The crash is contained by a process boundary, not a rescue: the
  // runtime and the sibling channel are both untouched.
  let close = helper.recv(frames)
  close |> string.contains("crash_msg:a") |> should.be_true
  { process.is_alive(runtime) } |> should.be_true
  { process.is_alive(survivor) } |> should.be_true

  helper.push(channels, "s1", "room:b", "ping", "r-4")
  helper.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
  helper.recv(frames) |> string.contains("\"pong\",1") |> should.be_true
}

/// Both parity costs of the process boundary, pinned on one crash.
///
/// `on_terminate` is unreachable: the shipped layer runs it, because core
/// rescues the callback and keeps the model, so the channel's state is
/// still there to terminate. Here the state died with the process. This
/// matches Phoenix, where a channel process crash skips `terminate/2`, but
/// it is a change from what beryl does today.
///
/// And the close is announced as `phx_close`, not `phx_error`: core picks
/// that from the stop reason, and the only way this layer can close a
/// topic it no longer owns is `KickTopic`, which is `Shutdown`. Preserving
/// the Phoenix contract needs a core effect that carries a reason.
pub fn a_crashed_worker_loses_terminate_and_closes_as_shutdown_test() -> Nil {
  let pids = process.new_subject()
  let trace = process.new_subject()
  let channels = start([message_panics(trace), room(pids, trace)])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "crash_msg:a", "jr-1", "r-1")
  let _join = helper.recv(frames)

  helper.push(channels, "s1", "crash_msg:a", "boom", "r-2")

  let close = helper.recv(frames)
  close |> string.contains("phx_close") |> should.be_true
  close |> string.contains("phx_error") |> should.be_false
  helper.no_trace(trace)
}

// --- teardown --------------------------------------------------------------

pub fn a_disconnect_terminates_every_worker_test() -> Nil {
  let pids = process.new_subject()
  let trace = process.new_subject()
  let channels = start([room(pids, trace)])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_a = helper.recv(frames)
  let channel_a = next_pid(pids)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _join_b = helper.recv(frames)
  let channel_b = next_pid(pids)

  helper.disconnect(channels, "s1")

  // Both channels ran `on_terminate` and then stopped: no worker outlives
  // the socket it belongs to.
  helper.next_trace(trace)
  |> string.starts_with("terminate:room:")
  |> should.be_true
  helper.next_trace(trace)
  |> string.starts_with("terminate:room:")
  |> should.be_true
  { await_exit(channel_a, 50) } |> should.be_true
  { await_exit(channel_b, 50) } |> should.be_true
}

/// A worker that dies instead of answering `Finish` must not hold the
/// shared runtime actor: the `Closed` turn selects on the worker's `DOWN`
/// alongside its reply, so the wait ends with the process rather than with
/// `terminate_timeout_ms`.
///
/// The disconnect is a cast, so a runtime that blocked for the full second
/// would still be inside that turn when the second socket joins, and its
/// join frame would miss `recv`'s 500ms window.
pub fn a_dead_worker_does_not_stall_the_runtime_test() -> Nil {
  let channels = start([terminate_panics()])
  let first = helper.connect(channels, "s1")

  helper.join(channels, "s1", "crash_term:a", "jr-1", "r-1")
  let _join = helper.recv(first)

  helper.disconnect(channels, "s1")

  let second = helper.connect(channels, "s2")
  helper.join(channels, "s2", "crash_term:b", "jr-2", "r-2")
  helper.recv(second) |> string.contains("phx_reply") |> should.be_true
}

/// **Third contract break.** A close overtakes the worker's own in-flight
/// batch, and the batch loses.
///
/// The push is cast to the worker and the leave is handled in the very next
/// turn, so the router drops the topic before the worker's reply gets home
/// — and then discards it. The client's `r-2` is never answered. The
/// shipped shared runtime cannot lose this: it runs `on_message` in the
/// same process that handles the leave, so the reply is already lowered.
///
/// Round 1 read this as a missing drain and expected #334 to supply it. It
/// does not: the reply is unanswerable from the closing turn regardless of
/// topology, because core invalidates the topic's reply refs before it
/// delivers `Closed`. See `a_reply_ref_is_dead_by_the_closed_turn_test`,
/// which loses the same reply with no workers at all.
pub fn a_leave_discards_the_reply_it_raced_test() -> Nil {
  let pids = process.new_subject()
  let trace = process.new_subject()
  let channels = start([room(pids, trace)])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join = helper.recv(frames)

  helper.push(channels, "s1", "room:a", "ping", "r-2")
  helper.leave(channels, "s1", "room:a", "jr-1", "r-3")

  // The leave is answered and the topic closes, but nothing the push
  // produced — neither its reply nor its `pong` — ever reaches the client.
  helper.recv(frames) |> string.contains("\"r-3\"") |> should.be_true
  helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  helper.recv_none(frames)
}

// --- round 2: what the per-socket actor (#334) actually changed ------------

/// A channel whose `join` sleeps for longer than a frame wait.
fn slow_join(delay: Int) -> channel.Handler {
  channel.handler("slow:*", fn(_context) {
    process.sleep(delay)
    channel.accept(Nil, channel.callbacks())
  })
}

/// A channel whose `on_terminate` blocks — the ceiling round 1 could not
/// pay down, because a blocked `Finish` held the one shared runtime actor.
fn terminate_blocks(delay: Int) -> channel.Handler {
  channel.handler("slow_term:*", fn(_context) {
    channel.callbacks()
    |> channel.on_terminate(fn(_state, _reason) {
      process.sleep(delay)
      []
    })
    |> channel.accept(Nil, _)
  })
}

/// Joins no longer serialise across sockets.
///
/// Round 1 started every worker through one globally named factory
/// supervisor, so `supervisor:start_child` — a `gen_server:call` — put every
/// join on every socket behind one process. Each socket now has its own
/// supervisor, started by and linked to its own socket actor, so a join
/// that blocks for 700ms delays only the socket that asked for it.
///
/// The delay is longer than `recv`'s 500ms window on purpose: under round
/// 1's shared factory, `s2`'s join frame could not arrive in time.
pub fn a_slow_join_does_not_block_another_socket_test() -> Nil {
  let pids = process.new_subject()
  let trace = process.new_subject()
  let channels = start([slow_join(700), room(pids, trace)])
  let first = helper.connect(channels, "s1")
  let second = helper.connect(channels, "s2")

  helper.join(channels, "s1", "slow:a", "jr-1", "r-1")
  helper.join(channels, "s2", "room:b", "jr-2", "r-2")

  // `recv`'s window is 500ms, so `s2` cannot have queued behind the 700ms
  // join `s1` is still inside.
  helper.recv(second)
  |> string.contains("\"handler\":\"room\"")
  |> should.be_true

  // `s1`'s own join still takes the full 700ms, which is the point: the
  // wait is confined to the socket that asked for it.
  let assert Ok(frame) = process.receive(first, 2000) as "s1 joined eventually"
  frame |> string.contains("phx_reply") |> should.be_true
}

/// A blocking `on_terminate` stalls one connection, not the server.
///
/// This is the ceiling round 1 named and could not lift: `finish` is a
/// synchronous call, and on the shared runtime the socket it blocked was
/// every socket. The `Finish` wait is unchanged here — only the process it
/// blocks is different.
pub fn a_blocking_terminate_stalls_only_its_own_socket_test() -> Nil {
  let pids = process.new_subject()
  let trace = process.new_subject()
  let channels = start([terminate_blocks(700), room(pids, trace)])
  let first = helper.connect(channels, "s1")

  helper.join(channels, "s1", "slow_term:a", "jr-1", "r-1")
  let _join = helper.recv(first)

  helper.disconnect(channels, "s1")

  let second = helper.connect(channels, "s2")
  helper.join(channels, "s2", "room:b", "jr-2", "r-2")
  helper.recv(second)
  |> string.contains("\"handler\":\"room\"")
  |> should.be_true
}

// --- round 2: why the raced reply is not a topology problem ---------------

/// The app-dispatch model for `a_reply_ref_is_dead_by_the_closed_turn_test`:
/// the pending reply ref for the one topic, if any.
type Stashed =
  option.Option(socket.ReplyRef)

/// A minimal app that answers a client's `ref` one turn too late — from the
/// topic's own `Closed` input, which is exactly where a drained worker
/// batch would land.
fn late_reply_app() -> beryl.Sockets {
  let assert Ok(#(sockets, spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(option.None, []) },
      update: fn(stashed: Stashed, input) {
        case input {
          socket.Join(ref: ref, ..) ->
            socket.Next(stashed, [socket.AcceptJoin(ref, option.None)])
          socket.Message(ref: option.Some(ref), ..) ->
            socket.Next(option.Some(ref), [])
          socket.Closed(..) ->
            case stashed {
              option.Some(ref) ->
                socket.Next(option.None, [
                  socket.ReplyOk(ref, json.object([#("late", json.bool(True))])),
                ])
              option.None -> socket.Next(stashed, [])
            }
          _ -> socket.Next(stashed, [])
        }
      },
    )
    as "the late-reply app config is valid"
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
    as "the late-reply app starts"
  sockets
}

/// **The third contract break is core's rule, not the topology's.**
///
/// Round 1 recorded that a close discards the worker's in-flight batch, and
/// blamed the router for not being a process: it could not drain its own
/// socket's envelopes before finishing, so #334 would fix it.
///
/// It does not, and no drain can. This test uses no workers at all — one
/// plain `beryl.child_spec` app, one socket, one process — and it still
/// loses the reply. `exec_close_topic` deletes the topic's
/// `pending_reply_refs` *before* it delivers `Closed`, so by the time any
/// layer sees the close its refs are already invalid. A drained batch lands
/// in that same turn and is dropped for that same reason.
///
/// Fixing it means core must hold the close until the worker is quiescent,
/// which means core must know the worker exists — so process-per-channel
/// belongs in `beryl/runtime`, not in a layer above it.
pub fn a_reply_ref_is_dead_by_the_closed_turn_test() -> Nil {
  let channels = late_reply_app()
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  helper.recv(frames) |> string.contains("\"r-1\"") |> should.be_true

  helper.push(channels, "s1", "room:a", "ping", "r-2")
  helper.leave(channels, "s1", "room:a", "jr-1", "r-3")

  // The leave is acknowledged and the topic closes; `r-2` never is.
  helper.recv(frames) |> string.contains("\"r-3\"") |> should.be_true
  helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  helper.recv_none(frames)
}
