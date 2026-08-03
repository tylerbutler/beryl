//// Tests for the `beryl_channels` handler-table validation and error
//// surface: deterministic pattern validation, exact-duplicate detection,
//// and tolerated non-identical overlaps.

import beryl_channels
import beryl_channels/channel
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn stub(pattern: String) -> channel.Handler {
  channel.handler(pattern, fn(_info, _topic, _payload) {
    channel.accept(channel.joined(Nil, channel.callbacks()))
  })
}

pub fn an_empty_handler_table_is_valid_test() {
  beryl_channels.validate_handlers([]) |> should.equal(Ok(Nil))
}

pub fn distinct_valid_patterns_are_accepted_test() {
  beryl_channels.validate_handlers([
    stub("room:*"),
    stub("document:*:ops"),
    stub("system"),
    stub("*"),
  ])
  |> should.equal(Ok(Nil))
}

pub fn an_empty_pattern_is_rejected_test() {
  beryl_channels.validate_handlers([stub("room:*"), stub("")])
  |> should.equal(
    Error(beryl_channels.InvalidPattern("", "pattern cannot be empty")),
  )
}

pub fn a_control_character_pattern_is_rejected_test() {
  beryl_channels.validate_handlers([stub("room:\u{0001}*")])
  |> should.equal(
    Error(beryl_channels.InvalidPattern(
      "room:\u{0001}*",
      "pattern contains control characters",
    )),
  )
}

pub fn exact_duplicate_patterns_are_rejected_test() {
  beryl_channels.validate_handlers([
    stub("room:*"),
    stub("document:*"),
    stub("room:*"),
  ])
  |> should.equal(Error(beryl_channels.DuplicatePattern("room:*")))
}

pub fn non_identical_overlaps_are_allowed_test() {
  beryl_channels.validate_handlers([
    stub("room:lobby"),
    stub("room:*"),
    stub("*"),
  ])
  |> should.equal(Ok(Nil))
}

pub fn validation_checks_syntax_before_duplicates_test() {
  // Pattern syntax is checked for the whole table first, so the invalid
  // empty pattern wins even though a duplicate appears earlier.
  beryl_channels.validate_handlers([stub("a"), stub("a"), stub("")])
  |> should.equal(
    Error(beryl_channels.InvalidPattern("", "pattern cannot be empty")),
  )

  beryl_channels.validate_handlers([stub(""), stub("a"), stub("a")])
  |> should.equal(
    Error(beryl_channels.InvalidPattern("", "pattern cannot be empty")),
  )
}

pub fn validation_reports_the_first_invalid_pattern_in_order_test() {
  beryl_channels.validate_handlers([stub("room:*"), stub(""), stub("\u{0001}")])
  |> should.equal(
    Error(beryl_channels.InvalidPattern("", "pattern cannot be empty")),
  )
}

pub fn validation_reports_the_first_repeated_pattern_in_order_test() {
  beryl_channels.validate_handlers([
    stub("a"),
    stub("b"),
    stub("b"),
    stub("a"),
  ])
  |> should.equal(Error(beryl_channels.DuplicatePattern("b")))
}
// Error-surface coverage deliberately stops here. `StartError` and
// `ChildSpecError` are only reachable through the `start`/`child_spec`
// entry points, so they are asserted end to end in `entry_point_test`;
// asserting on hand-constructed values here would test the compiler, not
// this package.
