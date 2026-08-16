import beryl/socket
import beryl/socket/router
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

// --- Fixtures ---
//
// The app owns its socket-wide model; the router only decides which
// namespace an input belongs to. Three namespaces: a read-only "lobby", a
// "room:*" namespace that keeps the captured room name in a Dict it manages
// itself, and an exact "room:vip" namespace registered first to pin
// first-match ordering.

type Model {
  Model(socket_id: String, topics: Dict(String, String))
}

fn init() -> Model {
  Model(socket_id: "socket-1", topics: dict.new())
}

fn join_ref(topic: String) -> socket.Ref {
  socket.make_join_ref(topic:, join_ref: Some("j1"), msg_ref: Some("m1"))
}

fn message_ref(topic: String) -> socket.Ref {
  socket.make_message_ref(topic:, join_ref: Some("j1"), msg_ref: Some("m2"))
}

fn empty_payload() -> dynamic.Dynamic {
  dynamic.properties([])
}

fn room_namespace() -> router.Namespace(Model) {
  router.namespace(
    pattern: "room:*",
    join: fn(model: Model, match: router.Match, _payload, ref) {
      case match.params {
        [room] ->
          case string.starts_with(room, "forbidden") {
            True -> #(model, [socket.RejectJoin(ref, json.object([]))])
            False -> #(
              Model(
                ..model,
                topics: dict.insert(model.topics, match.topic, room),
              ),
              [socket.AcceptJoin(ref, None)],
            )
          }
        _ -> #(model, [socket.RejectJoin(ref, json.object([]))])
      }
    },
    message: fn(model: Model, match: router.Match, event, _payload, ref) {
      case dict.get(model.topics, match.topic) {
        Ok(room) -> #(
          Model(
            ..model,
            topics: dict.insert(model.topics, match.topic, room <> ":" <> event),
          ),
          socket.reply_ok(ref, json.object([])),
        )
        Error(Nil) -> #(model, [])
      }
    },
    closed: fn(model: Model, match: router.Match, reason) {
      case dict.get(model.topics, match.topic) {
        Ok(_) -> #(
          Model(..model, topics: dict.delete(model.topics, match.topic)),
          [socket.Broadcast(match.topic, reason_event(reason), json.object([]))],
        )
        Error(Nil) -> #(model, [])
      }
    },
  )
}

fn reason_event(reason: socket.StopReason) -> String {
  case reason {
    socket.Normal -> "normal"
    socket.Shutdown -> "shutdown"
    socket.HeartbeatTimeout -> "timeout"
    socket.Errored(message) -> "errored:" <> message
  }
}

fn vip_namespace() -> router.Namespace(Model) {
  router.namespace(
    pattern: "room:vip",
    join: fn(model, _match, _payload, ref) {
      #(model, [socket.AcceptJoin(ref, Some(json.string("vip")))])
    },
    message: fn(model, _match, _event, _payload, _ref) { #(model, []) },
    closed: fn(model, _match, _reason) { #(model, []) },
  )
}

fn update(model: Model, ev: socket.Input(Nil)) -> socket.Next(Model, Nil) {
  router.route(
    [vip_namespace(), router.accept_only("lobby"), room_namespace()],
    router.unknown_topic(),
    model,
    ev,
  )
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

// --- Join / message / closed dispatch ---

pub fn join_message_closed_round_trip_test() {
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

  let assert socket.Next(
    closed,
    [socket.Broadcast("room:general", "normal", _)],
  ) = update(messaged, socket.Closed("room:general", socket.Normal))
  dict.has_key(closed.topics, "room:general") |> should.be_false
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

pub fn close_receives_each_stop_reason_test() {
  [
    #(socket.Normal, "normal"),
    #(socket.Shutdown, "shutdown"),
    #(socket.HeartbeatTimeout, "timeout"),
    #(socket.Errored("boom"), "errored:boom"),
  ]
  |> list.each(fn(reason_and_event) {
    let #(reason, expected_event) = reason_and_event
    let topic = "room:" <> expected_event
    let assert socket.Next(joined, [socket.AcceptJoin(_, None)]) =
      update(init(), socket.Join(topic, empty_payload(), join_ref(topic)))
    let assert socket.Next(closed, [socket.Broadcast(_, event, _)]) =
      update(joined, socket.Closed(topic, reason))

    event |> should.equal(expected_event)
    dict.has_key(closed.topics, topic) |> should.be_false
  })
}

// --- First-match ordering ---

pub fn first_matching_namespace_wins_test() {
  let assert socket.Next(next, [socket.AcceptJoin(_, Some(reply))]) =
    update(
      init(),
      socket.Join("room:vip", empty_payload(), join_ref("room:vip")),
    )

  json.to_string(reply) |> should.equal("\"vip\"")
  // The "room:*" namespace never saw the join.
  dict.has_key(next.topics, "room:vip") |> should.be_false
}

// --- Wildcard capture ---

pub fn prefix_wildcard_captures_suffix_test() {
  let assert socket.Next(next, _) =
    update(
      init(),
      socket.Join("room:general", empty_payload(), join_ref("room:general")),
    )

  // The model stores the captured param, not a re-split topic.
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
      closed: fn(model, _match, _reason) { #(model, []) },
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
      closed: fn(model, _match, _reason) { #(model, []) },
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
      closed: fn(model, _match, _reason) { #(model, []) },
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
