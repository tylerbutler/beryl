import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

import { buildWebSocketUrl, loadConfig } from "./lib/config.js";
import { buildOptions, parseProfile } from "./lib/profile.js";
import { buildSummary, resultMetadata, summaryPath } from "./lib/results.js";
import {
  clientConfigForVu,
  loadScenarioConfig,
} from "./lib/scenario-config.js";
import {
  BoundedRefTombstones,
  ProtocolError,
  RefGenerator,
  decodeFrame,
  decodeReply,
  encodeFrame,
} from "./lib/protocol.js";
import {
  PendingAcknowledgements,
  broadcastGroupTopic,
  durationMilliseconds,
  finalizeClient,
  isForbiddenReply,
  participantId,
  presenceDiffContains,
  replyContainsMarker,
} from "./lib/workload.js";

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
assert.equal(
  buildWebSocketUrl(loadConfig({ TARGET_URL: "ws://example.invalid/socket" })),
  "ws://example.invalid/socket?vsn=2.0.0",
);
assert.equal(
  buildWebSocketUrl(loadConfig({ TARGET_URL: "ws://example.invalid/socket?" })),
  "ws://example.invalid/socket?vsn=2.0.0",
);
assert.equal(
  buildWebSocketUrl(
    loadConfig({
      TARGET_URL: "ws://example.invalid?existing=value",
      WS_PATH: "/socket",
    }),
  ),
  "ws://example.invalid/socket?existing=value&vsn=2.0.0",
);
assert.throws(
  () => loadConfig({ TARGET_URL: "ws://example.invalid?vsn=1.0.0" }),
  /vsn must be 2\.0\.0/,
);

const refs = new RefGenerator();
assert.deepEqual([refs.next(), refs.next(), refs.next()], ["1", "2", "3"]);

const tombstones = new BoundedRefTombstones(2);
tombstones.set("1", { event: "first" });
tombstones.set("2", { event: "second" });
tombstones.set("3", { event: "third" });
assert.equal(tombstones.size, 2);
assert.equal(tombstones.get("1"), undefined);
assert.deepEqual(tombstones.get("2"), { event: "second" });
tombstones.delete("2");
assert.equal(tombstones.size, 1);
tombstones.clear();
assert.equal(tombstones.size, 0);

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

const profile = parseProfile(
  {
    name: "connection-rate",
    exec: "connectionRate",
    executor: {
      executor: "constant-arrival-rate",
      rate: 10,
      timeUnit: "1s",
      duration: "1m",
      preAllocatedVUs: 20,
    },
    thresholds: { checks: ["rate==1"] },
    parameters: { TOPIC: "bench:default" },
  },
  "connection-rate",
);
const options = buildOptions(profile, {
  RATE: "25",
  EXECUTION_SEGMENT: "1/2:1",
  EXECUTION_SEGMENT_SEQUENCE: "0,1/2,1",
});
assert.equal(options.scenarios.workload.executor, "constant-arrival-rate");
assert.equal(options.scenarios.workload.rate, 25);
assert.equal(options.executionSegment, "1/2:1");
assert.throws(() => buildOptions(profile, { RATE: "not-a-rate" }), /RATE/);
assert.throws(
  () =>
    buildOptions(profile, {
      PREALLOCATED_VUS: "20",
      MAX_VUS: "10",
    }),
  /MAX_VUS/,
);

const scenario = loadScenarioConfig(profile, {
  TARGET_URLS: "ws://one.invalid/socket, ws://two.invalid/socket",
  TRANSPORT: "mist",
});
assert.equal(clientConfigForVu(scenario, 1).targetUrl, "ws://one.invalid/socket");
assert.equal(clientConfigForVu(scenario, 2).targetUrl, "ws://two.invalid/socket");
assert.equal(clientConfigForVu(scenario, 3).targetUrl, "ws://one.invalid/socket");
assert.throws(
  () =>
    loadScenarioConfig(profile, {
      TARGET_URLS: "ws://valid.invalid/socket,not-a-websocket-url",
    }),
  /TARGET_URL/,
);

assert.equal(durationMilliseconds("1m"), 60_000);
assert.equal(durationMilliseconds("1500ms"), 1_500);
assert.equal(
  broadcastGroupTopic("bench:broadcast", 0, 1, 5),
  "bench:broadcast:generator-0:group-0",
);
assert.equal(
  broadcastGroupTopic("bench:broadcast", 2, 6, 5),
  "bench:broadcast:generator-2:group-1",
);
assert.equal(participantId(2, 7), "generator-2-vu-7");
assert.equal(
  presenceDiffContains({ joins: { alice: {} }, leaves: {} }, "join", "alice"),
  true,
);
assert.equal(
  presenceDiffContains({ joins: { alice: {} }, leaves: {} }, "leave", "alice"),
  false,
);
assert.equal(
  presenceDiffContains({ joins: {}, leaves: { alice: {} } }, "leave", "alice"),
  true,
);
assert.equal(presenceDiffContains({ key: "alice" }, "join", "alice"), false);
assert.equal(presenceDiffContains({ key: "alice" }, "leave", "alice"), false);
assert.equal(replyContainsMarker({ marker: "sent" }, "sent"), true);
assert.equal(replyContainsMarker({ marker: "corrupted" }, "sent"), false);
assert.equal(replyContainsMarker({}, "sent"), false);
assert.equal(replyContainsMarker(null, "sent"), false);
assert.equal(isForbiddenReply("error", { reason: "forbidden" }), true);
assert.equal(isForbiddenReply("ok", { reason: "forbidden" }), false);
assert.equal(isForbiddenReply("error", { reason: "other" }), false);
assert.equal(isForbiddenReply("error", { reason: 403 }), false);

let acknowledgementFinished = false;
const pendingAcknowledgements = new PendingAcknowledgements();
pendingAcknowledgements.add(
  Promise.resolve().then(() => {
    acknowledgementFinished = true;
  }),
);
await pendingAcknowledgements.drain();
assert.equal(acknowledgementFinished, true);

let fallbackCloseCalled = false;
assert.equal(
  await finalizeClient({
    async shutdown() {},
    async close() {
      throw new Error("close must not run after successful shutdown");
    },
  }),
  true,
);
assert.equal(
  await finalizeClient({
    async shutdown() {
      throw new Error("leave failed");
    },
    async close() {
      fallbackCloseCalled = true;
      throw new Error("close failed too");
    },
  }),
  false,
);
assert.equal(fallbackCloseCalled, true);

const idleProfile = parseProfile(
  JSON.parse(
    await readFile(
      new URL("./profiles/idle-connections.json", import.meta.url),
      "utf8",
    ),
  ),
  "idle-connections",
);
const idleConfig = loadScenarioConfig(idleProfile, {
  TARGET_URL: "ws://example.invalid/socket",
});
assert.ok(idleConfig.sessionDurationMs >= durationMilliseconds(idleProfile.executor.duration));
assert.ok(idleConfig.sessionDurationMs > idleConfig.client.heartbeatIntervalMs);
assert.throws(
  () =>
    loadScenarioConfig(idleProfile, {
      TARGET_URL: "ws://example.invalid/socket",
      SESSION_DURATION_MS: "10000",
    }),
  /idle profile duration/,
);
assert.throws(
  () =>
    loadScenarioConfig(idleProfile, {
      TARGET_URL: "ws://example.invalid/socket",
      DURATION: "2m",
    }),
  /idle profile duration/,
);

const effective = {
  targetCount: 2,
  executor: options.scenarios.workload,
  workload: {
    event: "echo",
    topic: "bench:reply",
    broadcast_topic: "bench:broadcast",
    guardrail_topic: "guardrail:forbidden",
  },
  session: { duration_ms: 10_000 },
};
const metadata = resultMetadata("connection-rate", effective, {
  GIT_SHA: "abc123",
  TRANSPORT: "ewe",
  RUNTIME: "OTP 28",
  HARDWARE: "test host",
  SOURCE_IP: "192.0.2.10",
  EXECUTION_SEGMENT: "1/2:1",
  EXECUTION_SEGMENT_SEQUENCE: "0,1/2,1",
  TOKEN: "must-not-appear",
  TARGET_URL: "wss://secret.invalid/socket",
});
assert.equal(metadata.git, "abc123");
assert.equal(metadata.profile, "connection-rate");
assert.equal(metadata.transport, "ewe");
assert.equal(metadata.target_count, 2);
assert.equal(metadata.executor.rate, 25);
assert.equal(metadata.session.duration_ms, 10_000);
assert.equal(metadata.workload.topic, "bench:reply");
assert.equal(metadata.workload.broadcast_topic, "bench:broadcast");
assert.equal(metadata.workload.guardrail_topic, "guardrail:forbidden");
assert.equal(metadata.segmentation.execution_segment, "1/2:1");
assert.equal(metadata.segmentation.execution_segment_sequence, "0,1/2,1");
assert.doesNotMatch(JSON.stringify(metadata), /must-not-appear|secret\.invalid/);
assert.equal(summaryPath("connection-rate", {}), "load/results/connection-rate-summary.json");
assert.deepEqual(
  buildSummary(
    { metrics: {} },
    "connection-rate",
    effective,
    { GIT_SHA: "abc123" },
  ).result,
  { metrics: {} },
);

console.log("k6 pure helper checks passed");
