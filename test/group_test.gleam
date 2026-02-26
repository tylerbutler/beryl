import beryl/group
import gleam/list
import gleam/set
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn group_start_test() {
  let result = group.start()
  should.be_ok(result)
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
    Error(group.AlreadyExists) -> Nil
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
    Error(group.NotFound) -> Nil
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
    Error(group.NotFound) -> Nil
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
