# beryl heirloom

Typed ETS tables, heirs, and ownership transfers for Erlang/BEAM. The package
has no dependency on beryl. Its runtime dependencies are `gleam_stdlib` and
`gleam_erlang`.

The package and module use the `beryl_heirloom` namespace. The native helper
remains `beryl_heirloom_ffi`; consumers can still define their own `heirloom`
and `heirloom_ffi` modules.

Table key and value types are checked at compile time, not by ETS at runtime.
Ownership changes require the caller to own the table and recipients or heirs
to be live local processes. The package does not start keeper processes or
manage application recovery. beryl owns its connection-limiter checkpoint
registry, heir process, and recovery policy.

This is a workspace package bundled into beryl alongside `beryl_protocol`.
It has no separate release, tag, or publication workflow. beryl consumers
need no extra installation or public API migration.

From the repository root, run `just test beryl_heirloom` for the focused ETS
tests and `just beam-check` for native boundary analysis.
