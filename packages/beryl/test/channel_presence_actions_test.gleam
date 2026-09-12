//// Presence actions lower onto core presence effects scoped to the
//// channel's own topic, and keep the core's apply-time snapshot
//// semantics.

import beryl
import beryl/channel
import beryl/presence
import beryl/wire
import channel_dispatch_helper as helper
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import test_helper

fn encode_users(entries: List(presence.PresenceEntry)) -> json.Json {
  json.object(list.map(entries, fn(entry) { #(entry.key, entry.meta) }))
}

/// A channel that tracks presence from its own `on_info` (right after the
/// join acknowledgment) and untracks-then-snapshots on a client message —
/// both in a single action list, and neither naming a topic.
fn presence_handler() -> channel.Handler {
  channel.handler("room:*", fn(context) {
    let result =
      channel.accept(Nil)
      |> channel.on_info(fn(state, _message) {
        channel.next(state, [
          channel.presence_track(
            "alice",
            json.object([#("status", json.string("online"))]),
          ),
          channel.broadcast_presence("presence_list", encode_users),
        ])
      })
      |> channel.on_message(fn(state, _message) {
        channel.next(state, [
          channel.presence_untrack("alice"),
          channel.push_presence("presence_list", encode_users),
        ])
      })

    let assert Ok(_) = channel.notify(context.self, Nil)
    result
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

pub fn presence_actions_target_the_channels_own_topic_test() -> Nil {
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

  // No settling delay is needed: the runtime applies presence effects with
  // synchronous calls to the presence actor, and the snapshot frame above
  // was encoded *after* the track committed.
  let assert Ok([entry]) = presence.list(handle, "room:a")
    as "the presence actor holds one entry for the topic"
  entry.key |> should.equal("alice")
}

pub fn presence_snapshots_see_earlier_actions_in_the_same_list_test() -> Nil {
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

  // Same ordering argument as above: the snapshot frame is only sent once
  // the untrack call has returned.
  presence.list(handle, "room:a") |> should.equal(Ok([]))
}

fn metadata(status: String) -> json.Json {
  json.object([#("status", json.string(status))])
}

fn recv_payload(
  frames: helper.Frames,
  topic: String,
  event: String,
) -> dynamic.Dynamic {
  let decoder = {
    use actual_topic <- decode.field(2, decode.string)
    use actual_event <- decode.field(3, decode.string)
    use payload <- decode.field(4, decode.dynamic)
    decode.success(#(actual_topic, actual_event, payload))
  }
  let assert Ok(#(actual_topic, actual_event, payload)) =
    json.parse(helper.recv(frames), decoder)
  actual_topic |> should.equal(topic)
  actual_event |> should.equal(event)
  payload
}

fn roster_statuses(payload: dynamic.Dynamic) -> List(String) {
  let decoder = {
    use metas <- decode.field("alice", {
      use metas <- decode.field(
        "metas",
        decode.list({
          use ref <- decode.field("phx_ref", decode.string)
          use status <- decode.field("status", decode.string)
          decode.success(#(ref, status))
        }),
      )
      decode.success(metas)
    })
    decode.success(metas)
  }
  let assert Ok(metas) = decode.run(payload, decoder)
  list.map(metas, fn(meta) {
    let #(ref, status) = meta
    string.is_empty(ref) |> should.be_false
    status
  })
}

fn managed_presence_handler() -> channel.Handler {
  channel.handler("room:*", fn(_context) {
    channel.accept(Nil)
    |> channel.with_reply(json.string("accepted"))
    |> channel.with_actions([channel.push("before", json.null())])
    |> channel.with_presence(key: "alice", meta: metadata("online"))
    |> channel.with_actions([channel.push("after", json.null())])
    |> channel.on_message(fn(state, message) {
      channel.next(state, [
        channel.presence_track("alice", metadata("away")),
        channel.reply_ok(message.reply, json.null()),
      ])
    })
  })
}

fn start_managed_presence(handle: presence.Presence) -> beryl.Sockets {
  helper.start(
    beryl.config(wire.phoenix_codec()) |> beryl.with_presence_handle(handle),
    handlers: [managed_presence_handler()],
  )
}

fn join_managed_presence(
  channels: beryl.Sockets,
  frames: helper.Frames,
  socket_id: String,
  topic: String,
) -> List(String) {
  helper.join(channels, socket_id, topic, "jr-1", "r-1")
  let reply = recv_payload(frames, topic, "phx_reply")
  let reply_decoder = {
    use status <- decode.field("status", decode.string)
    use response <- decode.field("response", decode.string)
    decode.success(#(status, response))
  }
  decode.run(reply, reply_decoder) |> should.equal(Ok(#("ok", "accepted")))
  let _before = recv_payload(frames, topic, "before")
  let _diff = recv_payload(frames, topic, "presence_diff")
  let snapshot = recv_payload(frames, topic, "presence_state")
  let _after = recv_payload(frames, topic, "after")
  roster_statuses(snapshot)
}

pub fn with_presence_preserves_join_actions_and_callbacks_test() -> Nil {
  let handle = start_presence()
  let channels = start_managed_presence(handle)
  let frames = helper.connect(channels, "s1")

  join_managed_presence(channels, frames, "s1", "room:a")
  |> should.equal(["online"])
  let assert Ok([entry]) = presence.list(handle, "room:a")
  entry.session_id |> should.equal("s1")
  entry.key |> should.equal("alice")

  helper.push(channels, "s1", "room:a", "away", "r-2")
  let _diff = recv_payload(frames, "room:a", "presence_diff")
  let _reply = recv_payload(frames, "room:a", "phx_reply")
  let assert Ok([updated]) = presence.list(handle, "room:a")
  updated.meta
  |> json.to_string
  |> string.contains("\"away\"")
  |> should.be_true
  helper.recv_none(frames)
  helper.disconnect(channels, "s1")
  let _close = recv_payload(frames, "room:a", "phx_close")
  beryl.stop(channels) |> should.equal(Ok(Nil))
}

pub fn with_presence_groups_sessions_and_cleans_up_only_closed_topics_test() -> Nil {
  let handle = start_presence()
  let channels = start_managed_presence(handle)
  let first = helper.connect(channels, "s1")
  let second = helper.connect(channels, "s2")

  join_managed_presence(channels, first, "s1", "room:a")
  |> should.equal(["online"])
  join_managed_presence(channels, second, "s2", "room:a")
  |> should.equal(["online", "online"])
  let _join_diff = recv_payload(first, "room:a", "presence_diff")

  join_managed_presence(channels, first, "s1", "room:b")
  |> should.equal(["online"])
  helper.recv_none(second)
  helper.leave(channels, "s1", "room:a", "jr-1", "r-2")
  let _reply = recv_payload(first, "room:a", "phx_reply")
  let _close = recv_payload(first, "room:a", "phx_close")
  let _leave = recv_payload(second, "room:a", "presence_diff")
  let assert Ok([remaining]) = presence.list(handle, "room:a")
  remaining.session_id |> should.equal("s2")
  let assert Ok([other_topic]) = presence.list(handle, "room:b")
  other_topic.session_id |> should.equal("s1")

  helper.disconnect(channels, "s2")
  let _close = recv_payload(second, "room:a", "phx_close")
  test_helper.wait_until(
    fn() { presence.list(handle, "room:a") == Ok([]) },
    1000,
    10,
  )
  helper.disconnect(channels, "s1")
  let _close = recv_payload(first, "room:b", "phx_close")
  test_helper.wait_until(
    fn() { presence.list(handle, "room:b") == Ok([]) },
    1000,
    10,
  )
  helper.recv_none(first)
  helper.recv_none(second)
  beryl.stop(channels) |> should.equal(Ok(Nil))
}

pub fn with_presence_leaves_rejected_joins_unchanged_test() -> Nil {
  let handle = start_presence()
  let handler =
    channel.handler("room:*", fn(_context) {
      channel.reject(json.string("denied"))
      |> channel.with_presence(key: "alice", meta: metadata("online"))
    })
  let channels =
    helper.start(
      beryl.config(wire.phoenix_codec()) |> beryl.with_presence_handle(handle),
      handlers: [handler],
    )
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let reply = recv_payload(frames, "room:a", "phx_reply")
  let decoder = {
    use status <- decode.field("status", decode.string)
    use reason <- decode.field("response", decode.string)
    decode.success(#(status, reason))
  }
  decode.run(reply, decoder) |> should.equal(Ok(#("error", "denied")))
  presence.list(handle, "room:a") |> should.equal(Ok([]))
  helper.recv_none(frames)
  beryl.stop(channels) |> should.equal(Ok(Nil))
}
