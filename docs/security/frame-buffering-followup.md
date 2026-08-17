# Follow-up: enforce frame limits before WebSocket payload buffering

Tracking record for GitHub issue #198,
"Enforce frame limits before WebSocket payload buffering".

## Resolution

Beryl pins its maintained Mist fork at commit
`e69e44edf4c0ca41a3bab771c2dd6e2151ecf3e5`. The fix is carried downstream
and does not depend on an upstream change.

The bounded Mist entry point scans WebSocket headers before decoding:

- a declared payload over `with_max_inbound_frame_bytes` receives close code
  1009 before its incomplete body can be retained;
- continuation-frame declared lengths are accumulated and rejected before
  Mist concatenates an oversized fragmented message; and
- values less than or equal to zero preserve the existing unlimited behavior.

`beryl_mist` passes the configured Beryl limit into that entry point. Beryl's
post-assembly check remains as defense in depth.

## Acceptance criteria

- [x] Bound transport memory before payload accumulation.
- [x] Close oversized frames after parsing the declared length.
- [x] Bound fragmented-message aggregation to the same limit.
- [x] Exercise header-only streamed payloads and fragmented payloads.
- [x] Document the in-process guarantee and remaining adapter responsibility.
