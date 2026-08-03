import beryl/socket
import beryl/socket/router
import gleam/dict
import gleam/dynamic
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should

// --- Fixtures ---
//
// A standalone-shaped app with three namespaces: a read-only "lobby", a
// stateful "room:*" namespace whose sub-model records the captured room
// name, and an exact "room:vip" namespace registered first to pin
// first-match ordering.

fn join_ref(topic: String) -> socket.Ref {
  socket.make_join_ref(topic:, join_ref: Some("j1"), msg_ref: Some("m1"))
}

fn message_ref(topic: String) -> socket.Ref {
  socket.make_message_ref(topic:, join_ref: Some("j1"), msg_ref: Some("m2"))
}

fn empty_payload() -> dynamic.Dynamic {
  dynamic.properties([])
}

fn connect_info() -> socket.ConnectInfo(Nil) {
  socket.ConnectInfo(
    socket_id: "socket-1",
    seed: socket.empty_seed(),
    self: socket.make_sender(fn(_message) { Nil }),
  )
}

fn room_namespace() -> router.Namespace(router.Standalone(String)) {
  router.standalone_namespace(fn(socket_id, get, put) {
    router.stateful(
      pattern: "room:*",
      socket_id:,
      get:,
      put:,
      join: fn(_socket_id, match: router.Match, _payload, ref) {
        case match.params {
          ["forbidden"] -> #(None, [
            socket.RejectJoin(ref, json.object([])),
          ])
          [room] -> #(Some(room), [socket.AcceptJoin(ref, None)])
          _ -> #(None, [socket.RejectJoin(ref, json.object([]))])
        }
      },
      message: fn(_socket_id, _match, room, event, _payload, ref) {
        #(room <> ":" <> event, socket.reply_ok(ref, json.object([])))
      },
      closed: fn(_socket_id, match, _room) {
        [socket.Broadcast(match.topic, "left", json.object([]))]
      },
    )
  })
}

fn vip_namespace() -> router.Namespace(router.Standalone(String)) {
  router.namespace(
    pattern: "room:vip",
    join: fn(model, _match, _payload, ref) {
      #(model, [socket.AcceptJoin(ref, Some(json.string("vip")))])
    },
    message: fn(model, _match, _event, _payload, _ref) { #(model, []) },
    closed: fn(model, _match) { #(model, []) },
  )
}

fn update(
  model: router.Standalone(String),
  ev: socket.Input(Nil),
) -> socket.Next(router.Standalone(String), Nil) {
  router.route(
    [vip_namespace(), router.accept_only("lobby"), room_namespace()],
    router.unknown_topic(),
    model,
    ev,
  )
}

fn init() -> router.Standalone(String) {
  let #(model, effects) = router.standalone_init(connect_info())
  effects |> should.equal([])
  model.socket_id |> should.equal("socket-1")
  model
}

// --- Fail-closed routing ---

pub fn unknown_topic_join_is_rejected_test() {
  let assert socket.Next(_, [socket.RejectJoin(_, reason)]) =
    update(
      init(),
      socket.Join("unknown:1", empty_payload(), join_ref("unknown:1")),
    )

  json.to_string(reason) |> should.equal("{\"reason\":\"unknown_topic\"}")
}

pub fn unclaimed_message_is_ignored_test() {
  let model = init()
  let assert socket.Next(next, []) =
    update(model, socket.Message("unknown:1", "ping", empty_payload(), None))

  next |> should.equal(model)
}

pub fn unclaimed_closed_is_ignored_test() {
  let model = init()
  let assert socket.Next(next, []) =
    update(model, socket.Closed("unknown:1", socket.Normal))

  next |> should.equal(model)
}

pub fn binary_and_info_pass_through_test() {
  let model = init()
  let assert socket.Next(next, []) =
    update(model, socket.Binary("room:lobby", <<1, 2>>))
  next |> should.equal(model)

  let assert socket.Next(next, []) = update(model, socket.Info(Nil))
  next |> should.equal(model)
}

// --- accept_only ---

pub fn accept_only_accepts_join_without_state_test() {
  let model = init()
  let assert socket.Next(next, [socket.AcceptJoin(_, None)]) =
    update(model, socket.Join("lobby", empty_payload(), join_ref("lobby")))

  next |> should.equal(model)
}

pub fn accept_only_ignores_messages_test() {
  let model = init()
  let assert socket.Next(next, []) =
    update(model, socket.Message("lobby", "refresh", empty_payload(), None))

  next |> should.equal(model)
}

// --- Stateful dict projection ---

pub fn stateful_join_message_closed_round_trip_test() {
  let assert socket.Next(joined, [socket.AcceptJoin(_, None)]) =
    update(
      init(),
      socket.Join("room:general", empty_payload(), join_ref("room:general")),
    )
  dict.get(joined.topics, "room:general") |> should.equal(Ok("general"))

  let assert socket.Next(messaged, [socket.ReplyOk(_, _)]) =
    update(
      joined,
      socket.Message(
        "room:general",
        "rename",
        empty_payload(),
        Some(message_ref("room:general")),
      ),
    )
  dict.get(messaged.topics, "room:general")
  |> should.equal(Ok("general:rename"))

  let assert socket.Next(closed, [socket.Broadcast("room:general", "left", _)]) =
    update(messaged, socket.Closed("room:general", socket.Normal))
  dict.has_key(closed.topics, "room:general") |> should.be_false
}

pub fn rejected_join_leaves_no_state_test() {
  let assert socket.Next(next, [socket.RejectJoin(_, _)]) =
    update(
      init(),
      socket.Join("room:forbidden", empty_payload(), join_ref("room:forbidden")),
    )

  dict.has_key(next.topics, "room:forbidden") |> should.be_false
}

pub fn message_for_unjoined_claimed_topic_is_ignored_test() {
  let model = init()
  let assert socket.Next(next, []) =
    update(
      model,
      socket.Message("room:general", "rename", empty_payload(), None),
    )

  next |> should.equal(model)
}

pub fn closed_for_unjoined_claimed_topic_is_ignored_test() {
  let model = init()
  let assert socket.Next(next, []) =
    update(model, socket.Closed("room:general", socket.Normal))

  next |> should.equal(model)
}

// --- First-match ordering ---

pub fn first_matching_namespace_wins_test() {
  let assert socket.Next(next, [socket.AcceptJoin(_, Some(reply))]) =
    update(
      init(),
      socket.Join("room:vip", empty_payload(), join_ref("room:vip")),
    )

  json.to_string(reply) |> should.equal("\"vip\"")
  // The stateful "room:*" namespace never saw the join.
  dict.has_key(next.topics, "room:vip") |> should.be_false
}

// --- Wildcard capture ---

pub fn prefix_wildcard_captures_suffix_test() {
  let assert socket.Next(next, _) =
    update(
      init(),
      socket.Join("room:general", empty_payload(), join_ref("room:general")),
    )

  // The sub-model stores the captured param, not a re-split topic.
  dict.get(next.topics, "room:general") |> should.equal(Ok("general"))
}

pub fn segment_wildcards_capture_each_segment_test() {
  let captured =
    router.namespace(
      pattern: "document:*:*",
      join: fn(_model, match: router.Match, _payload, ref) {
        #(match.params, [socket.AcceptJoin(ref, None)])
      },
      message: fn(model, _match, _event, _payload, _ref) { #(model, []) },
      closed: fn(model, _match) { #(model, []) },
    )

  let topic = "document:acme:readme"
  let assert socket.Next(params, [socket.AcceptJoin(_, None)]) =
    router.route(
      [captured],
      router.unknown_topic(),
      [],
      socket.Join(topic, empty_payload(), join_ref(topic)),
    )

  params |> should.equal(["acme", "readme"])
}

pub fn segment_wildcard_rejects_wrong_segment_count_test() {
  let captured =
    router.namespace(
      pattern: "document:*:*",
      join: fn(model, _match, _payload, ref) {
        #(model, [socket.AcceptJoin(ref, None)])
      },
      message: fn(model, _match, _event, _payload, _ref) { #(model, []) },
      closed: fn(model, _match) { #(model, []) },
    )

  let assert socket.Next(_, [socket.RejectJoin(_, reason)]) =
    router.route(
      [captured],
      router.unknown_topic(),
      [],
      socket.Join("document:acme", empty_payload(), join_ref("document:acme")),
    )

  json.to_string(reason) |> should.equal("{\"reason\":\"unknown_topic\"}")
}

pub fn exact_pattern_captures_nothing_test() {
  let captured =
    router.namespace(
      pattern: "lobby",
      join: fn(_model, match: router.Match, _payload, ref) {
        #(match.params, [socket.AcceptJoin(ref, None)])
      },
      message: fn(model, _match, _event, _payload, _ref) { #(model, []) },
      closed: fn(model, _match) { #(model, []) },
    )

  let assert socket.Next(params, [socket.AcceptJoin(_, None)]) =
    router.route(
      [captured],
      router.unknown_topic(),
      ["untouched"],
      socket.Join("lobby", empty_payload(), join_ref("lobby")),
    )

  params |> should.equal([])
}

// --- reply_ok ---

pub fn reply_ok_with_ref_replies_test() {
  let ref = message_ref("room:general")
  let payload = json.object([#("status", json.string("ok"))])

  socket.reply_ok(Some(ref), payload)
  |> should.equal([socket.ReplyOk(ref, payload)])
}

pub fn reply_ok_without_ref_is_silent_test() {
  socket.reply_ok(None, json.object([])) |> should.equal([])
}
