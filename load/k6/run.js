import {
  buildOptions,
  parseProfile,
  PROFILE_NAMES,
} from "./lib/profile.js";
import { buildSummary, summaryPath } from "./lib/results.js";
import { loadScenarioConfig } from "./lib/scenario-config.js";
import * as workloads from "./scenarios/workloads.js";

const documents = Object.freeze({
  "protocol-smoke": open("./profiles/protocol-smoke.json"),
  "idle-connections": open("./profiles/idle-connections.json"),
  "connection-rate": open("./profiles/connection-rate.json"),
  "push-round-trip": open("./profiles/push-round-trip.json"),
  "broadcast-fanout": open("./profiles/broadcast-fanout.json"),
  "presence-churn": open("./profiles/presence-churn.json"),
  "mixed-ws-http": open("./profiles/mixed-ws-http.json"),
  "guardrail-validation": open("./profiles/guardrail-validation.json"),
});

const profileName = __ENV.PROFILE || "protocol-smoke";
if (!PROFILE_NAMES.includes(profileName)) {
  throw new Error(`unknown PROFILE ${profileName}`);
}
const profile = parseProfile(documents[profileName], profileName);
const config = loadScenarioConfig(profile);

export const options = buildOptions(profile, __ENV);
const effectiveMetadata = Object.freeze({
  targetCount: config.targets.length,
  executor: Object.freeze({ ...options.scenarios.workload }),
  workload: Object.freeze({
    exec: profile.exec,
    topic: config.topic,
    broadcast_topic: config.broadcastTopic,
    guardrail_topic: config.guardrailTopic,
    topic_group_size: config.broadcastGroupSize,
    expected_broadcast_recipients: config.broadcastExpectedRecipients,
    broadcast_warmup_ms: config.broadcastWarmupMs,
    event: config.event,
    broadcast_event: config.broadcastEvent,
    broadcast_delivery_event: config.broadcastDeliveryEvent,
    broadcast_ack_event: config.broadcastAckEvent,
    presence_track_event: config.presenceTrackEvent,
    presence_untrack_event: config.presenceUntrackEvent,
    presence_delivery_event: config.presenceDeliveryEvent,
  }),
  session: Object.freeze({
    duration_ms: config.sessionDurationMs,
    operation_interval_ms: config.operationIntervalMs,
    delivery_timeout_ms: config.deliveryTimeoutMs,
    connect_timeout_ms: config.client.connectTimeoutMs,
    reply_timeout_ms: config.client.replyTimeoutMs,
    leave_timeout_ms: config.client.leaveTimeoutMs,
    heartbeat_interval_ms: config.client.heartbeatIntervalMs,
    heartbeat_timeout_ms: config.client.heartbeatTimeoutMs,
  }),
});

export async function protocolSmoke() {
  await workloads.protocolSmoke(config);
}
export async function idleConnections() {
  await workloads.idleConnections(config);
}
export async function connectionRate() {
  await workloads.connectionRate(config);
}
export async function pushRoundTrip() {
  await workloads.pushRoundTrip(config);
}
export async function broadcastFanout() {
  await workloads.broadcastFanout(config);
}
export async function presenceChurn() {
  await workloads.presenceChurn(config);
}
export async function mixedWsHttp() {
  await workloads.mixedWsHttp(config);
}
export async function guardrailValidation() {
  await workloads.guardrailValidation(config);
}

export function handleSummary(data) {
  return {
    [summaryPath(profile.name)]: JSON.stringify(
      buildSummary(data, profile.name, effectiveMetadata),
      null,
      2,
    ),
  };
}
