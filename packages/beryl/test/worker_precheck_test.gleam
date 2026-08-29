//// The runtime consults the worker contract's `accepts` before it starts a
//// topic worker. A refused topic gets a `RejectJoin` with the contract's
//// reason, and `open` never runs — no worker process is spawned.

import beryl
import beryl/socket
import beryl/wire
import channel_dispatch_helper as helper
import gleam/erlang/process
import gleam/json
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should

fn start(
  accepts accepts: fn(String) -> Result(Nil, json.Json),
  open open: fn(socket.WorkerContext) -> socket.WorkerOutcome,
) -> beryl.Sockets {
  let assert Ok(#(sockets, spec)) =
    beryl.worker_child_spec(beryl.config(wire.phoenix_codec()), accepts:, open:)
    as "the config is valid"
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
    as "the worker supervision tree starts"
  sockets
}

fn reason(text: String) -> json.Json {
  json.object([#("reason", json.string(text))])
}

pub fn a_refused_topic_is_rejected_without_running_open_test() {
  let opened = process.new_subject()
  let channels =
    start(
      accepts: fn(_topic) { Error(reason("unmatched topic")) },
      open: fn(_context) {
        process.send(opened, "open ran")
        socket.WorkerRejected(reason("unmatched topic"))
      },
    )
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "nope:1", "jr-1", "r-1")

  let reply = helper.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply
  |> string.contains("{\"reason\":\"unmatched topic\"}")
  |> should.be_true
  // `open` never ran, so no worker was spawned for the refused join.
  process.receive(opened, 100) |> should.be_error
  Nil
}

pub fn an_accepted_topic_still_reaches_open_test() {
  let channels =
    start(accepts: fn(_topic) { Ok(Nil) }, open: fn(_context) {
      socket.WorkerRejected(reason("forbidden"))
    })
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:1", "jr-1", "r-1")

  let reply = helper.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("forbidden") |> should.be_true
}
