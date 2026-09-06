import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { renderSmokeComment } from "./render-smoke-comment.mjs";

const directory = await mkdtemp(path.join(os.tmpdir(), "beryl-smoke-comment-"));
try {
  for (const runtime of ["erlang-27", "erlang-28"]) {
    for (const transport of ["mist", "ewe"]) {
      const artifact = path.join(directory, `${runtime}-${transport}`);
      await mkdir(artifact);
      await writeFile(
        path.join(
          artifact,
          `protocol-smoke-${runtime.replace("erlang-", "")}-${transport}.json`,
        ),
        JSON.stringify({
          metadata: { runtime, transport },
          result: {
            metrics: {
              checks: {
                values: { rate: 1 },
                thresholds: { "rate==1": { ok: true } },
              },
              phoenix_ws_establish_duration: { values: { avg: 7 } },
              phoenix_join_duration: { values: { avg: 4 } },
              phoenix_push_reply_duration: { values: { avg: 1 } },
              phoenix_leave_reply_duration: { values: { avg: 0 } },
              phoenix_client_errors: { values: { count: 0 } },
              phoenix_unexpected_client_errors: { values: { count: 0 } },
              phoenix_protocol_errors: { values: { count: 0 } },
              phoenix_decode_errors: { values: { count: 0 } },
            },
          },
        }),
      );
    }
  }

  const comment = await renderSmokeComment(directory, "https://example.invalid/run");
  assert.match(comment, /All protocol smoke checks passed/);
  assert.match(comment, /\| erlang-27 \| mist \| ✅ Pass \| 7\.0 ms/);
  assert.match(comment, /How to run a real load test/);
  assert.match(comment, /connection-rate/);
  assert.match(comment, /push-round-trip/);
} finally {
  await rm(directory, { recursive: true });
}

console.log("smoke comment checks passed");
