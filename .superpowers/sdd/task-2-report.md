# Task 2 Report

status: DONE

commits:
- test: add WebSocket contract harness

files changed:
- test/beryl_test_port_ffi.erl
- test/client_contract_test.gleam

tests/commands run:
- `gleam test -- --filter "start_test_server_uses_dynamic_port_test"` ✅
- `just test` ✅

self-review:
- Dynamic localhost port allocation is isolated in a test-only Erlang FFI helper.
- The harness starts a real Mist server and shuts it down explicitly after the smoke test.
- The Gleam test stays focused on the server contract and does not reimplement a client.

concerns:
- None.
