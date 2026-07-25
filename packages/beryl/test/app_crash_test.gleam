//// Crash blast radius under app-side dispatch (ADR 0002 open question 3):
//// a crashing `Join` rejects only that join; a crashing `Message` closes
//// only that topic; a crashing `Info` tears down the socket; a crashing
//// `Closed` or `init` is logged and processing continues.

import app_test_helpers as h
import beryl
import beryl/socket.{AcceptJoin, Closed, Info, Join, Message, Next}
import beryl/transport
import beryl/wire
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub type Msg {
  Boom
}

/// Joins to `room:*` are accepted; `crash:*` joins crash. A "boom" message
/// crashes the update; `Info(Boom)` crashes; `Closed` for topics under
/// `room:closed-crash` crashes.
fn start_system(
  events: process.Subject(socket.Input(Msg)),
  senders: process.Subject(socket.Sender(Msg)),
) -> beryl.Sockets {
  let assert Ok(channels) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(info) {
        process.send(senders, info.self)
        #(Nil, [])
      },
      update: fn(model, ev) {
        process.send(events, ev)
        case ev {
          Join("crash:" <> _, _payload, _ref) -> panic as "join crash"
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          Message(_topic, "boom", _payload, _ref) -> panic as "message crash"
          Info(Boom) -> panic as "info crash"
          Closed("room:closed-crash", _reason) -> panic as "closed crash"
          _ -> Next(model, [])
        }
      },
    )
  channels
}

fn start() -> #(
  beryl.Sockets,
  process.Subject(socket.Input(Msg)),
  process.Subject(socket.Sender(Msg)),
) {
  let events = process.new_subject()
  let senders = process.new_subject()
  #(start_system(events, senders), events, senders)
}

pub fn join_crash_rejects_join_and_socket_survives_test() {
  let #(channels, _events, _senders) = start()
  let frames = h.connect(channels, "s1")

  h.join(channels, "s1", "crash:a", "jr-1", "r-1")
  let reply = h.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("join crashed") |> should.be_true

  // The socket still works: a later join succeeds.
  h.join(channels, "s1", "room:a", "jr-2", "r-2")
  let ok_reply = h.recv(frames)
  ok_reply |> string.contains("\"status\":\"ok\"") |> should.be_true
}

pub fn message_crash_closes_only_that_topic_test() {
  let #(channels, events, _senders) = start()
  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply_a = h.recv(frames)
  h.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _reply_b = h.recv(frames)
  let assert Join(_, _, _) = h.next_event(events)
  let assert Join(_, _, _) = h.next_event(events)

  h.push(channels, "s1", "room:a", "boom", "r-3")

  // The crashed topic gets Closed(Errored) and a phx_error frame...
  let assert Message("room:a", "boom", _, _) = h.next_event(events)
  let assert Closed("room:a", socket.Errored(_)) = h.next_event(events)
  let error_frame = h.recv(frames)
  error_frame |> string.contains("phx_error") |> should.be_true

  // ...while the other topic keeps working.
  h.push(channels, "s1", "room:b", "echo", "r-4")
  let assert Message("room:b", "echo", _, _) = h.next_event(events)
}

pub fn info_crash_tears_down_socket_test() {
  let #(channels, events, senders) = start()
  let frames = h.connect(channels, "s1")
  let assert Ok(sender) = process.receive(senders, 500)
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = h.recv(frames)
  let assert Join(_, _, _) = h.next_event(events)

  socket.notify(sender, Boom)

  // Info crash: the topic is closed with an error frame and the socket is
  // gone — further joins are ignored entirely.
  let assert Info(Boom) = h.next_event(events)
  let assert Closed("room:a", socket.Errored(_)) = h.next_event(events)
  let error_frame = h.recv(frames)
  error_frame |> string.contains("phx_error") |> should.be_true

  h.join(channels, "s1", "room:b", "jr-2", "r-2")
  h.recv_none(frames)
}

pub fn closed_crash_is_logged_and_close_still_completes_test() {
  let #(channels, events, _senders) = start()
  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:closed-crash", "jr-1", "r-1")
  let _reply = h.recv(frames)
  let assert Join(_, _, _) = h.next_event(events)

  h.route(
    channels,
    "s1",
    "[\"jr-1\",\"r-2\",\"room:closed-crash\",\"phx_leave\",{}]",
  )

  // The Closed handler crashes, but the leave still acks and the terminal
  // frame still goes out.
  let leave_reply = h.recv(frames)
  leave_reply |> string.contains("phx_reply") |> should.be_true
  let close_frame = h.recv(frames)
  close_frame |> string.contains("phx_close") |> should.be_true

  // And the socket survives.
  h.join(channels, "s1", "room:after", "jr-3", "r-3")
  let assert Closed(_, _) = h.next_event(events)
  let assert Join(_, _, _) = h.next_event(events)
  let ok_reply = h.recv(frames)
  ok_reply |> string.contains("\"status\":\"ok\"") |> should.be_true
}

pub fn init_crash_leaves_socket_unregistered_test() {
  let assert Ok(channels) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { panic as "init crash" },
      update: fn(model: Nil, _ev: socket.Input(Msg)) { Next(model, []) },
    )
  let frames = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(channels)
  transport.admit_socket(
    sockets: channels,
    owner: owner,
    socket_id: "s1",
    send: fn(message) {
      process.send(frames, message)
      Ok(Nil)
    },
    send_binary: fn(_data) { Ok(Nil) },
    codec: None,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
  |> should.be_error

  // The socket was never registered: joins are ignored, no frames arrive.
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  h.recv_none(frames)
}
