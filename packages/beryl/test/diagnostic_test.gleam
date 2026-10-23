//// The rescue boundary returns typed results and copied, bounded UTF-8 text.

import beryl/internal
import gleam/bit_array
import gleam/list
import gleam/string
import gleeunit/should

@external(erlang, "beryl_diagnostic_test_ffi", "fail_operation")
fn fail_operation(value: String) -> Nil

@external(erlang, "beryl_diagnostic_test_ffi", "fail_with_stack")
fn fail_with_stack(shape: String) -> Nil

@external(erlang, "beryl_diagnostic_test_ffi", "fail_exception")
fn fail_exception(class: String, shape: String) -> Nil

@external(erlang, "beryl_diagnostic_test_ffi", "referenced_byte_size")
fn referenced_byte_size(value: String) -> Int

fn assert_bounded(description: String) -> Nil {
  let bytes = bit_array.from_string(description)
  bit_array.to_string(bytes) |> should.equal(Ok(description))
  { list.length(string.to_utf_codepoints(description)) <= 512 }
  |> should.be_true
  { bit_array.byte_size(bytes) <= 2048 } |> should.be_true
  { referenced_byte_size(description) <= 4096 } |> should.be_true
}

/// A successful callback keeps its exact typed result.
pub fn rescue_preserves_success_result_test() -> Nil {
  internal.rescue(fn() { #("unchanged", 42) })
  |> should.equal(Ok(#("unchanged", 42)))
}

/// Each synchronous exception class retains its reason and call sites.
pub fn rescue_preserves_exception_classes_and_reasons_test() -> Nil {
  list.each(["error", "exit", "throw"], fn(class) {
    let assert Error(description) =
      internal.rescue(fn() { fail_exception(class, "small") })
    string.starts_with(description, class <> ":") |> should.be_true
    string.contains(description, "boom") |> should.be_true
    string.contains(description, " stack: ") |> should.be_true
    assert_bounded(description)
  })
}

/// A real BIF failure reports the operation, not its sensitive argument.
pub fn rescue_reports_failing_operation_without_arguments_test() -> Nil {
  let assert Error(description) =
    internal.rescue(fn() { fail_operation("private-request-payload") })
  string.starts_with(description, "error:badarg") |> should.be_true
  string.contains(description, "erlang:binary_to_integer/1")
  |> should.be_true
  string.contains(description, "beryl_diagnostic_test_ffi.erl")
  |> should.be_true
  string.contains(description, "private-request-payload") |> should.be_false
  assert_bounded(description)
}

/// Caller-supplied deep stacks retain only three argument-free call sites.
pub fn rescue_limits_frames_and_omits_stack_arguments_and_metadata_test() -> Nil {
  let assert Error(description) =
    internal.rescue(fn() { fail_with_stack("deep") })
  description
  |> string.split("diagnostic_app:update/1")
  |> list.length
  |> should.equal(4)
  string.contains(description, "diagnostic_app.gleam") |> should.be_true
  string.contains(description, ":42") |> should.be_true
  string.contains(description, "private-request-payload") |> should.be_false
  string.contains(description, "private-stack-metadata") |> should.be_false
  assert_bounded(description)
}

/// Large reasons cannot consume the call-site or retained-memory budget.
pub fn rescue_reserves_call_site_budget_for_large_reasons_test() -> Nil {
  list.each(
    ["flat", "binary", "nested", "unicode", "emoji", "combining"],
    fn(shape) {
      let assert Error(description) =
        internal.rescue(fn() { fail_with_stack(shape) })
      string.contains(description, "diagnostic_app:update/1") |> should.be_true
      string.contains(description, ":42") |> should.be_true
      assert_bounded(description)
    },
  )
}

/// Four-byte Unicode source text remains valid and bounded.
pub fn rescue_bounds_unicode_source_locations_test() -> Nil {
  let assert Error(description) =
    internal.rescue(fn() { fail_with_stack("long_location") })
  string.contains(description, "diagnostic_app:update/2") |> should.be_true
  string.contains(description, "🚀") |> should.be_true
  assert_bounded(description)
}

/// Function-valued frames use their module and function names.
pub fn rescue_handles_function_stack_entries_test() -> Nil {
  let assert Error(description) =
    internal.rescue(fn() { fail_with_stack("fun") })
  string.contains(description, "beryl_diagnostic_test_ffi:retained_slice/0")
  |> should.be_true
  assert_bounded(description)
}

/// Long names cannot consume the arity and source-line budget.
pub fn rescue_preserves_arity_and_line_with_long_names_test() -> Nil {
  let assert Error(description) =
    internal.rescue(fn() { fail_with_stack("long_names") })
  string.contains(description, "diagnostic_application_") |> should.be_true
  string.contains(description, "callback_with_a_") |> should.be_true
  string.contains(description, "/2") |> should.be_true
  string.contains(description, ":42") |> should.be_true
  assert_bounded(description)
}

/// Invalid caller-supplied source text must not escape the rescue boundary.
pub fn rescue_handles_invalid_source_characters_test() -> Nil {
  let assert Error(description) =
    internal.rescue(fn() { fail_with_stack("invalid_location") })
  string.contains(description, "diagnostic_app:update/2") |> should.be_true
  string.contains(description, ":42") |> should.be_true
  assert_bounded(description)
}
