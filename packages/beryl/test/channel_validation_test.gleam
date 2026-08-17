//// Tests for the `beryl/channel` handler-table validation and error
//// surface: deterministic pattern validation, exact-duplicate detection,
//// and tolerated non-identical overlaps.

import beryl
import beryl/channel
import beryl/topic
import beryl/wire
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn stub(pattern: String) -> channel.Handler {
  channel.handler(pattern, fn(_context) {
    channel.accept(Nil, channel.callbacks())
  })
}

fn validate(
  handlers: List(channel.Handler),
) -> Result(Nil, channel.ChildSpecError) {
  case
    channel.child_spec(beryl.config(wire.phoenix_codec()), handlers: handlers)
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

pub fn an_empty_handler_table_is_valid_test() {
  validate([]) |> should.equal(Ok(Nil))
}

pub fn distinct_valid_patterns_are_accepted_test() {
  validate([
    stub("room:*"),
    stub("document:*:ops"),
    stub("system"),
    stub("*"),
  ])
  |> should.equal(Ok(Nil))
}

pub fn an_empty_pattern_is_rejected_test() {
  validate([stub("room:*"), stub("")])
  |> should.equal(Error(channel.InvalidPattern("", topic.EmptyTopic)))
}

pub fn a_control_character_pattern_is_rejected_test() {
  validate([stub("room:\u{0001}*")])
  |> should.equal(
    Error(channel.InvalidPattern(
      "room:\u{0001}*",
      topic.InvalidFormat("pattern contains control characters"),
    )),
  )
}

pub fn exact_duplicate_patterns_are_rejected_test() {
  validate([
    stub("room:*"),
    stub("document:*"),
    stub("room:*"),
  ])
  |> should.equal(Error(channel.DuplicatePattern("room:*")))
}

pub fn non_identical_overlaps_are_allowed_test() {
  validate([
    stub("room:lobby"),
    stub("room:*"),
    stub("*"),
  ])
  |> should.equal(Ok(Nil))
}

pub fn validation_checks_syntax_before_duplicates_test() {
  // Pattern syntax is checked for the whole table first, so the invalid
  // empty pattern wins even though a duplicate appears earlier.
  validate([stub("a"), stub("a"), stub("")])
  |> should.equal(Error(channel.InvalidPattern("", topic.EmptyTopic)))

  validate([stub(""), stub("a"), stub("a")])
  |> should.equal(Error(channel.InvalidPattern("", topic.EmptyTopic)))
}

pub fn validation_reports_the_first_invalid_pattern_in_order_test() {
  validate([stub("room:*"), stub(""), stub("\u{0001}")])
  |> should.equal(Error(channel.InvalidPattern("", topic.EmptyTopic)))
}

pub fn validation_reports_the_first_repeated_pattern_in_order_test() {
  validate([
    stub("a"),
    stub("b"),
    stub("b"),
    stub("a"),
  ])
  |> should.equal(Error(channel.DuplicatePattern("b")))
}
