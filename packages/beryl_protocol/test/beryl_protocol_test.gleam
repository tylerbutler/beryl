import beryl_protocol as protocol
import gleam/dynamic
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

fn initial() -> protocol.State {
  let assert Ok(state) = protocol.new(protocol.config(), "connection-1", 0)
  state
}

fn apply(
  state: protocol.State,
  input: protocol.Input,
  now: Int,
) -> #(protocol.State, List(protocol.Action)) {
  let assert Ok(#(state, actions)) = protocol.step(state, input, now)
  #(
    state,
    list.filter(actions, fn(action) {
      case action {
        protocol.Deadline(_) -> False
        protocol.DeliverJoin(..)
        | protocol.AdmitJoin(..)
        | protocol.Joined(..)
        | protocol.DeliverMessage(..)
        | protocol.CloseChannel(..)
        | protocol.Send(_)
        | protocol.CloseConnection(_) -> True
      }
    }),
  )
}

fn request_join(
  state: protocol.State,
  topic: String,
  join_ref: String,
) -> #(protocol.State, protocol.Channel, protocol.Operation) {
  let #(state, actions) =
    apply(
      state,
      protocol.Receive(protocol.Join(
        topic,
        dynamic.nil(),
        Some(join_ref),
        Some("join"),
      )),
      0,
    )
  let assert [protocol.DeliverJoin(channel, operation, _, _)] = actions
  #(state, channel, operation)
}

fn join(
  state: protocol.State,
  topic: String,
  join_ref: String,
  mode: protocol.CloseMode,
) -> #(protocol.State, protocol.Channel) {
  let #(state, channel, operation) = request_join(state, topic, join_ref)
  let assert #(state, [protocol.AdmitJoin(..)]) =
    apply(state, protocol.AcceptJoin(operation, json.object([]), mode), 0)
  let assert #(
    state,
    [
      protocol.Joined(..),
      protocol.Send(protocol.ReplyMessage(_, _, _, protocol.StatusOk, _)),
    ],
  ) = apply(state, protocol.AdmissionFinished(operation, True), 0)
  #(state, channel)
}

fn request(
  state: protocol.State,
  topic: String,
  ref: String,
) -> #(protocol.State, protocol.Operation) {
  let #(state, actions) =
    apply(
      state,
      protocol.Receive(protocol.Message(
        topic,
        "command",
        dynamic.nil(),
        None,
        Some(ref),
      )),
      0,
    )
  let assert [protocol.DeliverMessage(_, _, _, _, Some(operation))] = actions
  #(state, operation)
}

pub fn validation_preserves_public_scope_and_utf8_byte_limits_test() -> Nil {
  protocol.validate_topic("") |> should.equal(Error(protocol.EmptyTopic))
  protocol.validate_topic(":room") |> should.be_error
  protocol.validate_topic("room:") |> should.be_error
  protocol.validate_topic("room:\n") |> should.be_error
  protocol.validate_topic("room:\u{007f}") |> should.be_error
  protocol.validate_pattern("*") |> should.equal(Ok("*"))
  protocol.validate_event("phx_join") |> should.equal(Ok("phx_join"))
  protocol.valid_event(protocol.config(), "phx_join") |> should.be_false
  let assert Ok(config) =
    protocol.with_limits(
      protocol.config(),
      max_topic_bytes: 3,
      max_event_bytes: 3,
      max_channels: 2,
      max_pending: 2,
      heartbeat_timeout_ms: 10,
    )
  protocol.valid_topic(config, "éé") |> should.be_false
  protocol.valid_topic(config, "éa") |> should.be_true
  protocol.valid_event(config, "éé") |> should.be_false
}

pub fn invalid_and_reserved_joins_reply_without_app_delivery_test() -> Nil {
  list.each(["", ":room", "beryl:system"], fn(topic) {
    let #(state, actions) =
      apply(
        initial(),
        protocol.Receive(protocol.Join(topic, dynamic.nil(), None, Some("1"))),
        0,
      )
    let assert [
      protocol.Send(protocol.ReplyMessage(
        _,
        Some("1"),
        _,
        protocol.StatusError,
        payload,
      )),
    ] = actions
    json.to_string(payload) |> should.equal("{\"reason\":\"invalid_topic\"}")
    protocol.pending_count(state) |> should.equal(0)
  })
}

pub fn join_authorization_admission_and_push_order_test() -> Nil {
  let #(state, channel, operation) = request_join(initial(), "room:a", "j1")
  let assert #(state, []) =
    apply(state, protocol.Push(channel, "early", json.null()), 0)
  let assert #(state, [protocol.AdmitJoin(..)]) =
    apply(
      state,
      protocol.AcceptJoin(
        operation,
        json.object([]),
        protocol.InvalidateImmediately,
      ),
      0,
    )
  protocol.channel(state, "room:a") |> should.be_error
  let assert #(state, []) =
    apply(state, protocol.CallbackFinished(operation), 0)
  let #(state, actions) =
    apply(state, protocol.AdmissionFinished(operation, True), 0)
  let assert [
    protocol.Joined(..),
    protocol.Send(protocol.ReplyMessage(
      Some("j1"),
      Some("join"),
      "room:a",
      protocol.StatusOk,
      _,
    )),
  ] = actions
  let assert #(_, [protocol.Send(protocol.PushMessage("room:a", "ready", _))]) =
    apply(state, protocol.Push(channel, "ready", json.null()), 0)
  protocol.pending_count(state) |> should.equal(0)
}

pub fn unanswered_join_rejects_at_callback_turn_end_test() -> Nil {
  let #(state, _, operation) = request_join(initial(), "room:a", "j1")
  let #(state, actions) = apply(state, protocol.CallbackFinished(operation), 0)
  let assert [
    protocol.Send(protocol.ReplyMessage(_, _, _, protocol.StatusError, payload)),
  ] = actions
  json.to_string(payload)
  |> should.equal("{\"reason\":\"join not acknowledged\"}")
  protocol.pending_count(state) |> should.equal(0)
  let assert #(_, []) =
    apply(
      state,
      protocol.AcceptJoin(
        operation,
        json.null(),
        protocol.InvalidateImmediately,
      ),
      0,
    )
  Nil
}

pub fn rejected_join_and_late_decision_cannot_answer_retry_test() -> Nil {
  let #(state, old_channel, old) = request_join(initial(), "room:a", "same")
  let #(state, _) = apply(state, protocol.RejectJoin(old, json.null()), 0)
  let #(state, current_channel, current) = request_join(state, "room:a", "same")
  { old_channel == current_channel } |> should.be_false
  let assert #(state, []) =
    apply(
      state,
      protocol.AcceptJoin(old, json.null(), protocol.InvalidateImmediately),
      0,
    )
  let assert #(state, [protocol.AdmitJoin(_, operation, _)]) =
    apply(
      state,
      protocol.AcceptJoin(current, json.null(), protocol.InvalidateImmediately),
      0,
    )
  operation |> should.equal(current)
  protocol.pending_count(state) |> should.equal(1)
}

pub fn duplicate_join_waits_for_normal_cleanup_and_new_generation_test() -> Nil {
  let #(state, old) =
    join(initial(), "room:a", "same", protocol.InvalidateImmediately)
  let #(state, actions) =
    apply(
      state,
      protocol.Receive(protocol.Join(
        "room:a",
        dynamic.string("new"),
        Some("same"),
        Some("join"),
      )),
      0,
    )
  let assert [
    protocol.CloseChannel(channel, cleanup, "room:a", protocol.Normal),
  ] = actions
  channel |> should.equal(old)
  protocol.channel(state, "room:a") |> should.be_error
  let #(state, actions) = apply(state, protocol.CleanupFinished(cleanup), 0)
  let assert [
    protocol.Send(protocol.TerminalMessage(
      Some("same"),
      "room:a",
      protocol.Normal,
    )),
    protocol.DeliverJoin(new, _, "room:a", _),
  ] = actions
  { new == old } |> should.be_false
  let assert #(_, []) = apply(state, protocol.CleanupFinished(cleanup), 0)
  Nil
}

pub fn referenced_leave_ack_precedes_close_and_terminal_test() -> Nil {
  let #(state, _) =
    join(initial(), "room:a", "j1", protocol.InvalidateImmediately)
  let #(state, actions) =
    apply(
      state,
      protocol.Receive(protocol.Leave("room:a", None, Some("leave"))),
      0,
    )
  let assert [
    protocol.Send(protocol.ReplyMessage(
      Some("j1"),
      Some("leave"),
      _,
      protocol.StatusOk,
      _,
    )),
    protocol.CloseChannel(_, cleanup, _, _),
  ] = actions
  let assert #(_, [protocol.Send(protocol.TerminalMessage(..))]) =
    apply(state, protocol.CleanupFinished(cleanup), 0)
  Nil
}

pub fn stale_frames_drop_but_omitted_join_reference_is_accepted_test() -> Nil {
  let #(state, _) =
    join(initial(), "room:a", "current", protocol.InvalidateImmediately)
  let assert #(state, []) =
    apply(
      state,
      protocol.Receive(protocol.Leave("room:a", Some("old"), Some("leave"))),
      0,
    )
  let assert #(state, []) =
    apply(
      state,
      protocol.Receive(protocol.Message(
        "room:a",
        "command",
        dynamic.nil(),
        Some("old"),
        Some("1"),
      )),
      0,
    )
  let assert #(_, [protocol.DeliverMessage(..)]) =
    apply(
      state,
      protocol.Receive(protocol.Message(
        "room:a",
        "command",
        dynamic.nil(),
        None,
        Some("1"),
      )),
      0,
    )
  Nil
}

pub fn topicless_events_require_opt_in_and_one_membership_test() -> Nil {
  let config = protocol.with_topicless_events(protocol.config(), True)
  let assert Ok(state) = protocol.new(config, "topicless", 0)
  let #(state, _) = join(state, "room:a", "j1", protocol.InvalidateImmediately)
  let #(state, actions) =
    apply(
      state,
      protocol.Receive(protocol.Message(
        "",
        "command",
        dynamic.nil(),
        None,
        None,
      )),
      0,
    )
  let assert [protocol.DeliverMessage(_, "room:a", _, _, _)] = actions
  let #(state, _) = join(state, "room:b", "j2", protocol.InvalidateImmediately)
  let assert #(_, []) =
    apply(
      state,
      protocol.Receive(protocol.Message(
        "",
        "command",
        dynamic.nil(),
        None,
        None,
      )),
      0,
    )
  Nil
}

pub fn duplicate_effective_wire_key_and_reuse_after_reply_test() -> Nil {
  let #(state, _) =
    join(initial(), "room:a", "j1", protocol.InvalidateImmediately)
  let #(state, old) = request(state, "room:a", "same")
  let #(state, actions) =
    apply(
      state,
      protocol.Receive(protocol.Message(
        "room:a",
        "command",
        dynamic.nil(),
        Some("j1"),
        Some("same"),
      )),
      0,
    )
  let assert [
    protocol.Send(protocol.ReplyMessage(_, _, _, protocol.StatusError, payload)),
  ] = actions
  json.to_string(payload) |> should.equal("{\"reason\":\"duplicate_ref\"}")
  let assert #(state, [protocol.Send(protocol.ReplyMessage(..))]) =
    apply(state, protocol.Reply(old, protocol.StatusOk, json.null()), 0)
  let #(state, current) = request(state, "room:a", "same")
  let assert #(state, []) =
    apply(state, protocol.Reply(old, protocol.StatusOk, json.null()), 0)
  protocol.reply_pending(state, current) |> should.be_true
  protocol.pending_count(state) |> should.equal(1)
}

pub fn discarded_capability_cannot_consume_reused_reference_test() -> Nil {
  let #(state, _) =
    join(initial(), "room:a", "j1", protocol.InvalidateImmediately)
  let #(state, old) = request(state, "room:a", "same")
  let assert #(state, []) = apply(state, protocol.Discard(old), 0)
  let #(state, current) = request(state, "room:a", "same")
  let assert #(state, []) = apply(state, protocol.Discard(old), 0)
  protocol.reply_pending(state, current) |> should.be_true
  let assert #(state, []) = apply(state, protocol.Discard(current), 0)
  protocol.pending_count(state) |> should.equal(0)
}

pub fn cross_connection_operations_cannot_answer_each_other_test() -> Nil {
  let #(first, _) =
    join(initial(), "room:a", "same", protocol.InvalidateImmediately)
  let #(first, first_operation) = request(first, "room:a", "same")
  let assert Ok(second) = protocol.new(protocol.config(), "connection-2", 0)
  let #(second, _) =
    join(second, "room:a", "same", protocol.InvalidateImmediately)
  let #(second, operation) = request(second, "room:a", "same")
  let assert #(second, []) =
    apply(
      second,
      protocol.Reply(first_operation, protocol.StatusOk, json.null()),
      0,
    )
  protocol.reply_pending(second, operation) |> should.be_true
  protocol.reply_pending(first, first_operation) |> should.be_true
}

pub fn raw_closure_invalidates_before_closed_delivery_test() -> Nil {
  let #(state, channel) =
    join(initial(), "room:a", "j1", protocol.InvalidateImmediately)
  let #(state, reply) = request(state, "room:a", "request")
  let assert #(state, [protocol.CloseChannel(..)]) =
    apply(state, protocol.BeginClose(channel, protocol.Normal), 0)
  protocol.reply_pending(state, reply) |> should.be_false
  protocol.pending_count(state) |> should.equal(0)
  let assert #(state, []) =
    apply(state, protocol.Reply(reply, protocol.StatusOk, json.null()), 0)
  let assert #(_, []) =
    apply(state, protocol.Push(channel, "late", json.null()), 0)
  Nil
}

pub fn closing_worker_results_can_reply_and_push_until_drain_finishes_test() -> Nil {
  let #(state, channel) =
    join(initial(), "room:a", "j1", protocol.DrainBeforeCleanup)
  let #(state, reply) = request(state, "room:a", "request")
  let assert #(state, [protocol.CloseChannel(_, cleanup, _, _)]) =
    apply(state, protocol.BeginClose(channel, protocol.Shutdown), 0)
  let assert #(state, [protocol.Send(protocol.PushMessage(..))]) =
    apply(state, protocol.Push(channel, "computed", json.null()), 0)
  let assert #(state, [protocol.Send(protocol.ReplyMessage(..))]) =
    apply(state, protocol.Reply(reply, protocol.StatusOk, json.null()), 0)
  let assert #(state, []) =
    apply(state, protocol.DrainFinished(cleanup, protocol.Shutdown), 0)
  let assert #(state, []) =
    apply(state, protocol.Push(channel, "too_late", json.null()), 0)
  let assert #(state, [protocol.Send(protocol.TerminalMessage(..))]) =
    apply(state, protocol.CleanupFinished(cleanup), 0)
  protocol.pending_count(state) |> should.equal(0)
}

pub fn drain_failure_updates_the_terminal_reason_test() -> Nil {
  let #(state, channel) =
    join(initial(), "room:a", "j1", protocol.DrainBeforeCleanup)
  let assert #(state, [protocol.CloseChannel(_, cleanup, _, protocol.Normal)]) =
    apply(state, protocol.BeginClose(channel, protocol.Normal), 0)
  let assert #(state, []) =
    apply(
      state,
      protocol.DrainFinished(cleanup, protocol.Fault("callback failed")),
      0,
    )
  let assert #(
    _,
    [
      protocol.Send(protocol.TerminalMessage(
        Some("j1"),
        "room:a",
        protocol.Fault("callback failed"),
      )),
    ],
  ) = apply(state, protocol.CleanupFinished(cleanup), 0)
  Nil
}

pub fn pending_capacity_closes_and_cleanup_returns_ledger_to_zero_test() -> Nil {
  let assert Ok(config) =
    protocol.with_limits(protocol.config(), 256, 64, 2, 1, 60_000)
  let assert Ok(state) = protocol.new(config, "bounded", 0)
  let #(state, channel) =
    join(state, "room:a", "j1", protocol.DrainBeforeCleanup)
  let #(state, _) = request(state, "room:a", "1")
  protocol.pending_count(state) |> should.equal(1)
  let assert #(
    state,
    [
      protocol.CloseChannel(
        current,
        cleanup,
        _,
        protocol.Fault("pending_capacity"),
      ),
    ],
  ) =
    apply(
      state,
      protocol.Receive(protocol.Message(
        "room:a",
        "command",
        dynamic.nil(),
        None,
        Some("2"),
      )),
      0,
    )
  current |> should.equal(channel)
  let #(state, actions) = apply(state, protocol.CleanupFinished(cleanup), 0)
  let assert [
    protocol.Send(protocol.TerminalMessage(..)),
    protocol.CloseConnection(_),
  ] = actions
  protocol.pending_count(state) |> should.equal(0)
  protocol.next_deadline(state) |> should.equal(None)
}

pub fn heartbeat_boundary_and_application_traffic_do_not_refresh_deadline_test() -> Nil {
  let assert Ok(config) =
    protocol.with_limits(protocol.config(), 256, 64, 2, 10, 10)
  let assert Ok(state) = protocol.new(config, "heartbeat", 0)
  let #(state, _) = join(state, "room:a", "j1", protocol.InvalidateImmediately)
  let assert #(state, []) = apply(state, protocol.CheckDeadline, 10)
  let #(state, _) =
    apply(
      state,
      protocol.Receive(protocol.Message(
        "room:a",
        "work",
        dynamic.nil(),
        None,
        None,
      )),
      10,
    )
  protocol.next_deadline(state) |> should.equal(Some(11))
  let assert #(
    state,
    [protocol.Send(protocol.HeartbeatReply(Some("heartbeat")))],
  ) = apply(state, protocol.Receive(protocol.Heartbeat(Some("heartbeat"))), 10)
  protocol.next_deadline(state) |> should.equal(Some(21))
  let assert #(state, []) = apply(state, protocol.CheckDeadline, 11)
  let assert #(_, [protocol.CloseChannel(_, _, _, protocol.HeartbeatTimeout)]) =
    apply(state, protocol.CheckDeadline, 21)
  Nil
}

pub fn snapshot_round_trip_retains_membership_and_rebases_deadline_test() -> Nil {
  let #(state, original) =
    join(initial(), "room:a", "j1", protocol.InvalidateImmediately)
  let assert Ok(snapshot) = protocol.export(state, 20_000)
  let assert Ok(#(restored, [protocol.Deadline(Some(31_001))])) =
    protocol.restore(snapshot, 10_000, 1000)
  protocol.channel(restored, "room:a") |> should.equal(Ok(original))
  protocol.joined_ref(restored, "room:a") |> should.equal(Some("j1"))
  let assert Ok(second_snapshot) = protocol.export(restored, 1000)
  let assert Ok(#(twice, _)) = protocol.restore(second_snapshot, 0, 1000)
  protocol.channel(twice, "room:a") |> should.equal(Ok(original))
}

pub fn snapshot_lost_reply_forces_rejoin_and_preserves_counters_test() -> Nil {
  let #(state, original) =
    join(initial(), "room:a", "same", protocol.InvalidateImmediately)
  let #(state, old_reply) = request(state, "room:a", "same")
  let assert Ok(snapshot) = protocol.export(state, 0)
  let assert Ok(#(
    restored,
    [
      protocol.Send(protocol.TerminalMessage(
        Some("same"),
        "room:a",
        protocol.Fault("work_lost"),
      )),
      protocol.Deadline(_),
    ],
  )) = protocol.restore(snapshot, 0, 0)
  protocol.channel(restored, "room:a") |> should.be_error
  protocol.pending_count(restored) |> should.equal(0)
  let #(state, current) =
    join(restored, "room:a", "same", protocol.InvalidateImmediately)
  { original == current } |> should.be_false
  let #(state, new_reply) = request(state, "room:a", "same")
  let assert #(state, []) =
    apply(state, protocol.Reply(old_reply, protocol.StatusOk, json.null()), 0)
  protocol.reply_pending(state, new_reply) |> should.be_true
}

pub fn snapshot_lost_authorization_and_cleanup_require_rejoin_test() -> Nil {
  let #(state, _, pending) = request_join(initial(), "room:a", "j1")
  let assert Ok(snapshot) = protocol.export(state, 0)
  let assert Ok(#(restored, _)) = protocol.restore(snapshot, 0, 0)
  let assert #(_, []) =
    apply(
      restored,
      protocol.AcceptJoin(pending, json.null(), protocol.InvalidateImmediately),
      0,
    )
  let #(state, channel) =
    join(restored, "room:a", "j1", protocol.DrainBeforeCleanup)
  let assert #(state, [protocol.CloseChannel(_, cleanup, _, _)]) =
    apply(state, protocol.BeginClose(channel, protocol.Normal), 0)
  let assert Ok(snapshot) = protocol.export(state, 0)
  let assert Ok(#(restored, _)) = protocol.restore(snapshot, 0, 0)
  let assert #(_, []) = apply(restored, protocol.CleanupFinished(cleanup), 0)
  Nil
}

pub fn sleeping_past_deadline_closes_before_accepting_commands_test() -> Nil {
  let #(state, _) =
    join(initial(), "room:a", "j1", protocol.InvalidateImmediately)
  let assert Ok(snapshot) = protocol.export(state, 59_000)
  let assert Ok(#(
    state,
    [
      protocol.CloseChannel(_, cleanup, _, protocol.HeartbeatTimeout),
      protocol.Deadline(None),
    ],
  )) = protocol.restore(snapshot, 2000, 50)
  let assert #(state, []) =
    apply(
      state,
      protocol.Receive(protocol.Message(
        "room:a",
        "command",
        dynamic.nil(),
        None,
        None,
      )),
      50,
    )
  let assert #(
    _,
    [
      protocol.Send(protocol.TerminalMessage(..)),
      protocol.CloseConnection(protocol.HeartbeatTimeout),
    ],
  ) = apply(state, protocol.CleanupFinished(cleanup), 50)
  Nil
}

pub fn snapshot_rejects_unknown_versions_bad_counters_and_clock_data_test() -> Nil {
  let assert Ok(snapshot) = protocol.export(initial(), 0)
  snapshot
  |> string.replace("\"version\":1", "\"version\":2")
  |> protocol.restore(0, 0)
  |> should.equal(Error(protocol.UnsupportedVersion(2)))
  list.each(
    [
      string.replace(snapshot, "\"next_channel\":1", "\"next_channel\":0"),
      string.replace(
        snapshot,
        "\"next_operation\":1",
        "\"next_operation\":9007199254740992",
      ),
      string.replace(
        snapshot,
        "\"heartbeat_remaining_ms\":60001",
        "\"heartbeat_remaining_ms\":60002",
      ),
    ],
    fn(snapshot) { protocol.restore(snapshot, 0, 0) |> should.be_error },
  )
  protocol.restore(snapshot, -1, 0)
  |> should.equal(Error(protocol.InvalidClock))
  protocol.export(initial(), -1) |> should.equal(Error(protocol.InvalidClock))
}

pub fn snapshot_rejects_inconsistent_reply_generations_and_duplicate_keys_test() -> Nil {
  let #(state, _) = join(initial(), "room:a", "j1", protocol.DrainBeforeCleanup)
  let #(state, _) = request(state, "room:a", "1")
  let assert Ok(snapshot) = protocol.export(state, 0)
  snapshot
  |> string.replace(
    "\"replies\":[{\"generation\":1",
    "\"replies\":[{\"generation\":999",
  )
  |> protocol.restore(0, 0)
  |> should.be_error
  snapshot
  |> string.replace("\"operation\":2", "\"operation\":3")
  |> protocol.restore(0, 0)
  |> should.be_error
  Nil
}

pub fn negative_monotonic_clock_origins_are_supported_test() -> Nil {
  let assert Ok(state) =
    protocol.new(protocol.config(), "beam-clock", -1_000_000)
  protocol.next_deadline(state) |> should.equal(Some(-939_999))
  let assert Ok(snapshot) = protocol.export(state, -999_000)
  let assert Ok(#(state, _)) = protocol.restore(snapshot, 500, -2_000_000)
  protocol.next_deadline(state) |> should.equal(Some(-1_941_499))
}

pub fn failed_join_admission_closes_without_sending_a_join_reply_test() -> Nil {
  let #(state, _, operation) = request_join(initial(), "room:a", "j1")
  let assert #(state, [protocol.AdmitJoin(..)]) =
    apply(
      state,
      protocol.AcceptJoin(
        operation,
        json.null(),
        protocol.InvalidateImmediately,
      ),
      0,
    )
  let assert #(
    state,
    [protocol.CloseConnection(protocol.Fault("admission_rejected"))],
  ) = apply(state, protocol.AdmissionFinished(operation, False), 0)
  protocol.pending_count(state) |> should.equal(0)
  protocol.topics(state) |> should.equal([])
}

pub fn closed_connection_snapshot_replays_interrupted_transport_close_test() -> Nil {
  list.each(
    [
      protocol.Normal,
      protocol.Shutdown,
      protocol.HeartbeatTimeout,
      protocol.Fault("callback failed"),
    ],
    fn(reason) {
      let #(state, _) = apply(initial(), protocol.Disconnect(reason), 0)
      let assert Ok(snapshot) = protocol.export(state, 0)
      let assert Ok(#(restored, actions)) =
        protocol.restore(snapshot, 100, 1000)
      let expected = [protocol.CloseConnection(reason), protocol.Deadline(None)]
      actions |> should.equal(expected)
      protocol.close_reason(restored) |> should.equal(Some(reason))
      let assert Ok(second_snapshot) = protocol.export(restored, 1000)
      let assert Ok(#(twice, actions)) =
        protocol.restore(second_snapshot, 10, 2000)
      actions |> should.equal(expected)
      protocol.close_reason(twice) |> should.equal(Some(reason))
      let assert #(_, []) =
        apply(twice, protocol.Receive(protocol.Heartbeat(Some("late"))), 2000)
      Nil
    },
  )
}

pub fn closed_connection_snapshot_rejects_missing_or_invalid_reason_test() -> Nil {
  let #(state, _) = apply(initial(), protocol.Disconnect(protocol.Shutdown), 0)
  let assert Ok(snapshot) = protocol.export(state, 0)
  list.each(["null", "\"unknown\""], fn(closing) {
    snapshot
    |> string.replace("\"closing\":\"shutdown\"", "\"closing\":" <> closing)
    |> protocol.restore(0, 0)
    |> should.equal(Error(protocol.InvalidSnapshot))
  })
}

pub fn final_cleanup_snapshot_replays_interrupted_transport_close_test() -> Nil {
  let #(state, _) =
    join(initial(), "room:a", "j1", protocol.InvalidateImmediately)
  let assert #(state, [protocol.CloseChannel(_, cleanup, _, _)]) =
    apply(state, protocol.Disconnect(protocol.Normal), 0)
  let assert #(
    state,
    [
      protocol.Send(protocol.TerminalMessage(..)),
      protocol.CloseConnection(protocol.Normal),
    ],
  ) = apply(state, protocol.CleanupFinished(cleanup), 0)
  let assert Ok(snapshot) = protocol.export(state, 0)
  let assert Ok(#(
    _,
    [protocol.CloseConnection(protocol.Normal), protocol.Deadline(None)],
  )) = protocol.restore(snapshot, 10, 100)
  Nil
}

pub fn recovery_actions_are_topic_sorted_regardless_of_snapshot_array_order_test() -> Nil {
  let #(state, _) =
    join(initial(), "room:z", "jz", protocol.InvalidateImmediately)
  let #(state, _) = join(state, "room:a", "ja", protocol.InvalidateImmediately)
  let #(state, _) = request(state, "room:z", "1")
  let #(state, _) = request(state, "room:a", "1")
  let assert Ok(snapshot) = protocol.export(state, 0)
  let assert Ok(#(before, rest)) =
    string.split_once(snapshot, "\"memberships\":[")
  let assert Ok(#(memberships, after)) =
    string.split_once(rest, "],\"replies\"")
  let assert [first, second] = string.split(memberships, "},{")
  let reversed =
    before
    <> "\"memberships\":[{"
    <> string.drop_end(second, 1)
    <> "},{"
    <> string.drop_start(first, 1)
    <> "}],\"replies\""
    <> after
  let assert Ok(#(_, expected)) = protocol.restore(snapshot, 0, 0)
  let assert Ok(#(_, actual)) = protocol.restore(reversed, 0, 0)
  actual |> should.equal(expected)
  let assert [
    protocol.Send(protocol.TerminalMessage(_, "room:a", _)),
    protocol.Send(protocol.TerminalMessage(_, "room:z", _)),
    protocol.Deadline(_),
  ] = actual
  Nil
}

pub fn largest_safe_heartbeat_duration_round_trips_without_unsafe_integers_test() -> Nil {
  protocol.with_limits(protocol.config(), 256, 64, 2, 2, 9_007_199_254_740_991)
  |> should.equal(Error(protocol.InvalidConfig))
  let assert Ok(config) =
    protocol.with_limits(
      protocol.config(),
      256,
      64,
      2,
      2,
      9_007_199_254_740_990,
    )
  let assert Ok(state) = protocol.new(config, "maximum-timeout", -1)
  let assert Ok(snapshot) = protocol.export(state, -1)
  let assert Ok(#(restored, _)) = protocol.restore(snapshot, 0, -1)
  protocol.next_deadline(restored)
  |> should.equal(Some(9_007_199_254_740_990))
  snapshot
  |> string.replace(
    "\"heartbeat_remaining_ms\":9007199254740991",
    "\"heartbeat_remaining_ms\":9007199254740992",
  )
  |> protocol.restore(0, -1)
  |> should.be_error
  Nil
}
