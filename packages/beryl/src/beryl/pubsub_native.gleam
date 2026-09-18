import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}

// nolint: unused_exports -- public query adapter invoked from Erlang
@external(erlang, "pg", "get_members")
pub fn get_members(scope: atom.Atom, topic: String) -> List(Pid)

// nolint: unused_exports -- local query adapter invoked from Erlang
@external(erlang, "pg", "get_local_members")
pub fn get_local_members(scope: atom.Atom, topic: String) -> List(Pid)

@external(erlang, "beryl_pubsub_ffi", "registered_scope")
pub fn registered_scope(scope: atom.Atom) -> Result(Pid, Nil)

@external(erlang, "beryl_pubsub_ffi", "try_pg_join")
pub fn try_join(
  scope: atom.Atom,
  topic: String,
  owner: Pid,
) -> Result(Nil, Dynamic)

@external(erlang, "beryl_pubsub_ffi", "try_pg_leave")
pub fn try_leave(
  scope: atom.Atom,
  topic: String,
  owner: Pid,
) -> Result(Nil, Dynamic)

@external(erlang, "beryl_pubsub_ffi", "try_pg_local_members")
pub fn try_local_members(
  scope: atom.Atom,
  topic: String,
) -> Result(List(Pid), Dynamic)

@external(erlang, "gleam@erlang@process", "unsafely_create_subject")
pub fn subject_for_pid(pid: Pid, tag: atom.Atom) -> Subject(message)

@external(erlang, "beryl_pubsub_ffi", "is_local_pid")
pub fn is_local_pid(pid: Pid) -> Bool

@external(erlang, "erlang", "send")
fn raw_send(pid: Pid, message: message) -> message

pub fn send(
  pid: Pid,
  scope: atom.Atom,
  topic: String,
  event: String,
  payload: payload,
  from: from,
) -> Nil {
  case raw_send(pid, #(scope, topic, event, payload, from)) {
    _ -> Nil
  }
}

@external(erlang, "beryl_pubsub_ffi", "scoped_to_message")
pub fn coerce_scoped_message(value: Dynamic) -> message
