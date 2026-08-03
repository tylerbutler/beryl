---
title: "beryl/presence/wire"
description: "Phoenix-compatible wire encoding for presence diffs."
---

Phoenix-compatible wire encoding for presence diffs.

## Functions

### `encode_diff`

Encode a presence diff for one topic as a Phoenix-compatible payload.

 The resulting JSON has `joins` and `leaves` maps keyed by presence key,
 where each value contains the tracked metadata under `metas`.

 ```json
 {
   "joins": { "user:1": { "metas": [{ "status": "online" }] } },
   "leaves": { "user:2": { "metas": [{ "status": "offline" }] } }
 }
 ```

```gleam
pub fn encode_diff(
  presence.Diff,
  String
) -> json.Json
```

### `encode_state`

Encode a topic's full presence list as a Phoenix-compatible
 `presence_state` payload.

 The resulting JSON is a map keyed by presence key, where each value
 contains the tracked metadata under `metas` — the same shape as one side
 of a `presence_diff`:

 ```json
 { "user:1": { "metas": [{ "status": "online", "phx_ref": "..." }] } }
 ```

 Phoenix clients expect a `presence_state` event carrying this payload
 after joining a presence-enabled topic (followed by incremental
 `presence_diff` events). Build the entry list with `presence.list`.

```gleam
pub fn encode_state(List(presence.PresenceEntry)) -> json.Json
```
