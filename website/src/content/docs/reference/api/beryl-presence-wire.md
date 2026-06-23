---
title: beryl/presence/wire
description: Phoenix-compatible wire encoding for presence diffs.
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
