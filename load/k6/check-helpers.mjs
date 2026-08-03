import assert from "node:assert/strict";

import { buildWebSocketUrl, loadConfig } from "./lib/config.js";
import {
  ProtocolError,
  RefGenerator,
  decodeFrame,
  decodeReply,
  encodeFrame,
} from "./lib/protocol.js";

const config = loadConfig({
  TARGET_URL: "wss://example.invalid/socket?vsn=2.0.0",
  TOKEN: "a token",
  TOPICS: "bench:one, bench:two",
  HEARTBEAT_INTERVAL_MS: "10000",
  HEARTBEAT_TIMEOUT_MS: "1000",
});
assert.equal(
  buildWebSocketUrl(config),
  "wss://example.invalid/socket?vsn=2.0.0&token=a%20token",
);
assert.deepEqual(config.topics, ["bench:one", "bench:two"]);

const refs = new RefGenerator();
assert.deepEqual([refs.next(), refs.next(), refs.next()], ["1", "2", "3"]);

const encoded = encodeFrame("1", "2", "bench:one", "echo", { value: 42 });
assert.deepEqual(decodeFrame(encoded), {
  joinRef: "1",
  ref: "2",
  topic: "bench:one",
  event: "echo",
  payload: { value: 42 },
});
assert.deepEqual(
  decodeReply(["1", "2", "bench:one", "phx_reply", {
    status: "ok",
    response: { value: 42 },
  }]).response,
  { value: 42 },
);
assert.throws(() => decodeFrame('["too","short"]'), ProtocolError);
assert.throws(
  () => decodeReply(["1", "2", "bench:one", "phx_reply", { response: {} }]),
  ProtocolError,
);
assert.throws(() => loadConfig({ TARGET_URL: "https://example.invalid" }));
assert.throws(
  () =>
    loadConfig({
      TARGET_URL: "ws://example.invalid",
      HEARTBEAT_INTERVAL_MS: "1000",
      HEARTBEAT_TIMEOUT_MS: "1000",
    }),
  /HEARTBEAT_TIMEOUT_MS/,
);

console.log("k6 pure helper checks passed");
