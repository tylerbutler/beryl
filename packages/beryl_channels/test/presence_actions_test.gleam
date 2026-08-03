//// Presence actions lower onto core presence effects scoped to the
//// channel's own topic, and keep the core's apply-time snapshot
//// semantics.

import beryl
import beryl/presence
import beryl/wire
import beryl_channels
import beryl_channels/channel
import dispatch_helpers as helper
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should

fn encode_users(entries: List(presence.PresenceEntry)) -> json.Json {
  json.object(list.map(entries, fn(entry) { #(entry.key, entry.meta) }))
}

/// A channel that tracks presence from its own `on_info` (right after the
/// join acknowledgment) and untracks-then-snapshots on a client message —
/// both in a single action list, and neither naming a topic.
fn presence_handler() -> channel.Handler {
  channel.handler("room:*", fn(info, _topic, _payload) {
    let callbacks =
      channel.callbacks()
      |> channel.on_info(fn(state, _message) {
        channel.continue_with(
          state,
          channel.actions()
            |> channel.presence_track(
              "alice",
              json.object([#("status", json.string("online"))]),
            )
            |> channel.broadcast_presence("presence_list", encode_users),
        )
      })
      |> channel.on_message(fn(state, _message) {
        channel.continue_with(
          state,
          channel.actions()
            |> channel.presence_untrack("alice")
            |> channel.push_presence("presence_list", encode_users),
        )
      })

    channel.notify(info.self, Nil)
    channel.accept(channel.joined(Nil, callbacks))
  })
}

fn start_system(handle: presence.Presence) -> beryl.Sockets {
  helper.start(
    beryl.config(wire.phoenix_codec()) |> beryl.with_presence_handle(handle),
    handlers: [presence_handler()],
  )
}

fn start_presence() -> presence.Presence {
  let assert Ok(handle) = presence.start(presence.default_config("node1"))
    as "presence starts"
  handle
}

pub fn presence_actions_target_the_channels_own_topic_test() {
  let handle = start_presence()
  let channels = start_system(handle)
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = helper.recv(frames)

  // The tracked presence lands on `room:a` — the channel's own topic —
  // even though no action named a topic.
  let diff = helper.recv(frames)
  diff |> string.contains("presence_diff") |> should.be_true
  diff |> string.contains("\"room:a\"") |> should.be_true
  let snapshot = helper.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  snapshot |> string.contains("alice") |> should.be_true

  process.sleep(20)
  let assert [entry] = presence.list(handle, "room:a")
    as "the presence actor holds one entry for the topic"
  entry.key |> should.equal("alice")
}

pub fn presence_snapshots_see_earlier_actions_in_the_same_list_test() {
  let handle = start_presence()
  let channels = start_system(handle)
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = helper.recv(frames)
  let _join_diff = helper.recv(frames)
  let _join_snapshot = helper.recv(frames)

  helper.push(channels, "s1", "room:a", "part", "r-2")

  // The untrack is applied before the snapshot in the same list, so the
  // snapshot pushed to this socket is already empty.
  let leave_diff = helper.recv(frames)
  leave_diff |> string.contains("presence_diff") |> should.be_true
  let snapshot = helper.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  snapshot |> string.contains("alice") |> should.be_false

  process.sleep(20)
  presence.list(handle, "room:a") |> should.equal([])
}
