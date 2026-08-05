import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";

import { PROFILE_NAMES, buildOptions, parseProfile } from "./lib/profile.js";
import { durationMilliseconds } from "./lib/workload.js";

const directory = new URL("./profiles/", import.meta.url);
const filenames = (await readdir(directory))
  .filter((name) => name.endsWith(".json"))
  .sort();

assert.deepEqual(
  filenames,
  PROFILE_NAMES.map((name) => `${name}.json`).sort(),
);

for (const filename of filenames) {
  const name = filename.slice(0, -5);
  const document = await readFile(new URL(filename, directory), "utf8");
  const profile = parseProfile(document, name);
  const options = buildOptions(profile);
  assert.equal(options.scenarios.workload.exec, profile.exec);
  assert.deepEqual(
    profile.thresholds.phoenix_unexpected_client_errors,
    ["count==0"],
  );
  assert.deepEqual(profile.thresholds.phoenix_protocol_errors, ["count==0"]);
  assert.deepEqual(profile.thresholds.phoenix_decode_errors, ["count==0"]);
  if (name !== "guardrail-validation") {
    assert.deepEqual(profile.thresholds.phoenix_client_errors, ["count==0"]);
  } else {
    assert.equal(
      Object.hasOwn(profile.thresholds, "phoenix_client_errors"),
      false,
    );
  }

  const thresholdText = JSON.stringify(profile.thresholds);
  assert.doesNotMatch(thresholdText, /p\(\d+\)|avg|max|min|med/i);
}

const baseline = JSON.parse(
  await readFile(new URL("./baseline-metadata.json", import.meta.url), "utf8"),
);
for (const field of [
  "git",
  "transport",
  "runtime",
  "hardware",
  "source_ip",
  "profile",
]) {
  assert.ok(Object.hasOwn(baseline, field), `baseline metadata lacks ${field}`);
}
assert.ok(baseline.executor);
assert.ok(baseline.workload);
assert.ok(baseline.session);
assert.ok(baseline.segmentation.execution_segment_sequence);
assert.equal(Object.hasOwn(baseline, "target_count"), true);

const idle = JSON.parse(
  await readFile(new URL("./profiles/idle-connections.json", import.meta.url)),
);
assert.equal(idle.executor.executor, "constant-vus");
assert.ok(
  idle.parameters.SESSION_DURATION_MS >
    durationMilliseconds(idle.executor.duration),
);
assert.ok(idle.parameters.SESSION_DURATION_MS > 30_000);

const broadcast = JSON.parse(
  await readFile(new URL("./profiles/broadcast-fanout.json", import.meta.url)),
);
assert.equal(broadcast.executor.executor, "constant-vus");
assert.equal(
  broadcast.parameters.BROADCAST_EXPECTED_RECIPIENTS,
  broadcast.parameters.BROADCAST_GROUP_SIZE - 1,
);
assert.ok(broadcast.parameters.BROADCAST_ACK_EVENT);
assert.equal(
  Object.hasOwn(broadcast.parameters, "BROADCAST_EXPECT_SELF"),
  false,
);

const connectionRate = JSON.parse(
  await readFile(new URL("./profiles/connection-rate.json", import.meta.url)),
);
assert.equal(connectionRate.executor.executor, "constant-arrival-rate");

const justfile = await readFile(
  new URL("../../justfile", import.meta.url),
  "utf8",
);
for (const name of [
  "VUS",
  "RATE",
  "DURATION",
  "PREALLOCATED_VUS",
  "MAX_VUS",
  "WS_PATH",
  "TOKEN",
  "TOKEN_PARAM",
  "TOPICS",
  "CONNECT_TIMEOUT_MS",
  "REPLY_TIMEOUT_MS",
  "LEAVE_TIMEOUT_MS",
  "HEARTBEAT_INTERVAL_MS",
  "HEARTBEAT_TIMEOUT_MS",
  "EXPIRED_REF_LIMIT",
  "TOPIC",
  "EVENT",
  "HTTP_TARGET_URL",
  "SESSION_DURATION_MS",
  "OPERATION_INTERVAL_MS",
  "DELIVERY_TIMEOUT_MS",
  "BROADCAST_TOPIC",
  "BROADCAST_EVENT",
  "BROADCAST_DELIVERY_EVENT",
  "BROADCAST_ACK_EVENT",
  "BROADCAST_GROUP_SIZE",
  "BROADCAST_EXPECTED_RECIPIENTS",
  "BROADCAST_WARMUP_MS",
  "PRESENCE_TRACK_EVENT",
  "PRESENCE_UNTRACK_EVENT",
  "PRESENCE_DELIVERY_EVENT",
  "GUARDRAIL_TOPIC",
  "GIT_SHA",
  "RUNTIME",
  "HARDWARE",
  "SOURCE_IP",
  "CLUSTER",
  "LOAD_GENERATOR",
  "LOAD_GENERATOR_INDEX",
  "LOAD_GENERATOR_COUNT",
  "EXECUTION_SEGMENT",
  "EXECUTION_SEGMENT_SEQUENCE",
  "TARGET_LABEL",
  "RUN_ID",
  "SUMMARY_PATH",
]) {
  assert.match(justfile, new RegExp(`-e ${name}(?: |$)`));
}

console.log(`validated ${filenames.length} k6 profiles and baseline metadata`);
