//// Behavioral coverage for the showcase's `beryl/channel` handler table.
////
//// These pin the wire shapes the bundled browser clients depend on —
//// the join acknowledgments, the `presence_list` rosters, the chat
//// message/reply order, the typing indicator, and the document channel's
//// tenant-token gate — through the transport SPI, i.e. exactly the frames
//// the Playwright suite drives over a real socket.

import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import showcase_harness

// ---------------------------------------------------------------------------
// cursor:*
// ---------------------------------------------------------------------------

pub fn a_cursor_join_is_acknowledged_before_its_roster_test() -> Nil {
  let system = showcase_harness.start("cursor-join")
  let frames = showcase_harness.connect(system, "s1")

  showcase_harness.join(
    system,
    "s1",
    "cursor:main",
    "1",
    "{\"username\":\"ada\"}",
  )

  // The acknowledgment is the first frame on the wire, carrying the
  // socket's identity, name, and assigned color.
  let ack = showcase_harness.recv(frames)
  showcase_harness.contains(ack, [
    "phx_reply", "\"status\":\"ok\"", "cursor:main", "\"username\":\"ada\"",
    "\"socket_id\":\"s1\"", "\"color\":",
  ])
  |> should.be_true

  // Presence tracking and the roster follow it.
  showcase_harness.expect(frames, ["presence_list", "cursor:main", "ada"])
  showcase_harness.stop(system)
}

pub fn a_cursor_move_reaches_the_other_socket_only_test() -> Nil {
  let system = showcase_harness.start("cursor-move")
  let ada = showcase_harness.connect(system, "s1")
  let bob = showcase_harness.connect(system, "s2")

  showcase_harness.join(
    system,
    "s1",
    "cursor:main",
    "1",
    "{\"username\":\"ada\"}",
  )
  showcase_harness.join(
    system,
    "s2",
    "cursor:main",
    "1",
    "{\"username\":\"bob\"}",
  )
  // Both sockets settle on the roster that includes bob.
  settle_roster(ada, "bob")
  settle_roster(bob, "bob")

  showcase_harness.push_refless(
    system,
    "s1",
    "cursor:main",
    "cursor_move",
    "{\"x\":10,\"y\":20}",
  )

  let moved = showcase_harness.expect(bob, ["cursor_move"])
  showcase_harness.contains(moved, [
    "\"socket_id\":\"s1\"", "\"username\":\"ada\"", "\"x\":10", "\"y\":20",
  ])
  |> should.be_true
  // `broadcast_from` excludes the sender.
  showcase_harness.expect_silence(ada)
  showcase_harness.stop(system)
}

pub fn an_unsupported_reaction_is_ignored_test() -> Nil {
  let system = showcase_harness.start("cursor-reaction")
  let ada = showcase_harness.connect(system, "s1")
  let bob = showcase_harness.connect(system, "s2")

  showcase_harness.join(
    system,
    "s1",
    "cursor:main",
    "1",
    "{\"username\":\"ada\"}",
  )
  showcase_harness.join(
    system,
    "s2",
    "cursor:main",
    "1",
    "{\"username\":\"bob\"}",
  )
  settle_roster(ada, "bob")
  settle_roster(bob, "bob")

  showcase_harness.push_refless(
    system,
    "s1",
    "cursor:main",
    "reaction",
    "{\"reaction\":\"\\uD83D\\uDC80\",\"x\":0.5,\"y\":0.5}",
  )
  showcase_harness.expect_silence(bob)

  showcase_harness.push_refless(
    system,
    "s1",
    "cursor:main",
    "reaction",
    "{\"reaction\":\"\\uD83D\\uDD25\",\"x\":0.5,\"y\":0.5}",
  )
  showcase_harness.expect(bob, ["reaction", "\"x\":0.5"])
  showcase_harness.stop(system)
}

pub fn a_disconnect_republishes_the_cursor_roster_test() -> Nil {
  let system = showcase_harness.start("cursor-disconnect")
  let ada = showcase_harness.connect(system, "s1")
  let bob = showcase_harness.connect(system, "s2")

  showcase_harness.join(
    system,
    "s1",
    "cursor:main",
    "1",
    "{\"username\":\"ada\"}",
  )
  showcase_harness.join(
    system,
    "s2",
    "cursor:main",
    "1",
    "{\"username\":\"bob\"}",
  )
  settle_roster(ada, "bob")
  settle_roster(bob, "bob")

  showcase_harness.disconnect(system, "s1")

  // The channel that terminated publishes a roster it is no longer in.
  let roster = showcase_harness.expect(bob, ["presence_list", "bob"])
  string.contains(roster, "ada") |> should.be_false
  showcase_harness.stop(system)
}

pub fn a_leave_racing_a_join_never_publishes_a_stale_roster_test() -> Nil {
  let system = showcase_harness.start("cursor-leave-join")
  let ada = showcase_harness.connect(system, "s1")
  let bob = showcase_harness.connect(system, "s2")
  let _cleo = showcase_harness.connect(system, "s3")

  showcase_harness.join(
    system,
    "s1",
    "cursor:main",
    "1",
    "{\"username\":\"ada\"}",
  )
  showcase_harness.join(
    system,
    "s2",
    "cursor:main",
    "1",
    "{\"username\":\"bob\"}",
  )
  settle_roster(ada, "bob")
  settle_roster(bob, "bob")

  // A leave and a join are enqueued back to back. Both mutate the shared
  // ETS store in their runtime turns; the publisher reads the current
  // snapshot when it handles each queued notification.
  showcase_harness.leave(system, "s1", "cursor:main", "1", "7")
  showcase_harness.join(
    system,
    "s3",
    "cursor:main",
    "1",
    "{\"username\":\"cleo\"}",
  )

  let assert Ok(final) =
    showcase_harness.drain_all(bob)
    |> list.filter(string.contains(_, "presence_list"))
    |> list.last
    as "bob received a roster"

  // The roster that settles is the one that reflects both changes.
  string.contains(final, "cleo") |> should.be_true
  string.contains(final, "bob") |> should.be_true
  string.contains(final, "ada") |> should.be_false
  showcase_harness.stop(system)
}

// ---------------------------------------------------------------------------
// room:*
// ---------------------------------------------------------------------------

pub fn a_join_for_an_unknown_room_is_rejected_test() -> Nil {
  let system = showcase_harness.start("room-unknown")
  let frames = showcase_harness.connect(system, "s1")

  showcase_harness.join(
    system,
    "s1",
    "room:nope",
    "1",
    "{\"username\":\"ada\"}",
  )

  showcase_harness.contains(showcase_harness.recv(frames), [
    "phx_reply", "\"status\":\"error\"", "Room not found: nope",
  ])
  |> should.be_true
  showcase_harness.stop(system)
}

pub fn a_room_join_announces_the_member_then_the_roster_test() -> Nil {
  let system = showcase_harness.start("room-join")
  let frames = showcase_harness.connect(system, "s1")

  showcase_harness.join(
    system,
    "s1",
    "room:general",
    "1",
    "{\"username\":\"ada\"}",
  )

  showcase_harness.contains(showcase_harness.recv(frames), [
    "phx_reply", "\"status\":\"ok\"", "\"room\":\"general\"",
    "\"username\":\"ada\"",
  ])
  |> should.be_true

  let followups = showcase_harness.drain_all(frames)
  followups
  |> list.any(
    showcase_harness.contains(_, [
      "new_msg",
      "ada joined the room",
      "\"type\":\"system\"",
    ]),
  )
  |> should.be_true
  followups
  |> list.any(showcase_harness.contains(_, ["presence_list", "ada"]))
  |> should.be_true
  showcase_harness.stop(system)
}

pub fn an_empty_chat_message_is_answered_with_the_422_payload_test() -> Nil {
  let system = showcase_harness.start("room-empty-msg")
  let frames = showcase_harness.connect(system, "s1")
  showcase_harness.join(
    system,
    "s1",
    "room:general",
    "1",
    "{\"username\":\"ada\"}",
  )
  showcase_harness.expect(frames, ["presence_list", "ada"])

  showcase_harness.push(
    system,
    "s1",
    "room:general",
    "new_msg",
    "9",
    "{\"text\":\"   \"}",
  )

  // An ok-status reply carrying an error payload, exactly as before.
  showcase_harness.contains(showcase_harness.recv(frames), [
    "phx_reply", "\"status\":\"ok\"", "\"code\":422", "Message cannot be empty",
  ])
  |> should.be_true
  showcase_harness.stop(system)
}

pub fn a_chat_message_is_broadcast_before_its_reply_test() -> Nil {
  let system = showcase_harness.start("room-msg-order")
  let frames = showcase_harness.connect(system, "s1")
  showcase_harness.join(
    system,
    "s1",
    "room:general",
    "1",
    "{\"username\":\"ada\"}",
  )
  showcase_harness.expect(frames, ["presence_list", "ada"])

  showcase_harness.push(
    system,
    "s1",
    "room:general",
    "new_msg",
    "9",
    "{\"text\":\"hello\"}",
  )

  let broadcast = showcase_harness.recv(frames)
  showcase_harness.contains(broadcast, [
    "new_msg", "hello", "\"type\":\"user\"", "\"username\":\"ada\"",
  ])
  |> should.be_true

  showcase_harness.contains(showcase_harness.recv(frames), [
    "phx_reply",
    "\"status\":\"ok\"",
    "\"timestamp\":",
  ])
  |> should.be_true
  showcase_harness.stop(system)
}

pub fn a_refless_chat_message_gets_no_reply_test() -> Nil {
  let system = showcase_harness.start("room-refless")
  let frames = showcase_harness.connect(system, "s1")
  showcase_harness.join(
    system,
    "s1",
    "room:general",
    "1",
    "{\"username\":\"ada\"}",
  )
  showcase_harness.expect(frames, ["presence_list", "ada"])

  showcase_harness.push_refless(
    system,
    "s1",
    "room:general",
    "new_msg",
    "{\"text\":\"hi\"}",
  )

  showcase_harness.expect(frames, ["new_msg", "hi"])
  showcase_harness.expect_silence(frames)
  showcase_harness.stop(system)
}

pub fn a_typing_indicator_reaches_the_other_members_test() -> Nil {
  let system = showcase_harness.start("room-typing")
  let ada = showcase_harness.connect(system, "s1")
  let bob = showcase_harness.connect(system, "s2")
  showcase_harness.join(
    system,
    "s1",
    "room:general",
    "1",
    "{\"username\":\"ada\"}",
  )
  showcase_harness.join(
    system,
    "s2",
    "room:general",
    "1",
    "{\"username\":\"bob\"}",
  )
  settle_roster(ada, "bob")
  settle_roster(bob, "bob")

  showcase_harness.push_refless(system, "s1", "room:general", "typing", "{}")

  showcase_harness.contains(showcase_harness.expect(bob, ["\"typing\""]), [
    "\"username\":\"ada\"", "\"typing\":true",
  ])
  |> should.be_true
  // The sender is excluded from the indicator, but still receives the
  // session-presence snapshot its own metadata update produced.
  showcase_harness.expect(ada, ["presence_list"])
  showcase_harness.stop(system)
}

pub fn leaving_a_room_announces_the_departure_test() -> Nil {
  let system = showcase_harness.start("room-leave")
  let ada = showcase_harness.connect(system, "s1")
  let bob = showcase_harness.connect(system, "s2")
  showcase_harness.join(
    system,
    "s1",
    "room:general",
    "1",
    "{\"username\":\"ada\"}",
  )
  showcase_harness.join(
    system,
    "s2",
    "room:general",
    "1",
    "{\"username\":\"bob\"}",
  )
  settle_roster(ada, "bob")
  settle_roster(bob, "bob")

  showcase_harness.leave(system, "s1", "room:general", "1", "7")

  let followups = showcase_harness.drain_all(bob)
  followups
  |> list.any(
    showcase_harness.contains(_, [
      "new_msg",
      "ada left the room",
      "\"type\":\"system\"",
    ]),
  )
  |> should.be_true
  let assert Ok(roster) =
    followups
    |> list.filter(showcase_harness.contains(_, ["presence_list", "bob"]))
    |> list.last
    as "the post-leave roster was published"
  string.contains(roster, "ada") |> should.be_false

  // The leaver's own topic is closed.
  showcase_harness.expect(ada, ["phx_close", "room:general"])
  showcase_harness.stop(system)
}

/// `[1, 2, ..., count]`.
fn seats(count: Int) -> List(Int) {
  case count {
    0 -> []
    _ -> list.append(seats(count - 1), [count])
  }
}

pub fn a_full_room_rejects_the_next_join_test() -> Nil {
  let system = showcase_harness.start("room-capacity")

  // Twenty-one joins run concurrently across their socket actors. Their
  // relative reservation order is intentionally unspecified, but the
  // serialized tracker operation must admit exactly twenty.
  let replies =
    seats(21)
    |> list.map(fn(index) {
      let socket_id = "s" <> int.to_string(index)
      let frames = showcase_harness.connect(system, socket_id)
      showcase_harness.join(
        system,
        socket_id,
        "room:general",
        "1",
        "{\"username\":\"user" <> int.to_string(index) <> "\"}",
      )
      frames
    })
    |> list.map(showcase_harness.recv)

  replies
  |> list.filter(
    showcase_harness.contains(_, ["phx_reply", "\"status\":\"ok\""]),
  )
  |> list.length
  |> should.equal(20)
  replies
  |> list.filter(
    showcase_harness.contains(_, [
      "phx_reply", "\"status\":\"error\"", "\"code\":403",
      "Room is full (max 20)",
    ]),
  )
  |> list.length
  |> should.equal(1)
  showcase_harness.stop(system)
}

// ---------------------------------------------------------------------------
// document:*:*
// ---------------------------------------------------------------------------

pub fn a_document_join_without_a_token_is_rejected_test() -> Nil {
  let system = showcase_harness.start("docs-no-token")
  let frames = showcase_harness.connect(system, "s1")

  showcase_harness.join(system, "s1", "document:demo:welcome", "1", "{}")

  showcase_harness.contains(showcase_harness.recv(frames), [
    "phx_reply", "\"status\":\"error\"", "missing_token",
  ])
  |> should.be_true
  showcase_harness.stop(system)
}

pub fn a_document_join_with_another_tenants_token_is_rejected_test() -> Nil {
  let system = showcase_harness.start("docs-wrong-tenant")
  let frames = showcase_harness.connect(system, "s1")

  showcase_harness.join(
    system,
    "s1",
    "document:demo:welcome",
    "1",
    "{\"token\":\"" <> showcase_harness.token(system, "other") <> "\"}",
  )

  showcase_harness.contains(showcase_harness.recv(frames), [
    "phx_reply",
    "\"status\":\"error\"",
    "unauthorized",
  ])
  |> should.be_true
  showcase_harness.stop(system)
}

pub fn a_document_join_with_a_valid_token_is_accepted_test() -> Nil {
  let system = showcase_harness.start("docs-token")
  let frames = showcase_harness.connect(system, "s1")

  showcase_harness.join(
    system,
    "s1",
    "document:demo:welcome",
    "1",
    "{\"token\":\"" <> showcase_harness.token(system, "demo") <> "\"}",
  )

  showcase_harness.contains(showcase_harness.recv(frames), [
    "phx_reply", "\"status\":\"ok\"", "\"tenant\":\"demo\"",
    "\"document\":\"welcome\"", "\"state\":null",
  ])
  |> should.be_true
  showcase_harness.stop(system)
}

pub fn document_state_errors_keep_their_ok_status_replies_test() -> Nil {
  let system = showcase_harness.start("docs-state")
  let frames = showcase_harness.connect(system, "s1")
  showcase_harness.join(
    system,
    "s1",
    "document:demo:welcome",
    "1",
    "{\"token\":\"" <> showcase_harness.token(system, "demo") <> "\"}",
  )
  let _ack = showcase_harness.recv(frames)

  showcase_harness.push(
    system,
    "s1",
    "document:demo:welcome",
    "sync_state",
    "9",
    "{}",
  )
  showcase_harness.contains(showcase_harness.recv(frames), [
    "phx_reply",
    "\"status\":\"ok\"",
    "invalid_state",
  ])
  |> should.be_true

  showcase_harness.push(
    system,
    "s1",
    "document:demo:welcome",
    "sync_state",
    "10",
    "{\"state\":\"" <> string.repeat("a", 65_537) <> "\"}",
  )
  showcase_harness.contains(showcase_harness.recv(frames), [
    "phx_reply",
    "\"status\":\"ok\"",
    "state_too_large",
  ])
  |> should.be_true

  showcase_harness.push(
    system,
    "s1",
    "document:demo:welcome",
    "nope",
    "11",
    "{}",
  )
  showcase_harness.contains(showcase_harness.recv(frames), [
    "phx_reply",
    "\"status\":\"ok\"",
    "unknown_event",
  ])
  |> should.be_true
  showcase_harness.stop(system)
}

pub fn a_document_topic_with_the_wrong_shape_is_rejected_by_the_channel_test() -> Nil {
  let system = showcase_harness.start("docs-wrong-shape")
  let frames = showcase_harness.connect(system, "s1")

  // The channel claims the whole `document:` prefix, as the old app-side
  // router did, so a wrong-shaped topic is answered by the document
  // channel with `invalid_topic` rather than left unowned.
  showcase_harness.join(system, "s1", "document:welcome", "1", "{}")

  showcase_harness.contains(showcase_harness.recv(frames), [
    "phx_reply", "\"status\":\"error\"", "invalid_topic",
  ])
  |> should.be_true
  showcase_harness.stop(system)
}

// ---------------------------------------------------------------------------
// Lobby and unowned topics
// ---------------------------------------------------------------------------

pub fn the_read_only_lobby_receives_room_change_announcements_test() -> Nil {
  let system = showcase_harness.start("lobby")
  let lobby = showcase_harness.connect(system, "lobby-socket")
  showcase_harness.join(system, "lobby-socket", "lobby", "1", "{}")
  showcase_harness.contains(showcase_harness.recv(lobby), [
    "phx_reply",
    "\"status\":\"ok\"",
    "lobby",
  ])
  |> should.be_true

  let _room = showcase_harness.connect(system, "room-socket")
  showcase_harness.join(
    system,
    "room-socket",
    "room:general",
    "1",
    "{\"username\":\"ada\"}",
  )

  showcase_harness.expect(lobby, ["rooms_changed", "\"room\":\"general\""])
  showcase_harness.stop(system)
}

pub fn a_topic_no_channel_owns_is_refused_test() -> Nil {
  let system = showcase_harness.start("unowned")
  let frames = showcase_harness.connect(system, "s1")

  showcase_harness.join(system, "s1", "other", "1", "{}")

  showcase_harness.contains(showcase_harness.recv(frames), [
    "phx_reply",
    "\"status\":\"error\"",
    "unmatched",
  ])
  |> should.be_true
  showcase_harness.stop(system)
}

fn settle_roster(frames: showcase_harness.Frames, username: String) -> Nil {
  showcase_harness.drain_all(frames)
  |> list.any(showcase_harness.contains(_, ["presence_list", username]))
  |> should.be_true
}

// ---------------------------------------------------------------------------
// demo:presence:* (the documentation site's presence lab)
// ---------------------------------------------------------------------------

const lab_topic = "demo:presence:0123456789abcdef0123456789abcdef"

fn lab_join_payload(compatibility_version: Int) -> String {
  "{\"client_id\":\"11111111-1111-1111-1111-111111111111\","
  <> "\"compatibility_version\":"
  <> int.to_string(compatibility_version)
  <> ",\"name\":\"Alice\",\"color\":\"emerald\"}"
}

pub fn a_presence_lab_join_is_acknowledged_then_tracked_test() -> Nil {
  let system = showcase_harness.start("lab-join")
  let frames = showcase_harness.connect(system, "s1")

  showcase_harness.join(system, "s1", lab_topic, "1", lab_join_payload(1))

  // The acknowledgment carries the snapshot taken before this socket was
  // tracked; the socket's own join arrives as the following diff.
  let ack = showcase_harness.recv(frames)
  showcase_harness.contains(ack, [
    "phx_reply", "\"status\":\"ok\"", lab_topic, "\"compatibility_version\":1",
    "presence_state",
  ])
  |> should.be_true
  showcase_harness.expect(frames, [
    "presence_diff",
    lab_topic,
    "\"joins\"",
    "Alice",
  ])
  showcase_harness.stop(system)
}

pub fn a_presence_lab_join_with_another_version_is_rejected_test() -> Nil {
  let system = showcase_harness.start("lab-version")
  let frames = showcase_harness.connect(system, "s1")

  showcase_harness.join(system, "s1", lab_topic, "1", lab_join_payload(2))

  showcase_harness.expect(frames, [
    "phx_reply",
    "\"status\":\"error\"",
    "\"code\":409",
  ])
  showcase_harness.stop(system)
}
