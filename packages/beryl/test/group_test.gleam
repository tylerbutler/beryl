import beryl/error
import beryl/group
import gleam/erlang/process
import gleam/list
import gleam/otp/static_supervisor
import gleam/set
import gleeunit/should
import test_helper
import unitest

@external(erlang, "beryl_test_process_ffi", "with_suspended")
fn with_suspended(pid: process.Pid, action: fn() -> value) -> value

@external(erlang, "beryl_pubsub_test_ffi", "call_target")
fn call_target(mode: String) -> process.Subject(process.Subject(Nil))

@external(erlang, "beryl_ffi", "actor_call")
fn actor_call(
  subject: process.Subject(process.Subject(Nil)),
  timeout: Int,
  request: fn(process.Subject(Nil)) -> process.Subject(Nil),
) -> Result(Nil, error.CallError)

pub fn actor_call_retains_down_reason_and_cleans_up_test() -> Nil {
  let monitors = test_helper.monitor_count(process.self())
  let messages = test_helper.mailbox_length(process.self())
  let assert Error(error.CallDown(reason)) =
    actor_call(call_target("down"), 1000, fn(reply) { reply })
  error.describe_call_error(error.CallDown(reason))
  |> should.equal(
    "actor exited: abnormal: {test_call_failure,42,<<\"original\">>}",
  )
  test_helper.monitor_count(process.self()) |> should.equal(monitors)
  test_helper.mailbox_length(process.self()) |> should.equal(messages)
  actor_call(call_target("success"), 1000, fn(reply) { reply })
  |> should.equal(Ok(Nil))
  test_helper.monitor_count(process.self()) |> should.equal(monitors)
  test_helper.mailbox_length(process.self()) |> should.equal(messages)
}

pub fn group_start_test() -> Nil {
  let #(groups, spec) = group.child_spec()
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  group.list_groups(groups) |> should.equal(Ok([]))
}

pub fn group_handle_survives_supervised_restart_test() -> Nil {
  let #(groups, spec) = group.child_spec()
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  let assert Ok(Nil) = group.create(groups, "before:restart")
  let assert Ok(old_pid) = process.subject_owner(group.subject(groups))

  process.kill(old_pid)
  test_helper.wait_until(
    fn() {
      case process.subject_owner(group.subject(groups)) {
        Ok(pid) -> pid != old_pid
        Error(Nil) -> False
      }
    },
    2000,
    10,
  )

  group.list_groups(groups) |> should.equal(Ok([]))
  group.create(groups, "after:restart") |> should.equal(Ok(Nil))
}

pub fn configured_call_timeout_is_used_test() -> Nil {
  let config =
    group.default_config()
    |> group.with_call_timeout(20)
  let #(groups, spec) = group.child_spec_with_config(config)
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  let assert Ok(owner) = process.subject_owner(group.subject(groups))

  with_suspended(owner, fn() {
    group.list_groups(groups)
    |> should.equal(Error(group.GroupCallFailed(error.CallTimedOut)))
  })
}

pub fn group_timeouts_drop_monitors_and_late_replies_test() -> Nil {
  use <- unitest.tag("serial")
  let config = group.default_config() |> group.with_call_timeout(10)
  let #(groups, spec) = group.child_spec_with_config(config)
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  let assert Ok(owner) = process.subject_owner(group.subject(groups))
  let monitors = test_helper.monitor_count(process.self())
  let messages = test_helper.mailbox_length(process.self())

  with_suspended(owner, fn() {
    list.each(list.repeat(Nil, 10), fn(_) {
      group.list_groups(groups)
      |> should.equal(Error(group.GroupCallFailed(error.CallTimedOut)))
      test_helper.monitor_count(process.self()) |> should.equal(monitors)
    })
  })
  group.list_groups(groups) |> should.equal(Ok([]))
  test_helper.monitor_count(process.self()) |> should.equal(monitors)
  test_helper.mailbox_length(process.self()) |> should.equal(messages)
}

pub fn group_create_and_list_test() -> Nil {
  let assert Ok(groups) = group.start()

  let assert Ok(Nil) = group.create(groups, "team:eng")
  let assert Ok(Nil) = group.create(groups, "team:design")

  let assert Ok(names) = group.list_groups(groups)
  list.length(names) |> should.equal(2)
  list.contains(names, "team:eng") |> should.be_true()
  list.contains(names, "team:design") |> should.be_true()
}

pub fn group_already_exists_test() -> Nil {
  let assert Ok(groups) = group.start()

  let assert Ok(Nil) = group.create(groups, "team:eng")
  group.create(groups, "team:eng")
  |> should.equal(Error(group.GroupAlreadyExists("team:eng")))
}

pub fn group_add_topics_test() -> Nil {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "team:eng")

  let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")
  let assert Ok(Nil) = group.add(groups, "team:eng", "room:backend")

  let assert Ok(topics) = group.topics(groups, "team:eng")
  set.size(topics) |> should.equal(2)
  set.contains(topics, "room:frontend") |> should.be_true()
  set.contains(topics, "room:backend") |> should.be_true()
}

pub fn group_add_duplicate_topic_is_idempotent_test() -> Nil {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "team:eng")

  let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")
  let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")

  let assert Ok(topics) = group.topics(groups, "team:eng")
  set.size(topics) |> should.equal(1)
}

pub fn group_remove_topic_test() -> Nil {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "team:eng")
  let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")
  let assert Ok(Nil) = group.add(groups, "team:eng", "room:backend")

  let assert Ok(Nil) = group.remove(groups, "team:eng", "room:frontend")

  let assert Ok(topics) = group.topics(groups, "team:eng")
  set.size(topics) |> should.equal(1)
  set.contains(topics, "room:backend") |> should.be_true()
}

pub fn group_not_found_test() -> Nil {
  let assert Ok(groups) = group.start()

  group.add(groups, "nonexistent", "room:test")
  |> should.equal(Error(group.GroupNotFound("nonexistent")))

  let result2 = group.topics(groups, "nonexistent")
  should.be_error(result2)

  let result3 = group.remove(groups, "nonexistent", "room:test")
  should.be_error(result3)
  Nil
}

pub fn group_delete_test() -> Nil {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "team:eng")
  let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")

  let assert Ok(Nil) = group.delete(groups, "team:eng")

  // Group gone
  group.list_groups(groups) |> should.equal(Ok([]))

  // Operations on deleted group fail
  let result = group.topics(groups, "team:eng")
  should.be_error(result)
  Nil
}

pub fn group_delete_nonexistent_test() -> Nil {
  let assert Ok(groups) = group.start()

  group.delete(groups, "nonexistent")
  |> should.equal(Error(group.GroupNotFound("nonexistent")))
}

pub fn group_empty_on_start_test() -> Nil {
  let assert Ok(groups) = group.start()
  group.list_groups(groups) |> should.equal(Ok([]))
}

pub fn unavailable_group_operations_return_call_errors_test() -> Nil {
  let #(groups, _spec) = group.child_spec()
  let unavailable = group.GroupCallFailed(error.CallUnavailable)
  group.list_groups(groups) |> should.equal(Error(unavailable))
  group.create(groups, "missing") |> should.equal(Error(unavailable))
  group.delete(groups, "missing") |> should.equal(Error(unavailable))
  group.add(groups, "missing", "topic") |> should.equal(Error(unavailable))
  group.remove(groups, "missing", "topic") |> should.equal(Error(unavailable))
  group.topics(groups, "missing") |> should.equal(Error(unavailable))
}

pub fn group_new_group_has_no_topics_test() -> Nil {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "team:eng")

  let assert Ok(topics) = group.topics(groups, "team:eng")
  set.size(topics) |> should.equal(0)
}
