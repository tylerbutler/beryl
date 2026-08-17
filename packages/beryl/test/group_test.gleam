import beryl/group
import gleam/erlang/process
import gleam/list
import gleam/otp/static_supervisor
import gleam/set
import gleeunit/should
import test_helpers

fn assert_crashes_within(op: fn() -> Nil, timeout_ms: Int) -> Nil {
  let pid = process.spawn_unlinked(op)
  let monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })

  case process.selector_receive(selector, timeout_ms) {
    Ok(process.ProcessDown(reason: process.Normal, ..)) -> should.fail()
    Ok(process.ProcessDown(..)) -> Nil
    Ok(process.PortDown(..)) -> should.fail()
    Error(Nil) -> should.fail()
  }
}

pub fn group_start_test() {
  let #(groups, spec) = group.child_spec()
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  group.list_groups(groups) |> should.equal([])
}

pub fn group_handle_survives_supervised_restart_test() {
  let #(groups, spec) = group.child_spec()
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  let assert Ok(Nil) = group.create(groups, "before:restart")
  let assert Ok(old_pid) = process.subject_owner(group.subject(groups))

  process.kill(old_pid)
  test_helpers.wait_until(
    fn() {
      case process.subject_owner(group.subject(groups)) {
        Ok(pid) -> pid != old_pid
        Error(Nil) -> False
      }
    },
    2000,
    10,
  )

  group.list_groups(groups) |> should.equal([])
  group.create(groups, "after:restart") |> should.equal(Ok(Nil))
}

pub fn configured_call_timeout_is_used_test() {
  let config =
    group.default_config()
    |> group.with_call_timeout(20)
  let #(groups, _spec) = group.child_spec_with_config(config)

  assert_crashes_within(
    fn() {
      let _ = group.list_groups(groups)
      Nil
    },
    1000,
  )
}

pub fn group_create_and_list_test() {
  let assert Ok(groups) = group.start()

  let assert Ok(Nil) = group.create(groups, "team:eng")
  let assert Ok(Nil) = group.create(groups, "team:design")

  let names = group.list_groups(groups)
  list.length(names) |> should.equal(2)
  list.contains(names, "team:eng") |> should.be_true()
  list.contains(names, "team:design") |> should.be_true()
}

pub fn group_already_exists_test() {
  let assert Ok(groups) = group.start()

  let assert Ok(Nil) = group.create(groups, "team:eng")
  let result = group.create(groups, "team:eng")
  should.be_error(result)

  case result {
    Error(group.GroupAlreadyExists) -> Nil
    _ -> should.fail()
  }
}

pub fn group_add_topics_test() {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "team:eng")

  let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")
  let assert Ok(Nil) = group.add(groups, "team:eng", "room:backend")

  let assert Ok(topics) = group.topics(groups, "team:eng")
  set.size(topics) |> should.equal(2)
  set.contains(topics, "room:frontend") |> should.be_true()
  set.contains(topics, "room:backend") |> should.be_true()
}

pub fn group_add_duplicate_topic_is_idempotent_test() {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "team:eng")

  let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")
  let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")

  let assert Ok(topics) = group.topics(groups, "team:eng")
  set.size(topics) |> should.equal(1)
}

pub fn group_remove_topic_test() {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "team:eng")
  let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")
  let assert Ok(Nil) = group.add(groups, "team:eng", "room:backend")

  let assert Ok(Nil) = group.remove(groups, "team:eng", "room:frontend")

  let assert Ok(topics) = group.topics(groups, "team:eng")
  set.size(topics) |> should.equal(1)
  set.contains(topics, "room:backend") |> should.be_true()
}

pub fn group_not_found_test() {
  let assert Ok(groups) = group.start()

  let result = group.add(groups, "nonexistent", "room:test")
  should.be_error(result)
  case result {
    Error(group.GroupNotFound) -> Nil
    _ -> should.fail()
  }

  let result2 = group.topics(groups, "nonexistent")
  should.be_error(result2)

  let result3 = group.remove(groups, "nonexistent", "room:test")
  should.be_error(result3)
}

pub fn group_delete_test() {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "team:eng")
  let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")

  let assert Ok(Nil) = group.delete(groups, "team:eng")

  // Group gone
  group.list_groups(groups) |> should.equal([])

  // Operations on deleted group fail
  let result = group.topics(groups, "team:eng")
  should.be_error(result)
}

pub fn group_delete_nonexistent_test() {
  let assert Ok(groups) = group.start()

  let result = group.delete(groups, "nonexistent")
  should.be_error(result)
  case result {
    Error(group.GroupNotFound) -> Nil
    _ -> should.fail()
  }
}

pub fn group_empty_on_start_test() {
  let assert Ok(groups) = group.start()
  group.list_groups(groups) |> should.equal([])
}

pub fn group_new_group_has_no_topics_test() {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "team:eng")

  let assert Ok(topics) = group.topics(groups, "team:eng")
  set.size(topics) |> should.equal(0)
}
