import beryl
import beryl/channel
import beryl/overload
import beryl/socket
import beryl/transport
import beryl/wire
import gleam/dynamic
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should
import live_poll/raw
import live_poll/store
import live_poll/timer
import tutorial_composition as composition
import tutorial_counter as counter

fn start_raw(
  init: fn(socket.ConnectInfo(message)) -> #(model, List(socket.Effect)),
  update: fn(model, socket.Input(message)) -> socket.Next(model),
) -> beryl.Sockets {
  let assert Ok(#(sockets, specification)) =
    beryl.child_spec(beryl.config(wire.phoenix_codec()), init:, update:)
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(specification)
    |> static_supervisor.start()
  sockets
}

fn connect(sockets: beryl.Sockets, id: String) -> process.Subject(String) {
  let frames = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(sockets)
  let assert Ok(Nil) =
    transport.admit_socket(
      sockets:,
      owner:,
      socket_id: id,
      send: fn(frame) {
        process.send(frames, frame)
        Ok(Nil)
      },
      send_binary: fn(_) { Ok(Nil) },
      codec: None,
      seed: socket.empty_seed(),
      close: fn() { Nil },
    )
  frames
}

fn send(
  sockets: beryl.Sockets,
  id: String,
  topic: String,
  event: String,
  payload: json.Json,
) -> Nil {
  let encoded =
    json.array(
      [
        json.string(topic),
        json.string(event),
        json.string(topic),
        json.string(event),
        payload,
      ],
      of: fn(value) { value },
    )
    |> json.to_string
  let assert Ok(decoded) = wire.decode_message(encoded)
  transport.route_decoded(sockets, id, decoded)
  |> should.equal(Ok(Nil))
}

fn empty() -> json.Json {
  json.object([])
}

fn recv(frames: process.Subject(String)) -> String {
  let assert Ok(frame) = process.receive(frames, 1000)
  frame
}

fn contains(frame: String, text: String) -> Nil {
  #(string.contains(frame, text), frame, text)
  |> should.equal(#(True, frame, text))
}

fn no_frame(frames: process.Subject(String)) -> Nil {
  process.receive(frames, 50) |> should.be_error
}

/// The counter example runs against real opaque request and join references.
pub fn tutorial_counter_request_and_state_test() -> Nil {
  let senders = process.new_subject()
  let sockets =
    start_raw(
      fn(info) {
        process.send(senders, info.self)
        counter.counter_init(info)
      },
      counter.counter_update,
    )
  let frames = connect(sockets, "counter")
  let assert Ok(sender) = process.receive(senders, 1000)
  send(sockets, "counter", "unknown", "phx_join", empty())
  recv(frames) |> contains("\"status\":\"error\"")
  send(sockets, "counter", "counter:demo", "phx_join", empty())
  recv(frames) |> contains("\"status\":\"ok\"")
  send(sockets, "counter", "counter:demo", "get_count", empty())
  recv(frames) |> contains("\"response\":0")
  socket.notify(sender, counter.Increment) |> should.equal(Ok(Nil))
  socket.notify(sender, counter.Increment) |> should.equal(Ok(Nil))
  socket.notify(sender, counter.Increment) |> should.equal(Ok(Nil))
  no_frame(frames)
  send(sockets, "counter", "counter:demo", "get_count", empty())
  recv(frames) |> contains("\"response\":3")
  socket.notify(sender, counter.Increment) |> should.equal(Ok(Nil))
  no_frame(frames)
  send(sockets, "counter", "counter:demo", "get_count", empty())
  recv(frames) |> contains("\"response\":4")
  beryl.stop(sockets) |> should.equal(Ok(Nil))

  counter.counter_update(
    3,
    socket.Message("counter:demo", "get_count", dynamic.nil(), None),
  )
  |> should.equal(socket.Next(3, []))
  counter.counter_update(3, socket.Binary("counter:demo", <<>>))
  |> should.equal(socket.Next(3, []))
  counter.counter_update(3, socket.Closed("counter:demo", socket.Normal))
  |> should.equal(socket.Next(3, []))
  counter.counter_update(
    3,
    socket.Message("other", "get_count", dynamic.nil(), None),
  )
  |> should.equal(socket.Next(3, []))
}

type Mode {
  Raw
  Channels
}

type GuideAccess {
  RawGuide(socket.Sender(composition.Message))
  ChannelGuide(process.Subject(channel.Sender(composition.GuideInfo)))
}

fn guide_delivery(
  access: GuideAccess,
  generation: Int,
) -> fn(String) -> Result(Nil, overload.AdmissionError) {
  case access {
    RawGuide(sender) -> fn(text) {
      socket.notify(sender, composition.GuideReady(generation, text))
    }
    ChannelGuide(senders) -> {
      let assert Ok(sender) = process.receive(senders, 1000)
      fn(text) { channel.notify(sender, composition.Ready(text)) }
    }
  }
}

fn composition_system(
  mode: Mode,
) -> #(beryl.Sockets, process.Subject(String), GuideAccess) {
  let assert Ok(polls) = store.start()
  case mode {
    Raw -> {
      let senders = process.new_subject()
      let sockets =
        start_raw(
          fn(info) {
            process.send(senders, info.self)
            composition.init(info)
          },
          fn(model, input) { composition.update(polls, model, input) },
        )
      let frames = connect(sockets, "client")
      let assert Ok(sender) = process.receive(senders, 1000)
      #(sockets, frames, RawGuide(sender))
    }
    Channels -> {
      let senders = process.new_subject()
      let assert Ok(#(sockets, specification)) =
        channel.child_spec(
          beryl.config(wire.phoenix_codec()),
          handlers: composition.handlers(polls, process.send(senders, _)),
        )
      let assert Ok(_) =
        static_supervisor.new(static_supervisor.OneForOne)
        |> static_supervisor.add(specification)
        |> static_supervisor.start()
      #(sockets, connect(sockets, "client"), ChannelGuide(senders))
    }
  }
}

fn composition_scenario(mode: Mode) -> List(String) {
  let #(sockets, frames, access) = composition_system(mode)
  send(sockets, "client", "poll:demo", "phx_join", empty())
  recv(frames) |> contains("\"status\":\"ok\"")
  send(sockets, "client", "guide", "phx_join", empty())
  recv(frames) |> contains("\"status\":\"ok\"")
  let initial = recv(frames)
  initial |> contains("\"delivery\":1")
  let old_delivery = guide_delivery(access, 1)
  old_delivery("another tip") |> should.equal(Ok(Nil))
  let second_tip = recv(frames)
  second_tip |> contains("\"delivery\":2")

  let vote = json.object([#("option", json.string("gleam"))])
  send(sockets, "client", "poll:demo", "vote", vote)
  let first_vote = recv(frames)
  first_vote |> contains("\"gleam\":1")
  send(sockets, "client", "poll:demo", "vote", vote)
  let second_vote = recv(frames)
  second_vote |> contains("\"gleam\":2")
  no_frame(frames)

  send(sockets, "client", "poll:demo", "phx_leave", empty())
  recv(frames) |> contains("\"status\":\"ok\"")
  recv(frames) |> contains("\"phx_close\"")
  old_delivery("guide remains") |> should.equal(Ok(Nil))
  let after_leave = recv(frames)
  after_leave |> contains("\"delivery\":3")
  send(sockets, "client", "poll:demo", "phx_join", empty())
  recv(frames) |> contains("\"status\":\"ok\"")
  send(sockets, "client", "poll:demo", "get_state", empty())
  let new_poll = recv(frames)
  new_poll |> contains("\"gleam\":0")
  new_poll |> contains("\"erlang\":0")

  send(sockets, "client", "guide", "phx_leave", empty())
  recv(frames) |> contains("\"status\":\"ok\"")
  recv(frames) |> contains("\"phx_close\"")
  // The worker may have closed its queue or exited and removed it.
  let stale_outcomes = case mode {
    Raw -> [Ok(Nil)]
    Channels -> [Error(overload.Closed), Error(overload.Unavailable)]
  }
  stale_outcomes
  |> list.contains(old_delivery("must not arrive after leave"))
  |> should.be_true
  no_frame(frames)
  send(sockets, "client", "guide", "phx_join", empty())
  recv(frames) |> contains("\"status\":\"ok\"")
  let new_guide = recv(frames)
  new_guide |> contains("\"delivery\":1")
  let new_delivery = guide_delivery(access, 2)
  stale_outcomes
  |> list.contains(old_delivery("must not arrive in replacement"))
  |> should.be_true
  new_delivery("fresh tip") |> should.equal(Ok(Nil))
  let fresh_tip = recv(frames)
  fresh_tip |> contains("\"delivery\":2")
  fresh_tip |> contains("fresh tip")
  no_frame(frames)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
  [
    initial,
    second_tip,
    first_vote,
    second_vote,
    after_leave,
    new_poll,
    new_guide,
    fresh_tip,
  ]
}

/// Both checked composition adapters produce the same Phoenix frames.
pub fn tutorial_composition_parity_test() -> Nil {
  composition_scenario(Raw) |> should.equal(composition_scenario(Channels))
}

/// The browser simulation follows the real Voting checkpoint's recipients.
pub fn tutorial_shared_poll_recipients_and_cleanup_test() -> Nil {
  let assert Ok(polls) = store.start()
  let assert Ok(clock) = timer.start()
  let sockets =
    start_raw(raw.init, raw.update(raw.Voting, polls, clock, 60_000))
  let alice = connect(sockets, "alice")
  let bob = connect(sockets, "bob")
  send(sockets, "alice", "poll:demo", "phx_join", empty())
  recv(alice) |> contains("\"status\":\"ok\"")
  send(sockets, "bob", "poll:demo", "phx_join", empty())
  recv(bob) |> contains("\"status\":\"ok\"")
  send(sockets, "alice", "poll:demo", "get_state", empty())
  recv(alice) |> contains("\"gleam\":0")
  send(sockets, "bob", "poll:demo", "get_state", empty())
  recv(bob) |> contains("\"erlang\":0")
  send(
    sockets,
    "alice",
    "poll:demo",
    "vote",
    json.object([#("option", json.string("gleam"))]),
  )
  let reply = recv(alice)
  reply |> contains("\"phx_reply\"")
  reply |> contains("\"gleam\":1")
  let broadcast = recv(bob)
  broadcast |> contains("\"poll_state\"")
  broadcast |> contains("\"gleam\":1")
  no_frame(alice)
  send(
    sockets,
    "bob",
    "poll:demo",
    "vote",
    json.object([#("option", json.string("erlang"))]),
  )
  recv(bob) |> contains("\"phx_reply\"")
  recv(alice) |> contains("\"poll_state\"")

  transport.socket_disconnected(sockets, "alice")
  recv(alice) |> contains("\"phx_close\"")
  send(
    sockets,
    "bob",
    "poll:demo",
    "vote",
    json.object([#("option", json.string("erlang"))]),
  )
  recv(bob) |> contains("\"erlang\":2")
  no_frame(alice)
  let alice_again = connect(sockets, "alice-again")
  send(sockets, "alice-again", "poll:demo", "phx_join", empty())
  recv(alice_again) |> contains("\"status\":\"ok\"")
  send(sockets, "alice-again", "poll:demo", "get_state", empty())
  let retained = recv(alice_again)
  retained |> contains("\"gleam\":1")
  retained |> contains("\"erlang\":2")
  no_frame(alice)

  // Leave acknowledgments let the test complete each topic lifecycle before rejoining.
  send(sockets, "alice-again", "poll:demo", "phx_leave", empty())
  recv(alice_again) |> contains("\"status\":\"ok\"")
  recv(alice_again) |> contains("\"phx_close\"")
  send(sockets, "bob", "poll:demo", "phx_leave", empty())
  recv(bob) |> contains("\"status\":\"ok\"")
  recv(bob) |> contains("\"phx_close\"")
  store.close(polls, "demo") |> should.equal(store.RoomNotFound)
  send(sockets, "bob", "poll:demo", "phx_join", empty())
  recv(bob) |> contains("\"status\":\"ok\"")
  send(sockets, "bob", "poll:demo", "get_state", empty())
  let fresh = recv(bob)
  fresh |> contains("\"gleam\":0")
  fresh |> contains("\"erlang\":0")
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}
