import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import heirloom

@external(erlang, "heirloom_test_ffi", "send_transfer")
fn send_transfer(
  table: heirloom.Table(key, value),
  previous_owner: process.Pid,
  data: data,
) -> Nil

@external(erlang, "heirloom_test_ffi", "send_invalid_table_transfer")
fn send_invalid_table_transfer(previous_owner: process.Pid, data: data) -> Nil

fn table(name: String) -> heirloom.Table(String, String) {
  let assert Ok(table) = heirloom.create(heirloom.spec(name, heirloom.Set))
  table
}

pub fn heirloom_creates_each_table_type_test() -> Nil {
  [
    heirloom.Set,
    heirloom.OrderedSet,
    heirloom.Bag,
    heirloom.DuplicateBag,
  ]
  |> list.index_map(fn(table_type, index) {
    let assert Ok(table): Result(heirloom.Table(String, String), _) =
      heirloom.create(heirloom.spec(
        "heirloom_type_" <> string.inspect(index),
        table_type,
      ))
    heirloom.delete(table) |> should.equal(Ok(Nil))
  })
  Nil
}

pub fn heirloom_supports_access_and_data_operations_test() -> Nil {
  let table =
    heirloom.spec("heirloom_data", heirloom.Set)
    |> heirloom.with_access(heirloom.Public)
    |> heirloom.with_read_concurrency(True)
    |> heirloom.with_write_concurrency(True)
    |> heirloom.create
  let assert Ok(table): Result(heirloom.Table(String, String), _) = table

  heirloom.lookup(table, "missing") |> should.equal(Ok(None))
  heirloom.insert(table, "key", "first") |> should.equal(Ok(Nil))
  heirloom.insert(table, "key", "second") |> should.equal(Ok(Nil))
  heirloom.lookup(table, "key") |> should.equal(Ok(Some("second")))
  heirloom.delete(table) |> should.equal(Ok(Nil))
  heirloom.lookup(table, "key")
  |> should.equal(Error(heirloom.TableDoesNotExist))
}

pub fn heirloom_supports_private_access_and_no_heir_test() -> Nil {
  let specification =
    heirloom.spec("heirloom_private", heirloom.Set)
    |> heirloom.with_access(heirloom.Private)
    |> heirloom.without_heir
  let assert Ok(table): Result(heirloom.Table(String, String), _) =
    heirloom.create(specification)
  heirloom.heir(table) |> should.equal(Ok(None))
  heirloom.delete(table) |> should.equal(Ok(Nil))
}

pub fn heirloom_rejects_duplicate_named_table_test() -> Nil {
  let specification =
    heirloom.spec("heirloom_named_duplicate", heirloom.Set)
    |> heirloom.with_named_table
  let assert Ok(first): Result(heirloom.Table(String, String), _) =
    heirloom.create(specification)
  heirloom.create(specification)
  |> should.equal(Error(heirloom.TableAlreadyExists))
  heirloom.delete(first) |> should.equal(Ok(Nil))
}

pub fn heirloom_reports_access_denied_test() -> Nil {
  let table = table("heirloom_access_denied")
  let outcome = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      process.send(outcome, heirloom.insert(table, "key", "value"))
    })
  let monitor = process.monitor(worker)

  process.receive(outcome, 500)
  |> should.equal(Ok(Error(heirloom.AccessDenied)))
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(500)
  heirloom.delete(table) |> should.equal(Ok(Nil))
}

pub fn heirloom_configures_and_clears_heir_test() -> Nil {
  let first = process.spawn_unlinked(fn() { process.sleep(1000) })
  let second = process.spawn_unlinked(fn() { process.sleep(1000) })
  let specification =
    heirloom.spec("heirloom_heir", heirloom.Set)
    |> heirloom.with_heir(first, #("structured", 1))
  let assert Ok(table): Result(heirloom.Table(String, String), _) =
    heirloom.create(specification)

  heirloom.heir(table) |> should.equal(Ok(Some(first)))
  heirloom.set_heir(table, second, #("replacement", 2))
  |> should.equal(Ok(Nil))
  heirloom.heir(table) |> should.equal(Ok(Some(second)))
  heirloom.clear_heir(table) |> should.equal(Ok(Nil))
  heirloom.heir(table) |> should.equal(Ok(None))
  heirloom.delete(table) |> should.equal(Ok(Nil))
  process.kill(first)
  process.kill(second)
}

pub fn heirloom_rejects_heir_changes_from_non_owner_test() -> Nil {
  let table = table("heirloom_non_owner")
  let outcome = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      process.send(
        outcome,
        heirloom.set_heir(table, process.self(), "not-owner"),
      )
    })
  let monitor = process.monitor(worker)

  process.receive(outcome, 500)
  |> should.equal(Ok(Error(heirloom.NotOwner)))
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(500)
  heirloom.delete(table) |> should.equal(Ok(Nil))
}

pub fn heirloom_transfers_when_owner_exits_test() -> Nil {
  let announced = process.new_subject()
  let heir = process.self()
  let owner =
    process.spawn_unlinked(fn() {
      let specification =
        heirloom.spec("heirloom_owner_exit", heirloom.Set)
        |> heirloom.with_access(heirloom.Public)
        |> heirloom.with_heir(heir, "inherit")
      let assert Ok(table): Result(heirloom.Table(String, String), _) =
        heirloom.create(specification)
      let assert Ok(Nil) = heirloom.insert(table, "key", "value")
      process.send(announced, table)
    })
  let assert Ok(table) = process.receive(announced, 500)
  let selector =
    process.new_selector()
    |> heirloom.select_transfers(decode.string, fn(transfer) { transfer })
  let assert Ok(Ok(heirloom.Transfer(received, previous_owner, data))) =
    process.selector_receive(selector, 500)

  received |> should.equal(table)
  previous_owner |> should.equal(owner)
  data |> should.equal("inherit")
  heirloom.lookup(received, "key") |> should.equal(Ok(Some("value")))
  heirloom.delete(received) |> should.equal(Ok(Nil))
}

pub fn heirloom_give_away_selects_typed_transfer_test() -> Nil {
  let ready = process.new_subject()
  let received = process.new_subject()
  let recipient_process =
    process.spawn_unlinked(fn() {
      process.send(ready, process.self())
      let selector =
        process.new_selector()
        |> heirloom.select_transfers(decode.string, fn(transfer) { transfer })
      process.send(received, process.selector_receive(selector, 500))
      process.sleep(1000)
    })
  let assert Ok(recipient) = process.receive(ready, 500)
  let heir = process.spawn_unlinked(fn() { process.sleep(1000) })
  let specification =
    heirloom.spec("heirloom_give_away", heirloom.Set)
    |> heirloom.with_access(heirloom.Public)
    |> heirloom.with_heir(heir, "configured-heir")
  let assert Ok(table): Result(heirloom.Table(String, String), _) =
    heirloom.create(specification)
  let assert Ok(Nil) = heirloom.insert(table, "key", "value")

  heirloom.give_away(table, to: recipient, data: "gift")
  |> should.equal(Ok(Nil))
  let assert Ok(Ok(Ok(heirloom.Transfer(
    table: received_table,
    previous_owner: previous_owner,
    data: data,
  )))) = process.receive(received, 1000)
  received_table |> should.equal(table)
  previous_owner |> should.equal(process.self())
  data |> should.equal("gift")
  heirloom.owner(table) |> should.equal(Ok(recipient))
  heirloom.heir(table) |> should.equal(Ok(Some(heir)))
  process.kill(recipient_process)
  process.kill(heir)
}

pub fn heirloom_rejects_give_away_to_owner_test() -> Nil {
  let table = table("heirloom_same_owner")
  heirloom.give_away(table, to: process.self(), data: Nil)
  |> should.equal(Error(heirloom.RecipientIsOwner))
  heirloom.delete(table) |> should.equal(Ok(Nil))
}

pub fn heirloom_rejects_give_away_to_dead_process_test() -> Nil {
  let table = table("heirloom_dead_recipient")
  let recipient = process.spawn_unlinked(fn() { Nil })
  let monitor = process.monitor(recipient)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(500)
  heirloom.give_away(table, to: recipient, data: Nil)
  |> should.equal(Error(heirloom.RecipientNotAlive))
  heirloom.delete(table) |> should.equal(Ok(Nil))
}

pub fn heirloom_reports_invalid_transfer_data_test() -> Nil {
  let table = table("heirloom_invalid_transfer_data")
  send_transfer(table, process.self(), 123)
  let selector =
    process.new_selector()
    |> heirloom.select_transfers(decode.string, fn(transfer) { transfer })
  let assert Ok(Error(heirloom.InvalidHeirData([_, ..]))) =
    process.selector_receive(selector, 500)
  heirloom.delete(table) |> should.equal(Ok(Nil))
}

pub fn heirloom_reports_spoofed_transfer_table_test() -> Nil {
  send_invalid_table_transfer(process.self(), "data")
  let selector =
    process.new_selector()
    |> heirloom.select_transfers(decode.string, fn(transfer) { transfer })
  process.selector_receive(selector, 500)
  |> should.equal(Ok(Error(heirloom.InvalidTable)))
}

pub fn heirloom_transfer_selector_composes_with_subject_test() -> Nil {
  let subject = process.new_subject()
  process.send(subject, "normal")
  let selector =
    process.new_selector()
    |> process.select_map(subject, fn(message) { Ok(message) })
    |> heirloom.select_transfers(decode.string, fn(_transfer) { Error(Nil) })
  process.selector_receive(selector, 500)
  |> should.equal(Ok(Ok("normal")))
}
