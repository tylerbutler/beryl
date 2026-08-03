//// The Phoenix wire-contract parity matrix.
////
//// Every scenario in this module is written **once** and run by
//// [`wire_matrix.compare`](./wire_matrix.html) against two systems that
//// implement the same application contract: a raw `beryl.start` with a
//// hand-written `update`, and a `beryl_channels.start` with a handler
//// table. Both are served by the same `beryl_mist` transport over a real
//// WebSocket and share one `beryl.Config`, so the only variable is the
//// dispatch layer.
////
//// `compare` fails if the two systems observe different frames, and
//// returns the shared observation so each scenario can also pin what that
//// observation must be. A scenario therefore proves two things at once:
//// the contract holds, and the channel layer is invisible on the wire.

import beryl
import beryl/presence
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import wire_matrix as matrix

const lobby = "room:lobby"

/// Connect, join `room:lobby`, and return the join reply.
fn join(system: matrix.System) -> #(matrix.Client, matrix.Frame) {
  let client = matrix.connect(system)
  matrix.send(client, matrix.join_frame("jr-1", "r-1", lobby, json.object([])))
  let assert [reply] = matrix.take_exactly(client, 1)
  #(client, reply)
}

// === Join ==================================================================

pub fn a_join_is_accepted_with_the_same_reply_test() {
  let reply =
    matrix.compare_with(config: matrix.default_config, scenario: fn(system) {
      let #(client, reply) = join(system)
      matrix.close(client)
      reply
    })

  reply.join_ref |> should.equal(Some("jr-1"))
  reply.ref |> should.equal(Some("r-1"))
  reply.topic |> should.equal(lobby)
  reply.event |> should.equal(matrix.reply_event())
  reply.payload
  |> should.equal(
    "{\"response\":{\"joined\":true,\"topic\":\"room:lobby\"},\"status\":\"ok\"}",
  )
}

pub fn a_rejected_join_reports_the_same_reason_test() {
  let reply =
    matrix.compare_with(config: matrix.default_config, scenario: fn(system) {
      let client = matrix.connect(system)
      matrix.send(
        client,
        matrix.join_frame(
          "jr-1",
          "r-1",
          lobby,
          json.object([#("deny", json.bool(True))]),
        ),
      )
      let assert [reply] = matrix.take_exactly(client, 1)
      matrix.close(client)
      reply
    })

  reply.event |> should.equal(matrix.reply_event())
  reply.payload
  |> should.equal("{\"response\":{\"reason\":\"denied\"},\"status\":\"error\"}")
}

pub fn a_join_for_an_unowned_topic_is_refused_the_same_way_test() {
  let reply =
    matrix.compare_with(config: matrix.default_config, scenario: fn(system) {
      let client = matrix.connect(system)
      matrix.send(
        client,
        matrix.join_frame("jr-1", "r-1", "other:topic", json.object([])),
      )
      let assert [reply] = matrix.take_exactly(client, 1)
      matrix.close(client)
      reply
    })

  reply.topic |> should.equal("other:topic")
  reply.payload
  |> should.equal(
    "{\"response\":{\"reason\":\"unmatched topic\"},\"status\":\"error\"}",
  )
}

// === Replies ===============================================================

pub fn a_message_reply_is_identical_test() {
  let reply =
    matrix.compare_with(config: matrix.default_config, scenario: fn(system) {
      let #(client, _join) = join(system)
      matrix.send(
        client,
        matrix.event_frame("jr-1", "r-2", lobby, "ping", json.object([])),
      )
      let assert [reply] = matrix.take_exactly(client, 1)
      matrix.close(client)
      reply
    })

  // Phoenix echoes the channel's join_ref on event replies.
  reply.join_ref |> should.equal(Some("jr-1"))
  reply.ref |> should.equal(Some("r-2"))
  reply.event |> should.equal(matrix.reply_event())
  reply.payload
  |> should.equal("{\"response\":{\"pong\":true},\"status\":\"ok\"}")
}

pub fn an_error_reply_is_identical_test() {
  let reply =
    matrix.compare_with(config: matrix.default_config, scenario: fn(system) {
      let #(client, _join) = join(system)
      matrix.send(
        client,
        matrix.event_frame("jr-1", "r-2", lobby, "boom", json.object([])),
      )
      let assert [reply] = matrix.take_exactly(client, 1)
      matrix.close(client)
      reply
    })

  reply.ref |> should.equal(Some("r-2"))
  reply.payload
  |> should.equal("{\"response\":{\"reason\":\"nope\"},\"status\":\"error\"}")
}

// === Push and fan-out ======================================================

pub fn a_server_push_is_identical_test() {
  let pushed =
    matrix.compare_with(config: matrix.default_config, scenario: fn(system) {
      let #(client, _join) = join(system)
      matrix.send(
        client,
        matrix.unrefed_event_frame("jr-1", lobby, "push_me", json.object([])),
      )
      let assert [pushed] = matrix.take_exactly(client, 1)
      matrix.close(client)
      pushed
    })

  // A push is unsolicited: no join_ref and no ref, like Phoenix.
  pushed.join_ref |> should.equal(None)
  pushed.ref |> should.equal(None)
  pushed.topic |> should.equal(lobby)
  pushed.event |> should.equal("pushed")
  pushed.payload |> should.equal("{\"from\":\"server\"}")
}

pub fn broadcast_from_excludes_the_sender_identically_test() {
  let received =
    matrix.compare_with(config: matrix.default_config, scenario: fn(system) {
      let #(sender, _join) = join(system)
      let listener = matrix.connect(system)
      matrix.send(
        listener,
        matrix.join_frame("jr-2", "r-9", lobby, json.object([])),
      )
      let assert [_listener_join] = matrix.take_exactly(listener, 1)

      matrix.send(
        sender,
        matrix.unrefed_event_frame(
          "jr-1",
          lobby,
          "shout",
          json.object([#("body", json.string("hi"))]),
        ),
      )
      let assert [received] = matrix.take_exactly(listener, 1)
      // The sender is excluded from its own broadcast_from.
      matrix.expect_silence(sender)
      matrix.close(sender)
      matrix.close(listener)
      received
    })

  received.event |> should.equal("shouted")
  received.topic |> should.equal(lobby)
  received.payload |> should.equal("{\"body\":\"hi\"}")
}

pub fn a_server_side_broadcast_reaches_both_systems_identically_test() {
  let received =
    matrix.compare_with(config: matrix.default_config, scenario: fn(system) {
      let #(client, _join) = join(system)
      beryl.broadcast(
        system.sockets,
        lobby,
        "announcement",
        json.object([#("body", json.string("hello"))]),
      )
      let assert [received] = matrix.take_exactly(client, 1)
      matrix.close(client)
      received
    })

  received.event |> should.equal("announcement")
  received.payload |> should.equal("{\"body\":\"hello\"}")
}

// === Heartbeat and leave ===================================================

pub fn a_heartbeat_is_answered_identically_test() {
  let reply =
    matrix.compare_with(config: matrix.default_config, scenario: fn(system) {
      let #(client, _join) = join(system)
      matrix.send(client, matrix.heartbeat_frame("hb-1"))
      let assert [reply] = matrix.take_exactly(client, 1)
      matrix.close(client)
      reply
    })

  reply.join_ref |> should.equal(None)
  reply.ref |> should.equal(Some("hb-1"))
  reply.topic |> should.equal("phoenix")
  reply.event |> should.equal(matrix.reply_event())
  reply.payload |> should.equal("{\"response\":{},\"status\":\"ok\"}")
}

pub fn a_leave_ends_the_channel_identically_test() {
  let frames =
    matrix.compare_with(config: matrix.default_config, scenario: fn(system) {
      let #(client, _join) = join(system)
      matrix.send(client, matrix.leave_frame("jr-1", "r-3", lobby))
      let frames = matrix.take_exactly(client, 2)

      // The topic is gone: a later broadcast reaches nobody on this socket.
      beryl.broadcast(system.sockets, lobby, "after_leave", json.object([]))
      matrix.expect_silence(client)
      matrix.close(client)
      frames
    })

  // Phoenix answers the leave ref, then announces the channel is closed.
  let assert [reply, closed] = frames
  reply.ref |> should.equal(Some("r-3"))
  reply.event |> should.equal(matrix.reply_event())
  reply.payload |> should.equal("{\"response\":{},\"status\":\"ok\"}")
  closed.event |> should.equal("phx_close")
  closed.topic |> should.equal(lobby)
  closed.join_ref |> should.equal(Some("jr-1"))
  closed.payload |> should.equal("{}")
}

// === Binary ================================================================

pub fn a_codec_decoded_binary_frame_is_handled_identically_test() {
  let pushed =
    matrix.compare_with(config: matrix.default_config, scenario: fn(system) {
      let #(client, _join) = join(system)
      matrix.send_binary(
        client,
        matrix.binary_frame("jr-1", "r-4", lobby, "blob", <<1, 2, 3, 4, 5>>),
      )
      let assert [pushed] = matrix.take_exactly(client, 1)
      matrix.close(client)
      pushed
    })

  pushed.event |> should.equal("binary_in")
  pushed.payload |> should.equal("{\"bytes\":5,\"kind\":\"decoded\"}")
}

pub fn an_undecoded_binary_frame_is_handled_identically_test() {
  let pushed =
    matrix.compare_with(config: matrix.text_only_config, scenario: fn(system) {
      let #(client, _join) = join(system)
      matrix.send_binary(client, <<9, 9, 9>>)
      let assert [pushed] = matrix.take_exactly(client, 1)
      matrix.close(client)
      pushed
    })

  pushed.event |> should.equal("binary_in")
  pushed.payload |> should.equal("{\"bytes\":3,\"kind\":\"raw\"}")
}

// === Presence ==============================================================

pub fn presence_tracking_produces_the_same_frames_test() {
  let #(frames, entries) =
    matrix.compare(
      setup: fn() {
        let assert Ok(handle) = presence.start(presence.default_config("node1"))
          as "the presence actor starts"
        #(matrix.default_config() |> beryl.with_presence_handle(handle), handle)
      },
      scenario: fn(system, handle) {
        let #(client, _join) = join(system)
        matrix.send(
          client,
          matrix.unrefed_event_frame("jr-1", lobby, "track", json.object([])),
        )
        let frames = matrix.take_exactly(client, 2)
        let keys =
          presence.list(handle, lobby)
          |> list.map(fn(entry) { entry.key })
        matrix.close(client)
        #(frames, keys)
      },
    )

  let assert [diff, snapshot] = frames
  diff.event |> should.equal("presence_diff")
  diff.payload |> string.contains("alice") |> should.be_true
  diff.payload |> string.contains("online") |> should.be_true
  snapshot.event |> should.equal("presence_list")
  // The snapshot is encoded after the track in the same action list, so it
  // already contains the key that was just tracked.
  snapshot.payload |> should.equal("[\"alice\"]")
  entries |> should.equal(["alice"])
}

// === Abuse controls ========================================================

pub fn the_join_rate_limiter_answers_identically_test() {
  let reply =
    matrix.compare_with(
      config: fn() {
        matrix.default_config()
        |> beryl.with_join_rate(per_second: 1, burst: 1)
      },
      scenario: fn(system) {
        let #(client, _join) = join(system)
        matrix.send(
          client,
          matrix.join_frame("jr-2", "r-2", "room:other", json.object([])),
        )
        let assert [reply] = matrix.take_exactly(client, 1)
        matrix.close(client)
        reply
      },
    )

  reply.ref |> should.equal(Some("r-2"))
  reply.payload |> string.contains("\"status\":\"error\"") |> should.be_true
  reply.payload |> string.contains("rate_limited") |> should.be_true
}

pub fn the_topic_cap_answers_identically_test() {
  let reply =
    matrix.compare_with(
      config: fn() {
        matrix.default_config()
        |> beryl.with_max_joined_topics_per_socket(1)
      },
      scenario: fn(system) {
        let #(client, _join) = join(system)
        matrix.send(
          client,
          matrix.join_frame("jr-2", "r-2", "room:other", json.object([])),
        )
        let assert [reply] = matrix.take_exactly(client, 1)
        matrix.close(client)
        reply
      },
    )

  reply.payload |> string.contains("\"status\":\"error\"") |> should.be_true
  reply.payload |> string.contains("too_many_topics") |> should.be_true
}
