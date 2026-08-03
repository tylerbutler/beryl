//// Behavioral coverage for the showcase's `beryl_channels` handler table.
////
//// These pin the wire shapes the bundled browser clients depend on —
//// the join acknowledgments, the `presence_list` rosters, the chat
//// message/reply order, the typing indicator, and the document channel's
//// tenant-token gate — through the transport SPI, i.e. exactly the frames
//// the Playwright suite drives over a real socket.

import gleam/string
import gleeunit/should
import showcase_harness as h

// ---------------------------------------------------------------------------
// cursor:*
// ---------------------------------------------------------------------------

pub fn a_cursor_join_is_acknowledged_before_its_roster_test() {
  let system = h.start("cursor-join")
  let frames = h.connect(system, "s1")

  h.join(system, "s1", "cursor:main", "1", "{\"username\":\"ada\"}")

  // The acknowledgment is the first frame on the wire, carrying the
  // socket's identity, name, and assigned color.
  let ack = h.recv(frames)
  h.contains(ack, [
    "phx_reply", "\"status\":\"ok\"", "cursor:main", "\"username\":\"ada\"",
    "\"socket_id\":\"s1\"", "\"color\":",
  ])
  |> should.be_true

  // Presence tracking and the roster follow it.
  h.expect(frames, ["presence_list", "cursor:main", "ada"])
}

pub fn a_cursor_move_reaches_the_other_socket_only_test() {
  let system = h.start("cursor-move")
  let ada = h.connect(system, "s1")
  let bob = h.connect(system, "s2")

  h.join(system, "s1", "cursor:main", "1", "{\"username\":\"ada\"}")
  h.join(system, "s2", "cursor:main", "1", "{\"username\":\"bob\"}")
  // Both sockets settle on the roster that includes bob.
  h.expect(ada, ["presence_list", "bob"])
  h.expect(bob, ["presence_list", "bob"])

  h.push_refless(
    system,
    "s1",
    "cursor:main",
    "cursor_move",
    "{\"x\":10,\"y\":20}",
  )

  let moved = h.expect(bob, ["cursor_move"])
  h.contains(moved, [
    "\"socket_id\":\"s1\"", "\"username\":\"ada\"", "\"x\":10", "\"y\":20",
  ])
  |> should.be_true
  // `broadcast_from` excludes the sender.
  h.expect_silence(ada)
}

pub fn an_unsupported_reaction_is_ignored_test() {
  let system = h.start("cursor-reaction")
  let ada = h.connect(system, "s1")
  let bob = h.connect(system, "s2")

  h.join(system, "s1", "cursor:main", "1", "{\"username\":\"ada\"}")
  h.join(system, "s2", "cursor:main", "1", "{\"username\":\"bob\"}")
  h.expect(ada, ["presence_list", "bob"])
  h.expect(bob, ["presence_list", "bob"])

  h.push_refless(
    system,
    "s1",
    "cursor:main",
    "reaction",
    "{\"reaction\":\"\\uD83D\\uDC80\",\"x\":0.5,\"y\":0.5}",
  )
  h.expect_silence(bob)

  h.push_refless(
    system,
    "s1",
    "cursor:main",
    "reaction",
    "{\"reaction\":\"\\uD83D\\uDD25\",\"x\":0.5,\"y\":0.5}",
  )
  h.expect(bob, ["reaction", "\"x\":0.5"])
}

pub fn a_disconnect_republishes_the_cursor_roster_test() {
  let system = h.start("cursor-disconnect")
  let ada = h.connect(system, "s1")
  let bob = h.connect(system, "s2")

  h.join(system, "s1", "cursor:main", "1", "{\"username\":\"ada\"}")
  h.join(system, "s2", "cursor:main", "1", "{\"username\":\"bob\"}")
  h.expect(ada, ["presence_list", "bob"])
  h.expect(bob, ["presence_list", "bob"])

  h.disconnect(system, "s1")

  // The channel that terminated publishes a roster it is no longer in.
  let roster = h.expect(bob, ["presence_list", "bob"])
  string.contains(roster, "ada") |> should.be_false
}

// ---------------------------------------------------------------------------
// room:*
// ---------------------------------------------------------------------------

pub fn a_join_for_an_unknown_room_is_rejected_test() {
  let system = h.start("room-unknown")
  let frames = h.connect(system, "s1")

  h.join(system, "s1", "room:nope", "1", "{\"username\":\"ada\"}")

  h.contains(h.recv(frames), [
    "phx_reply", "\"status\":\"error\"", "Room not found: nope",
  ])
  |> should.be_true
}

pub fn a_room_join_announces_the_member_then_the_roster_test() {
  let system = h.start("room-join")
  let frames = h.connect(system, "s1")

  h.join(system, "s1", "room:general", "1", "{\"username\":\"ada\"}")

  h.contains(h.recv(frames), [
    "phx_reply", "\"status\":\"ok\"", "\"room\":\"general\"",
    "\"username\":\"ada\"",
  ])
  |> should.be_true

  h.expect(frames, ["new_msg", "ada joined the room", "\"type\":\"system\""])
  h.expect(frames, ["presence_list", "ada"])
}

pub fn an_empty_chat_message_is_answered_with_the_422_payload_test() {
  let system = h.start("room-empty-msg")
  let frames = h.connect(system, "s1")
  h.join(system, "s1", "room:general", "1", "{\"username\":\"ada\"}")
  h.expect(frames, ["presence_list", "ada"])

  h.push(system, "s1", "room:general", "new_msg", "9", "{\"text\":\"   \"}")

  // An ok-status reply carrying an error payload, exactly as before.
  h.contains(h.recv(frames), [
    "phx_reply", "\"status\":\"ok\"", "\"code\":422", "Message cannot be empty",
  ])
  |> should.be_true
}

pub fn a_chat_message_is_broadcast_before_its_reply_test() {
  let system = h.start("room-msg-order")
  let frames = h.connect(system, "s1")
  h.join(system, "s1", "room:general", "1", "{\"username\":\"ada\"}")
  h.expect(frames, ["presence_list", "ada"])

  h.push(system, "s1", "room:general", "new_msg", "9", "{\"text\":\"hello\"}")

  let broadcast = h.recv(frames)
  h.contains(broadcast, [
    "new_msg", "hello", "\"type\":\"user\"", "\"username\":\"ada\"",
  ])
  |> should.be_true

  h.contains(h.recv(frames), [
    "phx_reply",
    "\"status\":\"ok\"",
    "\"timestamp\":",
  ])
  |> should.be_true
}

pub fn a_refless_chat_message_gets_no_reply_test() {
  let system = h.start("room-refless")
  let frames = h.connect(system, "s1")
  h.join(system, "s1", "room:general", "1", "{\"username\":\"ada\"}")
  h.expect(frames, ["presence_list", "ada"])

  h.push_refless(system, "s1", "room:general", "new_msg", "{\"text\":\"hi\"}")

  h.expect(frames, ["new_msg", "hi"])
  h.expect_silence(frames)
}

pub fn a_typing_indicator_reaches_the_other_members_test() {
  let system = h.start("room-typing")
  let ada = h.connect(system, "s1")
  let bob = h.connect(system, "s2")
  h.join(system, "s1", "room:general", "1", "{\"username\":\"ada\"}")
  h.join(system, "s2", "room:general", "1", "{\"username\":\"bob\"}")
  h.expect(ada, ["presence_list", "bob"])
  h.expect(bob, ["presence_list", "bob"])

  h.push_refless(system, "s1", "room:general", "typing", "{}")

  h.contains(h.expect(bob, ["\"typing\""]), [
    "\"username\":\"ada\"", "\"typing\":true",
  ])
  |> should.be_true
  // The sender is excluded from the indicator, but not from the presence
  // update its own re-track produced.
  h.expect(ada, ["presence_diff"])
}

pub fn leaving_a_room_announces_the_departure_test() {
  let system = h.start("room-leave")
  let ada = h.connect(system, "s1")
  let bob = h.connect(system, "s2")
  h.join(system, "s1", "room:general", "1", "{\"username\":\"ada\"}")
  h.join(system, "s2", "room:general", "1", "{\"username\":\"bob\"}")
  h.expect(ada, ["presence_list", "bob"])
  h.expect(bob, ["presence_list", "bob"])

  h.leave(system, "s1", "room:general", "1", "7")

  h.expect(bob, ["new_msg", "ada left the room", "\"type\":\"system\""])
  let roster = h.expect(bob, ["presence_list", "bob"])
  string.contains(roster, "ada") |> should.be_false

  // The leaver's own topic is closed.
  h.expect(ada, ["phx_close", "room:general"])
}

// ---------------------------------------------------------------------------
// document:*:*
// ---------------------------------------------------------------------------

pub fn a_document_join_without_a_token_is_rejected_test() {
  let system = h.start("docs-no-token")
  let frames = h.connect(system, "s1")

  h.join(system, "s1", "document:demo:welcome", "1", "{}")

  h.contains(h.recv(frames), [
    "phx_reply", "\"status\":\"error\"", "missing_token",
  ])
  |> should.be_true
}

pub fn a_document_join_with_another_tenants_token_is_rejected_test() {
  let system = h.start("docs-wrong-tenant")
  let frames = h.connect(system, "s1")

  h.join(
    system,
    "s1",
    "document:demo:welcome",
    "1",
    "{\"token\":\"" <> h.token(system, "other") <> "\"}",
  )

  h.contains(h.recv(frames), [
    "phx_reply",
    "\"status\":\"error\"",
    "unauthorized",
  ])
  |> should.be_true
}

pub fn a_document_join_with_a_valid_token_is_accepted_test() {
  let system = h.start("docs-token")
  let frames = h.connect(system, "s1")

  h.join(
    system,
    "s1",
    "document:demo:welcome",
    "1",
    "{\"token\":\"" <> h.token(system, "demo") <> "\"}",
  )

  h.contains(h.recv(frames), [
    "phx_reply", "\"status\":\"ok\"", "\"tenant\":\"demo\"",
    "\"document\":\"welcome\"", "\"state\":null",
  ])
  |> should.be_true
}

pub fn document_state_errors_keep_their_ok_status_replies_test() {
  let system = h.start("docs-state")
  let frames = h.connect(system, "s1")
  h.join(
    system,
    "s1",
    "document:demo:welcome",
    "1",
    "{\"token\":\"" <> h.token(system, "demo") <> "\"}",
  )
  let _ack = h.recv(frames)

  h.push(system, "s1", "document:demo:welcome", "sync_state", "9", "{}")
  h.contains(h.recv(frames), ["phx_reply", "\"status\":\"ok\"", "invalid_state"])
  |> should.be_true

  h.push(
    system,
    "s1",
    "document:demo:welcome",
    "sync_state",
    "10",
    "{\"state\":\"" <> string.repeat("a", 65_537) <> "\"}",
  )
  h.contains(h.recv(frames), [
    "phx_reply",
    "\"status\":\"ok\"",
    "state_too_large",
  ])
  |> should.be_true

  h.push(system, "s1", "document:demo:welcome", "nope", "11", "{}")
  h.contains(h.recv(frames), ["phx_reply", "\"status\":\"ok\"", "unknown_event"])
  |> should.be_true
}

// ---------------------------------------------------------------------------
// Unowned topics
// ---------------------------------------------------------------------------

pub fn a_topic_no_channel_owns_is_refused_test() {
  let system = h.start("unowned")
  let frames = h.connect(system, "s1")

  h.join(system, "s1", "lobby", "1", "{}")

  h.contains(h.recv(frames), ["phx_reply", "\"status\":\"error\"", "unmatched"])
  |> should.be_true
}
