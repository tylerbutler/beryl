import beryl/event
import beryl/group
import beryl/presence
import chatrooms/app
import gleam/dict
import gleam/dynamic
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should

fn context() -> app.Ctx {
  let assert Ok(presence_handle) =
    presence.start(presence.default_config("chatrooms-lobby-test"))
  let assert Ok(groups) = group.start()
  let assert Ok(_) = group.create(groups, "public")
  let assert Ok(_) = group.add(groups, "public", "room:general")
  app.Ctx(presence: presence_handle, groups: groups)
}

fn lobby_ref() -> event.Ref {
  event.make_join_ref(
    topic: "lobby",
    join_ref: Some("lobby-join"),
    msg_ref: Some("lobby-ref"),
  )
}

fn room_ref(topic: String) -> event.Ref {
  event.make_join_ref(
    topic: topic,
    join_ref: Some("room-join"),
    msg_ref: Some("room-ref"),
  )
}

fn empty_payload() -> dynamic.Dynamic {
  dynamic.properties([])
}

fn connect_info() -> event.ConnectInfo(Nil) {
  event.ConnectInfo(
    socket_id: "socket-1",
    seed: event.empty_seed(),
    self: event.make_sender(fn(_message) { Nil }),
  )
}

pub fn lobby_join_is_accepted_test() {
  let #(model, effects) = app.lobby_join(lobby_ref())

  model |> should.equal(app.Lobby)
  let assert [event.AcceptJoin(_, None)] = effects
}

pub fn lobby_messages_are_ignored_test() {
  let #(model, effects) =
    app.lobby_update(app.Lobby, "refresh", empty_payload(), None)

  model |> should.equal(app.Lobby)
  effects |> should.equal([])
}

pub fn standalone_routes_lobby_join_test() {
  let #(model, _) = app.standalone_init(connect_info())
  let next =
    app.standalone_update(
      context(),
      model,
      event.Join("lobby", empty_payload(), lobby_ref()),
    )

  let assert event.Next(
    app.Standalone(socket_id: _, rooms: _, lobby: Some(app.Lobby)),
    [event.AcceptJoin(_, None)],
  ) = next
}

pub fn closing_lobby_preserves_room_models_test() {
  let room =
    app.Model(username: "Alice", color: "#abcdef", room_name: "general")
  let model =
    app.Standalone(
      socket_id: "socket-1",
      rooms: dict.from_list([#("room:general", room)]),
      lobby: Some(app.Lobby),
    )

  let next =
    app.standalone_update(context(), model, event.Closed("lobby", event.Normal))

  let assert event.Next(
    app.Standalone(socket_id: _, rooms: rooms, lobby: None),
    [],
  ) = next
  dict.has_key(rooms, "room:general") |> should.be_true
}

pub fn unrelated_topic_is_rejected_test() {
  let #(model, _) = app.standalone_init(connect_info())
  let next =
    app.standalone_update(
      context(),
      model,
      event.Join(
        "notifications:alice",
        empty_payload(),
        room_ref("notifications:alice"),
      ),
    )

  let assert event.Next(_, [event.RejectJoin(_, reason)]) = next
  json.to_string(reason)
  |> should.equal("{\"reason\":\"unknown_topic\"}")
}

pub fn accepted_room_join_invalidates_lobby_after_presence_track_test() {
  let #(joined, effects) =
    app.join(
      context(),
      "socket-1",
      "room:general",
      dynamic.properties([
        #(dynamic.string("username"), dynamic.string("Alice")),
      ]),
      room_ref("room:general"),
    )

  joined |> should.be_some
  let assert [
    event.AcceptJoin(_, _),
    event.PresenceTrack("room:general", "Alice", _),
    event.Broadcast("lobby", "rooms_changed", changed),
    event.Broadcast("room:general", "new_msg", _),
    event.BroadcastPresence("room:general", "presence_list", _),
  ] = effects
  json.to_string(changed) |> should.equal("{\"room\":\"general\"}")
}

pub fn rejected_room_join_does_not_invalidate_lobby_test() {
  let #(joined, effects) =
    app.join(
      context(),
      "socket-1",
      "room:missing",
      empty_payload(),
      room_ref("room:missing"),
    )

  joined |> should.be_none
  let assert [event.RejectJoin(_, _)] = effects
}

pub fn room_close_invalidates_lobby_after_presence_untrack_test() {
  let model =
    app.Model(username: "Alice", color: "#abcdef", room_name: "general")
  let effects = app.closed(context(), "socket-1", "room:general", model)

  let assert [
    event.PresenceUntrack("room:general", "Alice"),
    event.Broadcast("lobby", "rooms_changed", changed),
    event.Broadcast("room:general", "new_msg", _),
    event.BroadcastPresence("room:general", "presence_list", _),
  ] = effects
  json.to_string(changed) |> should.equal("{\"room\":\"general\"}")
}
