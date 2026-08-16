//// Behavioral coverage for the showcase's `beryl_channels` handler table.
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
  h.stop(system)
}

pub fn a_cursor_move_reaches_the_other_socket_only_test() {
  let system = h.start("cursor-move")
  let ada = h.connect(system, "s1")
  let bob = h.connect(system, "s2")

  h.join(system, "s1", "cursor:main", "1", "{\"username\":\"ada\"}")
  h.join(system, "s2", "cursor:main", "1", "{\"username\":\"bob\"}")
  // Both sockets settle on the roster that includes bob.
  settle_roster(ada, "bob")
  settle_roster(bob, "bob")

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
  h.stop(system)
}

pub fn an_unsupported_reaction_is_ignored_test() {
  let system = h.start("cursor-reaction")
  let ada = h.connect(system, "s1")
  let bob = h.connect(system, "s2")

  h.join(system, "s1", "cursor:main", "1", "{\"username\":\"ada\"}")
  h.join(system, "s2", "cursor:main", "1", "{\"username\":\"bob\"}")
  settle_roster(ada, "bob")
  settle_roster(bob, "bob")

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
  h.stop(system)
}

pub fn a_disconnect_republishes_the_cursor_roster_test() {
  let system = h.start("cursor-disconnect")
  let ada = h.connect(system, "s1")
  let bob = h.connect(system, "s2")

  h.join(system, "s1", "cursor:main", "1", "{\"username\":\"ada\"}")
  h.join(system, "s2", "cursor:main", "1", "{\"username\":\"bob\"}")
  settle_roster(ada, "bob")
  settle_roster(bob, "bob")

  h.disconnect(system, "s1")

  // The channel that terminated publishes a roster it is no longer in.
  let roster = h.expect(bob, ["presence_list", "bob"])
  string.contains(roster, "ada") |> should.be_false
  h.stop(system)
}

pub fn a_leave_racing_a_join_never_publishes_a_stale_roster_test() {
  let system = h.start("cursor-leave-join")
  let ada = h.connect(system, "s1")
  let bob = h.connect(system, "s2")
  let _cleo = h.connect(system, "s3")

  h.join(system, "s1", "cursor:main", "1", "{\"username\":\"ada\"}")
  h.join(system, "s2", "cursor:main", "1", "{\"username\":\"bob\"}")
  settle_roster(ada, "bob")
  settle_roster(bob, "bob")

  // A leave and a join are enqueued back to back. Both mutate the shared
  // ETS store in their runtime turns; the publisher reads the current
  // snapshot when it handles each queued notification.
  h.leave(system, "s1", "cursor:main", "1", "7")
  h.join(system, "s3", "cursor:main", "1", "{\"username\":\"cleo\"}")

  let assert Ok(final) =
    h.drain_all(bob)
    |> list.filter(string.contains(_, "presence_list"))
    |> list.last
    as "bob received a roster"

  // The roster that settles is the one that reflects both changes.
  string.contains(final, "cleo") |> should.be_true
  string.contains(final, "bob") |> should.be_true
  string.contains(final, "ada") |> should.be_false
  h.stop(system)
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
  h.stop(system)
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

  let followups = h.drain_all(frames)
  followups
  |> list.any(
    h.contains(_, ["new_msg", "ada joined the room", "\"type\":\"system\""]),
  )
  |> should.be_true
  followups
  |> list.any(h.contains(_, ["presence_list", "ada"]))
  |> should.be_true
  h.stop(system)
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
  h.stop(system)
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
  h.stop(system)
}

pub fn a_refless_chat_message_gets_no_reply_test() {
  let system = h.start("room-refless")
  let frames = h.connect(system, "s1")
  h.join(system, "s1", "room:general", "1", "{\"username\":\"ada\"}")
  h.expect(frames, ["presence_list", "ada"])

  h.push_refless(system, "s1", "room:general", "new_msg", "{\"text\":\"hi\"}")

  h.expect(frames, ["new_msg", "hi"])
  h.expect_silence(frames)
  h.stop(system)
}

pub fn a_typing_indicator_reaches_the_other_members_test() {
  let system = h.start("room-typing")
  let ada = h.connect(system, "s1")
  let bob = h.connect(system, "s2")
  h.join(system, "s1", "room:general", "1", "{\"username\":\"ada\"}")
  h.join(system, "s2", "room:general", "1", "{\"username\":\"bob\"}")
  settle_roster(ada, "bob")
  settle_roster(bob, "bob")

  h.push_refless(system, "s1", "room:general", "typing", "{}")

  h.contains(h.expect(bob, ["\"typing\""]), [
    "\"username\":\"ada\"", "\"typing\":true",
  ])
  |> should.be_true
  // The sender is excluded from the indicator, but still receives the
  // session-presence snapshot its own metadata update produced.
  h.expect(ada, ["presence_list"])
  h.stop(system)
}

pub fn leaving_a_room_announces_the_departure_test() {
  let system = h.start("room-leave")
  let ada = h.connect(system, "s1")
  let bob = h.connect(system, "s2")
  h.join(system, "s1", "room:general", "1", "{\"username\":\"ada\"}")
  h.join(system, "s2", "room:general", "1", "{\"username\":\"bob\"}")
  settle_roster(ada, "bob")
  settle_roster(bob, "bob")

  h.leave(system, "s1", "room:general", "1", "7")

  let followups = h.drain_all(bob)
  followups
  |> list.any(
    h.contains(_, ["new_msg", "ada left the room", "\"type\":\"system\""]),
  )
  |> should.be_true
  let assert Ok(roster) =
    followups
    |> list.filter(h.contains(_, ["presence_list", "bob"]))
    |> list.last
    as "the post-leave roster was published"
  string.contains(roster, "ada") |> should.be_false

  // The leaver's own topic is closed.
  h.expect(ada, ["phx_close", "room:general"])
  h.stop(system)
}

/// `[1, 2, ..., count]`.
fn seats(count: Int) -> List(Int) {
  case count {
    0 -> []
    _ -> list.append(seats(count - 1), [count])
  }
}

pub fn a_full_room_rejects_the_next_join_test() {
  let system = h.start("room-capacity")

  // Twenty joins enqueued back to back, then the twenty-first — nothing
  // is read in between, so every join turn runs before the next one is
  // routed. The capacity check and the presence track that satisfies it
  // are part of the same accept, so the cap holds without a settling
  // delay.
  list.each(seats(20), fn(index) {
    let socket_id = "s" <> int.to_string(index)
    let _frames = h.connect(system, socket_id)
    h.join(
      system,
      socket_id,
      "room:general",
      "1",
      "{\"username\":\"user" <> int.to_string(index) <> "\"}",
    )
  })

  let overflow = h.connect(system, "s21")
  h.join(system, "s21", "room:general", "1", "{\"username\":\"late\"}")

  h.contains(h.recv(overflow), [
    "phx_reply", "\"status\":\"error\"", "\"code\":403", "Room is full (max 20)",
  ])
  |> should.be_true
  h.stop(system)
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
  h.stop(system)
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
  h.stop(system)
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
  h.stop(system)
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
  h.stop(system)
}

pub fn a_document_topic_with_the_wrong_shape_is_rejected_by_the_channel_test() {
  let system = h.start("docs-wrong-shape")
  let frames = h.connect(system, "s1")

  // The channel claims the whole `document:` prefix, as the old app-side
  // router did, so a wrong-shaped topic is answered by the document
  // channel with `invalid_topic` rather than left unowned.
  h.join(system, "s1", "document:welcome", "1", "{}")

  h.contains(h.recv(frames), [
    "phx_reply", "\"status\":\"error\"", "invalid_topic",
  ])
  |> should.be_true
  h.stop(system)
}

// ---------------------------------------------------------------------------
// Lobby and unowned topics
// ---------------------------------------------------------------------------

pub fn the_read_only_lobby_receives_room_change_announcements_test() {
  let system = h.start("lobby")
  let lobby = h.connect(system, "lobby-socket")
  h.join(system, "lobby-socket", "lobby", "1", "{}")
  h.contains(h.recv(lobby), ["phx_reply", "\"status\":\"ok\"", "lobby"])
  |> should.be_true

  let _room = h.connect(system, "room-socket")
  h.join(system, "room-socket", "room:general", "1", "{\"username\":\"ada\"}")

  h.expect(lobby, ["rooms_changed", "\"room\":\"general\""])
  h.stop(system)
}

pub fn a_topic_no_channel_owns_is_refused_test() {
  let system = h.start("unowned")
  let frames = h.connect(system, "s1")

  h.join(system, "s1", "other", "1", "{}")

  h.contains(h.recv(frames), ["phx_reply", "\"status\":\"error\"", "unmatched"])
  |> should.be_true
  h.stop(system)
}

fn settle_roster(frames: h.Frames, username: String) -> Nil {
  h.drain_all(frames)
  |> list.any(h.contains(_, ["presence_list", username]))
  |> should.be_true
}
