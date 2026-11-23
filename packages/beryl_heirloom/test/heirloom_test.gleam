import beryl_heirloom as heirloom
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import unitest

@external(erlang, "heirloom_test_ffi", "send_transfer")
fn send_transfer(
  table: identifier,
  previous_owner: process.Pid,
  data: data,
) -> Nil

@external(erlang, "heirloom_test_ffi", "send_invalid_table_transfer")
fn send_invalid_table_transfer(previous_owner: process.Pid, data: data) -> Nil

@external(erlang, "heirloom_test_ffi", "check_unnamed_labels")
fn check_unnamed_labels(
  create: fn(String) ->
    Result(heirloom.Table(String, String), heirloom.CreateError),
) -> Nil

@external(erlang, "heirloom_test_ffi", "check_invalid_names")
fn check_invalid_names() -> Nil

@external(erlang, "heirloom_test_ffi", "check_recipient_death_during_transfer")
fn check_recipient_death_during_transfer(check: fn(process.Pid) -> Nil) -> Nil

fn table(name: String) -> heirloom.Table(String, String) {
  let assert Ok(table) = heirloom.create(heirloom.spec(name, heirloom.Set))
  table
}

fn gift_decoder() -> decode.Decoder(#(String, Int)) {
  use label <- decode.field(0, decode.string)
  use number <- decode.field(1, decode.int)
  decode.success(#(label, number))
}

type Handoff {
  ConfiguredHeir
  UpdatedHeir
  GivenAway
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

pub fn heirloom_accepts_255_code_point_names_test() -> Nil {
  ["x", "\u{00e9}", "\u{1f600}"]
  |> list.each(fn(character) {
    // Named cases reuse three fixed labels, even when this test runs again.
    let specification =
      heirloom.spec(string.repeat(character, 255), heirloom.Set)
    [specification, heirloom.with_named_table(specification)]
    |> list.each(fn(specification) {
      let assert Ok(table): Result(heirloom.Table(String, String), _) =
        heirloom.create(specification)
      heirloom.delete(table) |> should.equal(Ok(Nil))
      heirloom.exists(table) |> should.be_false
    })
  })
}

pub fn heirloom_rejects_256_code_point_names_test() -> Nil {
  [
    string.repeat("x", 256),
    string.repeat("\u{00e9}", 256),
    string.repeat("\u{1f600}", 256),
    string.repeat("e\u{0301}", 128),
  ]
  |> list.each(fn(name) {
    let specification = heirloom.spec(name, heirloom.Set)
    [specification, heirloom.with_named_table(specification)]
    |> list.each(fn(specification) {
      heirloom.create(specification)
      |> should.equal(Error(heirloom.InvalidName))
    })
  })
}

pub fn heirloom_unnamed_labels_do_not_create_atoms_test() -> Nil {
  check_unnamed_labels(fn(name) {
    heirloom.spec(name, heirloom.Set)
    |> heirloom.create
  })
}

pub fn heirloom_rejects_invalid_native_names_test() -> Nil {
  check_invalid_names()
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

pub fn heirloom_stale_named_handle_cannot_reach_replacement_test() -> Nil {
  use <- unitest.tag("serial")
  let specification =
    heirloom.spec("heirloom_named_replacement", heirloom.Set)
    |> heirloom.with_named_table
  let assert Ok(stale): Result(heirloom.Table(String, String), _) =
    heirloom.create(specification)
  heirloom.insert(stale, "key", "original") |> should.equal(Ok(Nil))
  heirloom.delete(stale) |> should.equal(Ok(Nil))

  let assert Ok(replacement): Result(heirloom.Table(String, Int), _) =
    heirloom.create(specification)
  heirloom.insert(replacement, "key", 674) |> should.equal(Ok(Nil))

  // Match only the error: a successful stale lookup can contain a value
  // whose runtime representation does not match its declared String type.
  let stale_lookup_failed = case heirloom.lookup(stale, "key") {
    Error(heirloom.TableDoesNotExist) -> True
    Error(heirloom.AccessDenied) | Ok(_) -> False
  }
  let stale_delete = heirloom.delete(stale)
  let marker = heirloom.lookup(replacement, "key")
  case heirloom.exists(replacement) {
    True -> heirloom.delete(replacement) |> should.equal(Ok(Nil))
    False -> Nil
  }

  #(stale_lookup_failed, stale_delete, marker)
  |> should.equal(#(True, Error(heirloom.TableDoesNotExist), Ok(Some(674))))
}

pub fn heirloom_creation_publishes_requested_named_access_test() -> Nil {
  use <- unitest.tag("serial")
  [False, True]
  |> list.each(fn(named) { access_and_owner_only_deletion(named) })
}

fn access_and_owner_only_deletion(named: Bool) -> Nil {
  [heirloom.Private, heirloom.Protected, heirloom.Public]
  |> list.each(fn(access) {
    let specification =
      heirloom.spec("heirloom_published_named_access", heirloom.Set)
      |> heirloom.with_access(access)
    let specification = case named {
      True -> heirloom.with_named_table(specification)
      False -> specification
    }
    let assert Ok(table): Result(heirloom.Table(String, String), _) =
      heirloom.create(specification)
    heirloom.insert(table, "key", "original") |> should.equal(Ok(Nil))
    let outcome = process.new_subject()
    let worker =
      process.spawn_unlinked(fn() {
        process.send(outcome, #(
          heirloom.lookup(table, "key"),
          heirloom.insert(table, "key", "replacement"),
          heirloom.delete(table),
        ))
      })
    let monitor = process.monitor(worker)
    let actual = process.receive(outcome, 500)
    let down =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
      |> process.selector_receive(500)
    let marker = heirloom.lookup(table, "key")
    let owner_delete = heirloom.delete(table)
    let missing_delete = heirloom.delete(table)
    let assert Ok(_) = down
    let expected = case access {
      heirloom.Private -> #(
        Error(heirloom.AccessDenied),
        Error(heirloom.AccessDenied),
        Error(heirloom.AccessDenied),
      )
      heirloom.Protected -> #(
        Ok(Some("original")),
        Error(heirloom.AccessDenied),
        Error(heirloom.AccessDenied),
      )
      heirloom.Public -> #(
        Ok(Some("original")),
        Ok(Nil),
        Error(heirloom.AccessDenied),
      )
    }
    let expected_marker = case access {
      heirloom.Private | heirloom.Protected -> "original"
      heirloom.Public -> "replacement"
    }
    #(actual, marker, owner_delete, missing_delete)
    |> should.equal(#(
      Ok(expected),
      Ok(Some(expected_marker)),
      Ok(Nil),
      Error(heirloom.TableDoesNotExist),
    ))
  })
}

pub fn heirloom_delayed_named_transfer_cannot_reach_replacement_test() -> Nil {
  use <- unitest.tag("serial")
  list.each([ConfiguredHeir, UpdatedHeir, GivenAway], fn(handoff) {
    let specification =
      heirloom.spec("heirloom_delayed_named_replacement", heirloom.Set)
      |> heirloom.with_named_table
    let announced = process.new_subject()
    let recipient = process.self()
    let owner =
      process.spawn_unlinked(fn() {
        let assert Ok(table): Result(heirloom.Table(String, String), _) = case
          handoff
        {
          ConfiguredHeir ->
            specification
            |> heirloom.with_heir(recipient, "original-gift")
            |> heirloom.create
          UpdatedHeir | GivenAway -> heirloom.create(specification)
        }
        let assert Ok(Nil) = heirloom.insert(table, "key", "original")
        case handoff {
          ConfiguredHeir -> Nil
          UpdatedHeir ->
            heirloom.set_heir(table, recipient, "original-gift")
            |> should.equal(Ok(Nil))
          GivenAway ->
            heirloom.give_away(table, to: recipient, data: "original-gift")
            |> should.equal(Ok(Nil))
        }
        process.send(announced, table)
      })
    let monitor = process.monitor(owner)
    let assert Ok(original) = process.receive(announced, 500)
    // Waiting for this exact monitor leaves ETS-TRANSFER queued and ensures
    // ownership has moved before the recipient deletes the original table.
    let assert Ok(_) =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
      |> process.selector_receive(500)
    heirloom.delete(original) |> should.equal(Ok(Nil))
    let assert Ok(replacement): Result(heirloom.Table(String, Int), _) =
      heirloom.create(specification)
    heirloom.insert(replacement, "key", 674) |> should.equal(Ok(Nil))

    let selector =
      process.new_selector()
      |> heirloom.select_transfers(decode.string, fn(transfer) { transfer })
    let rejected = case process.selector_receive(selector, 500) {
      Ok(Error(error)) -> Ok(Error(error))
      Ok(Ok(_transfer)) -> Ok(Ok(Nil))
      Error(error) -> Error(error)
    }
    let marker = heirloom.lookup(replacement, "key")
    heirloom.delete(replacement) |> should.equal(Ok(Nil))
    // Do not inspect a success payload: before the fix it could be mistyped.
    #(handoff, rejected, marker)
    |> should.equal(#(handoff, Ok(Error(heirloom.InvalidTable)), Ok(Some(674))))
  })
}

pub fn heirloom_rejects_untagged_named_transfer_test() -> Nil {
  let specification =
    heirloom.spec("heirloom_untagged_named_transfer", heirloom.Set)
    |> heirloom.with_named_table
  let assert Ok(table): Result(heirloom.Table(String, String), _) =
    heirloom.create(specification)
  send_transfer(
    atom.create("heirloom_untagged_named_transfer"),
    process.self(),
    "gift",
  )
  let selector =
    process.new_selector()
    |> heirloom.select_transfers(decode.string, fn(transfer) { transfer })
  let decoded = process.selector_receive(selector, 500)
  heirloom.delete(table) |> should.equal(Ok(Nil))
  decoded |> should.equal(Ok(Error(heirloom.InvalidTable)))
}

pub fn heirloom_rejects_malformed_transfer_envelopes_test() -> Nil {
  let name = atom.create("heirloom_malformed_transfer_envelopes")
  let tag = atom.create("beryl_heirloom_transfer")
  let specification =
    heirloom.spec("heirloom_malformed_transfer_envelopes", heirloom.Set)
    |> heirloom.with_named_table
  let assert Ok(table): Result(heirloom.Table(String, String), _) =
    heirloom.create(specification)
  // A live name inside the reserved envelope still cannot prove identity.
  send_transfer(name, process.self(), #(tag, name, "gift"))
  send_transfer(table, process.self(), #(tag, 674, "gift"))
  send_transfer(674, process.self(), "gift")
  let selector =
    process.new_selector()
    |> heirloom.select_transfers(decode.string, fn(transfer) { transfer })
  let outcomes = [
    process.selector_receive(selector, 500),
    process.selector_receive(selector, 500),
    process.selector_receive(selector, 500),
  ]
  heirloom.delete(table) |> should.equal(Ok(Nil))
  outcomes
  |> should.equal(list.repeat(Ok(Error(heirloom.InvalidTable)), 3))
}

pub fn heirloom_accepts_untagged_tid_transfer_test() -> Nil {
  let table = table("heirloom_untagged_tid_transfer")
  send_transfer(table, process.self(), "native-gift")
  let selector =
    process.new_selector()
    |> heirloom.select_transfers(decode.string, fn(transfer) { transfer })
  let decoded = process.selector_receive(selector, 500)
  heirloom.delete(table) |> should.equal(Ok(Nil))
  decoded
  |> should.equal(
    Ok(
      Ok(heirloom.Transfer(
        table: table,
        previous_owner: process.self(),
        data: "native-gift",
      )),
    ),
  )
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
  heirloom.spec("heirloom_owner_exit", heirloom.Set)
  |> transfers_when_owner_exits
}

pub fn heirloom_named_transfer_when_owner_exits_preserves_instance_test() -> Nil {
  heirloom.spec("heirloom_named_owner_exit", heirloom.Set)
  |> heirloom.with_named_table
  |> transfers_when_owner_exits
}

fn transfers_when_owner_exits(specification: heirloom.Spec(Nil)) -> Nil {
  let announced = process.new_subject()
  let heir = process.self()
  let owner =
    process.spawn_unlinked(fn() {
      let specification =
        specification
        |> heirloom.with_access(heirloom.Public)
        |> heirloom.with_heir(heir, #("inherit", 674))
      let assert Ok(table): Result(heirloom.Table(String, String), _) =
        heirloom.create(specification)
      let assert Ok(Nil) = heirloom.insert(table, "key", "value")
      process.send(announced, table)
    })
  let assert Ok(table) = process.receive(announced, 500)
  let selector =
    process.new_selector()
    |> heirloom.select_transfers(gift_decoder(), fn(transfer) { transfer })
  let assert Ok(Ok(heirloom.Transfer(received, previous_owner, data))) =
    process.selector_receive(selector, 500)

  received |> should.equal(table)
  previous_owner |> should.equal(owner)
  data |> should.equal(#("inherit", 674))
  heirloom.lookup(received, "key") |> should.equal(Ok(Some("value")))
  heirloom.delete(received) |> should.equal(Ok(Nil))
}

pub fn heirloom_give_away_selects_typed_transfer_test() -> Nil {
  heirloom.spec("heirloom_give_away", heirloom.Set)
  |> give_away_selects_typed_transfer
}

pub fn heirloom_named_give_away_preserves_instance_test() -> Nil {
  heirloom.spec("heirloom_named_give_away", heirloom.Set)
  |> heirloom.with_named_table
  |> give_away_selects_typed_transfer
}

fn give_away_selects_typed_transfer(specification: heirloom.Spec(Nil)) -> Nil {
  let ready = process.new_subject()
  let received = process.new_subject()
  let recipient_process =
    process.spawn_unlinked(fn() {
      process.send(ready, process.self())
      let selector =
        process.new_selector()
        |> heirloom.select_transfers(gift_decoder(), fn(transfer) { transfer })
      process.send(received, process.selector_receive(selector, 500))
      process.sleep(1000)
    })
  let assert Ok(recipient) = process.receive(ready, 500)
  let heir = process.spawn_unlinked(fn() { process.sleep(1000) })
  let specification =
    specification
    |> heirloom.with_access(heirloom.Public)
    |> heirloom.with_heir(heir, "configured-heir")
  let assert Ok(table): Result(heirloom.Table(String, String), _) =
    heirloom.create(specification)
  let assert Ok(Nil) = heirloom.insert(table, "key", "value")

  heirloom.give_away(table, to: recipient, data: #("gift", 674))
  |> should.equal(Ok(Nil))
  let assert Ok(Ok(Ok(heirloom.Transfer(
    table: received_table,
    previous_owner: previous_owner,
    data: data,
  )))) = process.receive(received, 1000)
  received_table |> should.equal(table)
  previous_owner |> should.equal(process.self())
  data |> should.equal(#("gift", 674))
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
  heirloom.set_heir(table, recipient, Nil)
  |> should.equal(Error(heirloom.InvalidOwnershipHeir))
  heirloom.give_away(table, to: recipient, data: Nil)
  |> should.equal(Error(heirloom.RecipientNotAlive))
  heirloom.delete(table) |> should.equal(Ok(Nil))
}

pub fn heirloom_reports_recipient_death_during_transfer_test() -> Nil {
  heirloom.spec("heirloom_recipient_death_race", heirloom.Set)
  |> recipient_death_during_transfer
}

pub fn heirloom_named_recipient_death_preserves_instance_test() -> Nil {
  heirloom.spec("heirloom_named_recipient_death_race", heirloom.Set)
  |> heirloom.with_named_table
  |> recipient_death_during_transfer
}

fn recipient_death_during_transfer(specification: heirloom.Spec(Nil)) -> Nil {
  check_recipient_death_during_transfer(fn(recipient) {
    let assert Ok(table): Result(heirloom.Table(String, String), _) =
      heirloom.create(specification)
    let assert Ok(Nil) = heirloom.insert(table, "key", "original")
    let assert Ok(Nil) =
      heirloom.set_heir(table, process.self(), "configured-heir")
    let transferred =
      heirloom.give_away(table, to: recipient, data: "recipient-death-race")
    let owner = heirloom.owner(table)
    let heir = heirloom.heir(table)
    let contents = heirloom.lookup(table, "key")
    heirloom.delete(table) |> should.equal(Ok(Nil))
    #(transferred, owner, heir, contents)
    |> should.equal(#(
      Error(heirloom.RecipientNotAlive),
      Ok(process.self()),
      Ok(Some(process.self())),
      Ok(Some("original")),
    ))
  })
}

pub fn heirloom_preserves_ownership_error_precedence_test() -> Nil {
  let table = table("heirloom_transfer_ownership_errors")
  let outcome = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      process.send(
        outcome,
        heirloom.give_away(table, to: process.self(), data: Nil),
      )
    })
  let monitor = process.monitor(worker)
  let result = process.receive(outcome, 500)
  let down =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(500)
  heirloom.delete(table) |> should.equal(Ok(Nil))
  let missing = heirloom.give_away(table, to: process.self(), data: Nil)
  let assert Ok(_) = down
  #(result, missing)
  |> should.equal(#(
    Ok(Error(heirloom.NotOwner)),
    Error(heirloom.OwnershipTableDoesNotExist),
  ))
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
