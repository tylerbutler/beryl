# beryl_heirloom

Typed ETS tables with heirs and ownership transfers, for Gleam on the BEAM.

## Overview

ETS deletes a table when the process that owns it exits. If the table has an
_heir_, ETS gives the table and its data to the heir instead. `beryl_heirloom`
gives you a typed Gleam API for this behavior:

- Create ETS tables with key and value types that the compiler checks.
- Set an heir, so that a table and its data stay alive when the owner exits.
- Give a table to a different process.
- Receive inherited and given tables as typed messages.

The package runs on the Erlang target only. It depends on `gleam_stdlib` and
`gleam_erlang`. It does not depend on beryl.

## Installation

beryl includes this package. The package has no separate release. To use it
without beryl, add a git dependency:

```toml
[dependencies]
beryl_heirloom = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl_heirloom" }
```

Import the module as `beryl_heirloom`. It does not conflict with modules named
`heirloom` or `heirloom_ffi` in your project.

## Create and use a table

```gleam
import beryl_heirloom as heirloom
import gleam/option.{Some}

pub fn main() -> Nil {
  let assert Ok(table): Result(heirloom.Table(String, Int), _) =
    heirloom.spec("scores", heirloom.Set)
    |> heirloom.with_read_concurrency(True)
    |> heirloom.create

  let assert Ok(Nil) = heirloom.insert(table, "alice", 10)
  let assert Ok(Some(10)) = heirloom.lookup(table, "alice")
  let assert Ok(Nil) = heirloom.delete(table)
  Nil
}
```

`spec` makes an unnamed table with `Protected` access and no heir. The table
type is `Set`, `OrderedSet`, `Bag`, or `DuplicateBag`. Use these functions to
change the specification before you call `create`:

| Function                 | Effect                                                        |
| ------------------------ | ------------------------------------------------------------- |
| `with_access`            | Sets `Private`, `Protected`, or `Public` access.              |
| `with_named_table`       | Registers the table under its name. See [Table names][names]. |
| `with_read_concurrency`  | Sets the ETS `read_concurrency` option.                       |
| `with_write_concurrency` | Sets the ETS `write_concurrency` option.                      |
| `with_heir`              | Sets the heir process and the data that the heir receives.    |
| `without_heir`           | Removes the heir.                                             |

`lookup` returns one value. For `Bag` and `DuplicateBag` tables, it returns the
first value that ETS reports.

[names]: #table-names

## Keep a table when its owner exits

Set an heir when you create the table:

```gleam
import beryl_heirloom as heirloom
import gleam/erlang/process

fn create_sessions(keeper: process.Pid) -> heirloom.Table(String, Int) {
  let assert Ok(table) =
    heirloom.spec("sessions", heirloom.Set)
    |> heirloom.with_heir(keeper, "sessions")
    |> heirloom.create
  table
}
```

When the owner exits, ETS sends an `ETS-TRANSFER` message to the heir. In the
heir, use `select_transfers` to receive that message. The decoder reads the
data that you gave to `with_heir`:

```gleam
import beryl_heirloom as heirloom
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/result

fn await_table() -> Result(
  heirloom.Table(String, Int),
  heirloom.TransferDecodeError,
) {
  process.new_selector()
  |> heirloom.select_transfers(decode.string, fn(transfer) { transfer })
  |> process.selector_receive_forever
  |> result.map(fn(transfer) { transfer.table })
}
```

Each `Transfer` contains the `table`, the `previous_owner`, and the decoded
`data`. If the data does not decode, the result is `InvalidHeirData`.

The heir must be a live process on the local node. Use a long-lived process,
for example a supervised one. Do not link the heir to the owner. If the owner
crashes, a linked heir also stops, unless it traps exits.

The package does not start heir processes or restore application state. Your
application supplies the heir and decides what to do with the table.

To change the heir of an existing table, use `set_heir` or `clear_heir`. To
read the current heir or owner, use `heir` or `owner`.

## Give a table to another process

```gleam
let assert Ok(Nil) = heirloom.give_away(table, to: worker, data: "handoff")
```

The recipient receives the table through `select_transfers`, as an heir does.
`give_away` does not change the heir. If the recipient stops before ETS moves
the table, `give_away` returns `RecipientNotAlive` and the caller keeps the
table.

## Rules and limits

### Types

The compiler checks key and value types. ETS does not check them at runtime.
Write to a table only through its typed handle.

### Table names

- A name must be valid UTF-8 with no more than 255 Unicode code points. If it is
  not, `create` returns `InvalidName`.
- Unnamed tables do not create atoms. For these tables,
  `ets:info(Table, name)` returns the atom `beryl_heirloom`. Use the handle
  from `create` to identify the table.
- `with_named_table` converts the name to an atom. The VM never frees atoms.
  Use a small, fixed set of names. Do not make names from request IDs or job
  IDs.
- If a table with the same name exists, `create` returns `TableAlreadyExists`.

### Handles

A handle refers to one table instance, not to a name. If you delete a named
table and create a new table with the same name, the old handle cannot read or
delete the new table.

### Ownership

- Only the owner can delete a table. Other processes get `AccessDenied`, also
  for `Public` tables. If the table does not exist, `delete` returns
  `TableDoesNotExist`.
- Only the owner can call `set_heir`, `clear_heir`, and `give_away`. Other
  processes get `NotOwner`.
- `set_heir` returns `InvalidOwnershipHeir` if the heir is not a live local
  process.
- `give_away` returns `RecipientNotAlive` or `RecipientNotLocal` if the
  recipient is not a live local process. It returns `RecipientIsOwner` if the
  caller gives the table to itself.

### Transfers from other code

`select_transfers` also accepts `ETS-TRANSFER` messages from code that does not
use this package, for example `ets:give_away/3` in Erlang. The message must
contain a table ID. `select_transfers` returns `InvalidTable` if:

- The message identifies the table only by name. A name does not identify one
  table instance.
- The original table no longer exists, even if a new table has its name.

## Development

From the repository root:

- `just test beryl_heirloom` runs the tests.
- `just beam-check` runs the BEAM FFI checks.
