//// Lane B keeps presence independent from app-side dispatch. Presence
//// mutations retain their established public API and the shared runtime
//// neither owns nor cleans up entries.

import app_test_helpers as h
import beryl
import beryl/event.{AcceptJoin, Join, Next}
import beryl/presence
import beryl/wire
import gleam/json
import gleam/option.{None}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn app_runtime_does_not_own_presence_entries_test() {
  let assert Ok(tracker) = presence.start(presence.default_config("node1"))
  let tracked_ref =
    presence.track(
      tracker,
      "room:a",
      "user:1",
      "external-session",
      json.object([#("status", json.string("online"))]),
    )
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, event) {
        case event {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          _ -> Next(model, [])
        }
      },
    )

  let frames = h.connect(sockets, "socket-1")
  h.join(sockets, "socket-1", "room:a", "jr-1", "r-1")
  let _reply = h.recv(frames)
  h.route(sockets, "socket-1", "[\"jr-1\",\"r-2\",\"room:a\",\"phx_leave\",{}]")
  let _leave_reply = h.recv(frames)
  let _close = h.recv(frames)

  let assert [entry] = presence.list(tracker, "room:a")
  entry.session_id |> should.equal("external-session")

  presence.untrack(tracker, tracked_ref)
  presence.list(tracker, "room:a") |> should.equal([])
  let assert Ok(Nil) = beryl.stop(sockets)
}
