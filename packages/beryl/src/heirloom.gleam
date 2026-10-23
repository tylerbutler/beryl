//// Typed ETS tables, heirs, and ownership transfers.

import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/option.{type Option}
import gleam/result

/// An ETS table whose key and value types are tracked by Gleam.
///
/// ETS does not validate these types at runtime.
pub type Table(key, value)

/// The ETS table type.
pub type TableType {
  Set
  OrderedSet
  Bag
  DuplicateBag
}

/// The ETS table access level.
pub type Access {
  Private
  Protected
  Public
}

/// The process that inherits a table when its owner exits.
pub type Heir(data) {
  NoHeir
  Heir(process: process.Pid, data: data)
}

/// An ETS ownership transfer.
pub type Transfer(key, value, data) {
  Transfer(table: Table(key, value), previous_owner: process.Pid, data: data)
}

/// Options used to create a table.
pub opaque type Spec(heir_data) {
  Spec(
    name: String,
    table_type: TableType,
    access: Access,
    named_table: Bool,
    read_concurrency: Bool,
    write_concurrency: Bool,
    heir: Heir(heir_data),
  )
}

/// An error returned while creating a table.
pub type CreateError {
  TableAlreadyExists
  InvalidName
  InvalidHeir
  InvalidOptions
}

/// An error returned while accessing a table.
pub type TableError {
  TableDoesNotExist
  AccessDenied
}

/// An error returned while changing table ownership.
pub type OwnershipError {
  OwnershipTableDoesNotExist
  NotOwner
  InvalidOwnershipHeir
  RecipientNotAlive
  RecipientNotLocal
  RecipientIsOwner
}

/// An error returned while decoding an `ETS-TRANSFER` message.
pub type TransferDecodeError {
  InvalidTransferMessage
  InvalidTable
  InvalidPreviousOwner
  InvalidHeirData(List(decode.DecodeError))
}

/// Create a table specification with protected access and no heir.
pub fn spec(name: String, table_type: TableType) -> Spec(Nil) {
  Spec(
    name: name,
    table_type: table_type,
    access: Protected,
    named_table: False,
    read_concurrency: False,
    write_concurrency: False,
    heir: NoHeir,
  )
}

/// Set the table access level.
pub fn with_access(spec: Spec(data), access: Access) -> Spec(data) {
  Spec(..spec, access: access)
}

/// Register the table under its configured name.
pub fn with_named_table(spec: Spec(data)) -> Spec(data) {
  Spec(..spec, named_table: True)
}

/// Enable or disable ETS read concurrency optimization.
pub fn with_read_concurrency(spec: Spec(data), enabled: Bool) -> Spec(data) {
  Spec(..spec, read_concurrency: enabled)
}

/// Enable or disable ETS write concurrency optimization.
pub fn with_write_concurrency(spec: Spec(data), enabled: Bool) -> Spec(data) {
  Spec(..spec, write_concurrency: enabled)
}

/// Configure a live local process as the table heir.
pub fn with_heir(
  spec: Spec(previous_data),
  process: process.Pid,
  data: heir_data,
) -> Spec(heir_data) {
  Spec(
    name: spec.name,
    table_type: spec.table_type,
    access: spec.access,
    named_table: spec.named_table,
    read_concurrency: spec.read_concurrency,
    write_concurrency: spec.write_concurrency,
    heir: Heir(process:, data:),
  )
}

/// Remove the configured heir.
pub fn without_heir(spec: Spec(previous_data)) -> Spec(Nil) {
  Spec(
    name: spec.name,
    table_type: spec.table_type,
    access: spec.access,
    named_table: spec.named_table,
    read_concurrency: spec.read_concurrency,
    write_concurrency: spec.write_concurrency,
    heir: NoHeir,
  )
}

/// Create an ETS table owned by the calling process.
pub fn create(spec: Spec(heir_data)) -> Result(Table(key, value), CreateError) {
  create_ffi(
    spec.name,
    spec.table_type,
    spec.access,
    spec.named_table,
    spec.read_concurrency,
    spec.write_concurrency,
    spec.heir,
  )
}

@external(erlang, "heirloom_ffi", "create")
fn create_ffi(
  name: String,
  table_type: TableType,
  access: Access,
  named_table: Bool,
  read_concurrency: Bool,
  write_concurrency: Bool,
  heir: Heir(data),
) -> Result(Table(key, value), CreateError)

/// Insert or replace a key and value.
pub fn insert(
  table: Table(key, value),
  key: key,
  value: value,
) -> Result(Nil, TableError) {
  insert_ffi(table, key, value)
}

@external(erlang, "heirloom_ffi", "insert")
fn insert_ffi(
  table: Table(key, value),
  key: key,
  value: value,
) -> Result(Nil, TableError)

/// Look up one value for a key.
///
/// Set tables contain at most one value. Bag tables return the first value
/// reported by ETS.
pub fn lookup(
  table: Table(key, value),
  key: key,
) -> Result(Option(value), TableError) {
  lookup_ffi(table, key)
}

@external(erlang, "heirloom_ffi", "lookup")
fn lookup_ffi(
  table: Table(key, value),
  key: key,
) -> Result(Option(value), TableError)

/// Delete a table owned by the calling process.
pub fn delete(table: Table(key, value)) -> Result(Nil, TableError) {
  delete_ffi(table)
}

@external(erlang, "heirloom_ffi", "delete")
fn delete_ffi(table: Table(key, value)) -> Result(Nil, TableError)

/// Return whether a table currently exists.
@external(erlang, "heirloom_ffi", "exists")
pub fn exists(table: Table(key, value)) -> Bool

/// Return the current table owner.
@external(erlang, "heirloom_ffi", "owner")
pub fn owner(table: Table(key, value)) -> Result(process.Pid, TableError)

/// Return the configured live heir, if present.
@external(erlang, "heirloom_ffi", "heir")
pub fn heir(table: Table(key, value)) -> Result(Option(process.Pid), TableError)

/// Set the table heir.
///
/// The caller must own the table. The heir must be a live local process.
pub fn set_heir(
  table: Table(key, value),
  process: process.Pid,
  data: heir_data,
) -> Result(Nil, OwnershipError) {
  set_heir_ffi(table, process, data)
}

@external(erlang, "heirloom_ffi", "set_heir")
fn set_heir_ffi(
  table: Table(key, value),
  process: process.Pid,
  data: data,
) -> Result(Nil, OwnershipError)

/// Clear the table heir.
///
/// The caller must own the table.
@external(erlang, "heirloom_ffi", "clear_heir")
pub fn clear_heir(table: Table(key, value)) -> Result(Nil, OwnershipError)

/// Give the table to another live local process.
///
/// The caller must own the table. The recipient observes completion through
/// an `ETS-TRANSFER` message. The configured heir is unchanged.
pub fn give_away(
  table: Table(key, value),
  to process: process.Pid,
  data data: gift_data,
) -> Result(Nil, OwnershipError) {
  give_away_ffi(table, process, data)
}

@external(erlang, "heirloom_ffi", "give_away")
fn give_away_ffi(
  table: Table(key, value),
  process: process.Pid,
  data: data,
) -> Result(Nil, OwnershipError)

/// Add typed ETS ownership transfers to a process selector.
pub fn select_transfers(
  selector: process.Selector(message),
  data_decoder: decode.Decoder(data),
  mapping: fn(Result(Transfer(key, value, data), TransferDecodeError)) ->
    message,
) -> process.Selector(message) {
  process.select_record(selector, atom.create("ETS-TRANSFER"), 3, fn(raw) {
    let transfer = case validate_transfer(raw) {
      Error(error) -> Error(error)
      Ok(#(table, previous_owner, raw_data)) ->
        decode.run(raw_data, data_decoder)
        |> result.map(fn(data) {
          Transfer(table: table, previous_owner: previous_owner, data: data)
        })
        |> result.map_error(InvalidHeirData)
    }
    mapping(transfer)
  })
}

@external(erlang, "heirloom_ffi", "validate_transfer")
fn validate_transfer(
  message: decode.Dynamic,
) -> Result(
  #(Table(key, value), process.Pid, decode.Dynamic),
  TransferDecodeError,
)
