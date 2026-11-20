import beryl
import beryl/channel
import beryl/overload
import beryl/socket
import beryl/transport
import beryl/wire
import channel_dispatch_helper as helper
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleeunit/should
import test_helper

type Command {
  Add(Int)
  ReadCount
}

type CommandError {
  UnknownEvent(String)
  InvalidAmount
}

fn decode_command(
  event: String,
  payload: Dynamic,
) -> Result(Command, CommandError) {
  case event {
    "add" ->
      decode.run(payload, decode.at(["amount"], decode.int))
      |> result.map(Add)
      |> result.map_error(fn(_) { InvalidAmount })
    "read" -> Ok(ReadCount)
    _ -> Error(UnknownEvent(event))
  }
}

fn error_to_json(error: CommandError) -> json.Json {
  case error {
    UnknownEvent(event) -> json.string("unknown:" <> event)
    InvalidAmount -> json.string("invalid_amount")
  }
}

fn handle_command(
  count: Int,
  command: Command,
  reply: Option(socket.ReplyReference),
) -> channel.Next(Int) {
  let count = case command {
    Add(amount) -> count + amount
    ReadCount -> count
  }
  channel.next(count, [
    channel.reply_ok(reply, json.int(count)),
    channel.push("count", json.int(count)),
  ])
}

fn handle_error(
  count: Int,
  error: CommandError,
  reply: Option(socket.ReplyReference),
) -> channel.Next(Int) {
  case reply {
    Some(_) ->
      channel.next(count, [channel.reply_error(reply, error_to_json(error))])
    None -> channel.close([channel.push("invalid", error_to_json(error))])
  }
}

fn counter() -> channel.JoinResult(Int, Nil) {
  channel.accept(0)
  |> channel.on_decoded_message(
    decode: decode_command,
    handle: handle_command,
    on_error: handle_error,
  )
}

fn open(result: channel.JoinResult(state, Nil)) -> socket.WorkerOutcome {
  channel.open(
    channel.handler("counter", fn(_) { result }),
    socket.WorkerContext(
      socket_id: "s1",
      seed: socket.empty_seed(),
      topic: "counter",
      payload: dynamic.nil(),
      deliver: fn(_) { Ok(Nil) },
      queue_snapshot: fn() { Error(overload.Unavailable) },
    ),
    [],
  )
}

pub fn decoded_callbacks_receive_the_exact_optional_reference_test() -> Nil {
  let reference =
    socket.make_reply_reference("counter", Some("join"), Some("request"))
  list.each([None, Some(reference)], fn(reply) {
    let assert socket.WorkerAccepted(_, _, worker) = open(counter())
    let assert socket.WorkerContinue(_, effects) =
      worker.on_message("read", dynamic.nil(), reply)
    case reply, effects {
      None, [socket.Push(event: "count", payload: payload, ..)] ->
        json.to_string(payload) |> should.equal("0")
      Some(expected),
        [socket.ReplyOk(reference: actual, ..), socket.Push(event: "count", ..)]
      -> actual |> should.equal(expected)
      _, _ -> should.fail()
    }

    list.each(
      [#("unknown", UnknownEvent("unknown")), #("add", InvalidAmount)],
      fn(input) {
        case worker.on_message(input.0, dynamic.nil(), reply), reply {
          socket.WorkerContinue(
            _,
            [socket.ReplyError(reference: actual, payload: payload)],
          ),
            Some(expected)
          -> {
            actual |> should.equal(expected)
            json.to_string(payload)
            |> should.equal(json.to_string(error_to_json(input.1)))
          }
          socket.WorkerClose([
            socket.Push(event: "invalid", payload: payload, ..),
          ]),
            None
          ->
            json.to_string(payload)
            |> should.equal(json.to_string(error_to_json(input.1)))
          _, _ -> should.fail()
        }
      },
    )
  })
}

fn raw(
  joined: channel.JoinResult(Int, Nil),
  label: String,
) -> channel.JoinResult(Int, Nil) {
  channel.on_message(joined, fn(count, _) {
    channel.next(count, [channel.push(label, json.null())])
  })
}

fn decoded(
  joined: channel.JoinResult(Int, Nil),
  label: String,
) -> channel.JoinResult(Int, Nil) {
  channel.on_decoded_message(
    joined,
    decode: fn(_, _) { Ok(Nil) },
    handle: fn(count, _: Nil, _) {
      channel.next(count, [channel.push(label, json.null())])
    },
    on_error: fn(count, _: Nil, _) {
      should.fail()
      channel.stay(count)
    },
  )
}

pub fn raw_and_decoded_registration_last_wins_test() -> Nil {
  list.each(
    [
      #(counter() |> raw("raw"), "raw"),
      #(channel.accept(0) |> raw("raw") |> decoded("typed"), "typed"),
      #(channel.accept(0) |> decoded("first") |> decoded("last"), "last"),
      #(counter() |> raw("first") |> raw("last"), "last"),
    ],
    fn(example) {
      let assert socket.WorkerAccepted(_, _, worker) = open(example.0)
      let assert socket.WorkerContinue(_, [socket.Push(event: event, ..)]) =
        worker.on_message("read", dynamic.nil(), None)
      event |> should.equal(example.1)
    },
  )
}

pub fn decoded_and_raw_builders_preserve_rejected_joins_test() -> Nil {
  let rejected =
    channel.reject(json.string("forbidden"))
    |> decoded("first")
    |> raw("raw")
    |> decoded("last")
  let assert socket.WorkerRejected(reason) = open(rejected)
  json.to_string(reason) |> should.equal("\"forbidden\"")
}

type Echo {
  Echo(String)
}

type EchoError {
  InvalidEcho
}

fn echo_decode(event: String, payload: Dynamic) -> Result(Echo, EchoError) {
  case event {
    "echo" ->
      decode.run(payload, decode.string)
      |> result.map(Echo)
      |> result.map_error(fn(_) { InvalidEcho })
    _ -> Error(InvalidEcho)
  }
}

fn handlers(
  workers: process.Subject(process.Pid),
  decoders: process.Subject(process.Pid),
  successes: process.Subject(Command),
) -> List(channel.Handler) {
  [
    channel.handler("counter", fn(_) {
      process.send(workers, process.self())
      channel.accept(0)
      |> channel.on_decoded_message(
        decode: fn(event, payload) {
          process.send(decoders, process.self())
          decode_command(event, payload)
        },
        handle: fn(count, command, reply) {
          process.send(successes, command)
          handle_command(count, command, reply)
        },
        on_error: handle_error,
      )
    }),
    channel.handler("echo", fn(_) {
      channel.accept(Nil)
      |> channel.on_decoded_message(
        decode: echo_decode,
        handle: fn(_: Nil, command, reply) {
          let Echo(text) = command
          channel.next(Nil, [channel.reply_ok(reply, json.string(text))])
        },
        on_error: fn(_: Nil, error, reply) {
          let InvalidEcho = error
          channel.next(Nil, [channel.reply_error(reply, json.null())])
        },
      )
    }),
  ]
}

fn send(
  sockets: beryl.Sockets,
  reference: Option(String),
  event: String,
  payload: json.Json,
) -> Nil {
  helper.route(
    sockets,
    "s1",
    json.array(
      [
        json.string("counter-join"),
        option_to_json(reference),
        json.string("counter"),
        json.string(event),
        payload,
      ],
      fn(value) { value },
    )
      |> json.to_string,
  )
}

fn option_to_json(value: Option(String)) -> json.Json {
  case value {
    Some(value) -> json.string(value)
    None -> json.null()
  }
}

fn reply(frames: helper.Frames, status: String, response: String) -> Nil {
  helper.recv(frames)
  |> should.equal(
    "[\"counter-join\",\"request\",\"counter\",\"phx_reply\",{\"status\":\""
    <> status
    <> "\",\"response\":"
    <> response
    <> "}]",
  )
}

pub fn decoded_transport_messages_keep_correlation_and_run_in_the_worker_test() -> Nil {
  use <- test_helper.with_isolated_caller(5000)
  let workers = process.new_subject()
  let decoders = process.new_subject()
  let successes = process.new_subject()
  let sockets =
    helper.start(
      beryl.config(wire.phoenix_codec()),
      handlers: handlers(workers, decoders, successes),
    )
  let frames = helper.connect(sockets, "s1")
  helper.join(sockets, "s1", "counter", "counter-join", "join-request")
  let _ = helper.recv(frames)
  let assert Ok(worker) = process.receive(workers, 500)
  let assert Ok(runtime) = transport.runtime_pid(sockets)
  worker |> should.not_equal(runtime)

  send(sockets, Some("request"), "add", json.object([#("amount", json.int(3))]))
  reply(frames, "ok", "3")
  helper.recv(frames) |> should.equal("[null,null,\"counter\",\"count\",3]")
  process.receive(successes, 500) |> should.equal(Ok(Add(3)))
  process.receive(decoders, 500) |> should.equal(Ok(worker))

  // Reusing the request key proves each callback releases the live capability.
  list.each(
    [
      #("unknown", json.null(), "\"unknown:unknown\""),
      #(
        "add",
        json.object([#("amount", json.string("bad"))]),
        "\"invalid_amount\"",
      ),
    ],
    fn(input) {
      send(sockets, Some("request"), input.0, input.1)
      reply(frames, "error", input.2)
      process.receive(decoders, 500) |> should.equal(Ok(worker))
    },
  )
  send(sockets, None, "read", json.null())
  helper.recv(frames) |> should.equal("[null,null,\"counter\",\"count\",3]")
  process.receive(successes, 500) |> should.equal(Ok(ReadCount))
  process.receive(decoders, 500) |> should.equal(Ok(worker))
  process.receive(successes, 0) |> should.equal(Error(Nil))
  helper.recv_none(frames)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn unreferenced_decode_failures_close_only_the_application_topic_test() -> Nil {
  use <- test_helper.with_isolated_caller(5000)
  list.each(
    [#("unknown", "\"unknown:unknown\""), #("add", "\"invalid_amount\"")],
    fn(input) {
      let workers = process.new_subject()
      let decoders = process.new_subject()
      let successes = process.new_subject()
      let sockets =
        helper.start(
          beryl.config(wire.phoenix_codec()),
          handlers: handlers(workers, decoders, successes),
        )
      let frames = helper.connect(sockets, "s1")
      helper.join(sockets, "s1", "counter", "counter-join", "join-counter")
      let _ = helper.recv(frames)
      let assert Ok(worker) = process.receive(workers, 500)
      helper.join(sockets, "s1", "echo", "echo-join", "join-echo")
      let _ = helper.recv(frames)

      send(sockets, None, input.0, json.null())
      helper.recv(frames)
      |> should.equal("[null,null,\"counter\",\"invalid\"," <> input.1 <> "]")
      helper.recv(frames)
      |> should.equal(
        "[\"counter-join\",\"counter-join\",\"counter\",\"phx_close\",{}]",
      )
      process.receive(decoders, 500) |> should.equal(Ok(worker))
      process.receive(successes, 0) |> should.equal(Error(Nil))

      helper.route(
        sockets,
        "s1",
        "[\"echo-join\",\"echo-request\",\"echo\",\"echo\",\"still here\"]",
      )
      helper.recv(frames)
      |> should.equal(
        "[\"echo-join\",\"echo-request\",\"echo\",\"phx_reply\",{\"status\":\"ok\",\"response\":\"still here\"}]",
      )
      helper.recv_none(frames)
      beryl.stop(sockets) |> should.equal(Ok(Nil))
    },
  )
}
