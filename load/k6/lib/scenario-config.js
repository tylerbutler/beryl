import { loadConfig } from "./config.js";
import { durationMilliseconds } from "./workload.js";

function text(env, parameters, name, fallback = "") {
  const value = env[name] ?? parameters[name] ?? fallback;
  return String(value).trim();
}

function integer(env, parameters, name, fallback, minimum = 0) {
  const raw = text(env, parameters, name, fallback);
  if (!/^\d+$/.test(raw)) throw new Error(`${name} must be an integer`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum) {
    throw new Error(`${name} must be at least ${minimum}`);
  }
  return value;
}

function targetUrls(env) {
  const raw = text(env, {}, "TARGET_URLS", env.TARGET_URL ?? "");
  const urls = raw.split(",").map((url) => url.trim()).filter(Boolean);
  if (urls.length === 0) throw new Error("TARGET_URL or TARGET_URLS is required");
  return urls;
}

export function loadScenarioConfig(profile, env = globalThis.__ENV ?? {}) {
  const parameters = profile.parameters ?? {};
  const targets = targetUrls(env);
  for (const target of targets) {
    loadConfig({ ...env, TARGET_URL: target });
  }
  const client = loadConfig({ ...env, TARGET_URL: targets[0] });
  const config = {
    client,
    targets: Object.freeze(targets),
    profile: profile.name,
    topic: text(env, parameters, "TOPIC", "bench:lobby"),
    broadcastTopic: text(
      env,
      parameters,
      "BROADCAST_TOPIC",
      "bench:broadcast",
    ),
    event: text(env, parameters, "EVENT", "echo"),
    broadcastEvent: text(env, parameters, "BROADCAST_EVENT", "broadcast"),
    broadcastDeliveryEvent: text(
      env,
      parameters,
      "BROADCAST_DELIVERY_EVENT",
      "broadcast",
    ),
    broadcastAckEvent: text(
      env,
      parameters,
      "BROADCAST_ACK_EVENT",
      "broadcast_ack",
    ),
    presenceTrackEvent: text(
      env,
      parameters,
      "PRESENCE_TRACK_EVENT",
      "presence_track",
    ),
    presenceUntrackEvent: text(
      env,
      parameters,
      "PRESENCE_UNTRACK_EVENT",
      "presence_untrack",
    ),
    presenceDeliveryEvent: text(
      env,
      parameters,
      "PRESENCE_DELIVERY_EVENT",
      "presence_diff",
    ),
    guardrailTopic: text(
      env,
      parameters,
      "GUARDRAIL_TOPIC",
      "guardrail:forbidden",
    ),
    httpTargetUrl: text(env, parameters, "HTTP_TARGET_URL"),
    sessionDurationMs: integer(
      env,
      parameters,
      "SESSION_DURATION_MS",
      10_000,
      1,
    ),
    operationIntervalMs: integer(
      env,
      parameters,
      "OPERATION_INTERVAL_MS",
      250,
      0,
    ),
    deliveryTimeoutMs: integer(
      env,
      parameters,
      "DELIVERY_TIMEOUT_MS",
      client.replyTimeoutMs,
      1,
    ),
    loadGeneratorIndex: integer(
      env,
      parameters,
      "LOAD_GENERATOR_INDEX",
      0,
      0,
    ),
    broadcastGroupSize: integer(
      env,
      parameters,
      "BROADCAST_GROUP_SIZE",
      5,
      2,
    ),
    broadcastExpectedRecipients: integer(
      env,
      parameters,
      "BROADCAST_EXPECTED_RECIPIENTS",
      1,
      1,
    ),
    broadcastWarmupMs: integer(
      env,
      parameters,
      "BROADCAST_WARMUP_MS",
      2_000,
      0,
    ),
  };
  if (profile.name === "mixed-ws-http" && !config.httpTargetUrl) {
    throw new Error("HTTP_TARGET_URL is required by mixed-ws-http");
  }
  if (config.broadcastExpectedRecipients >= config.broadcastGroupSize) {
    throw new Error(
      "BROADCAST_EXPECTED_RECIPIENTS must be less than BROADCAST_GROUP_SIZE",
    );
  }
  if (profile.name === "idle-connections") {
    const testDurationMs = durationMilliseconds(
      env.DURATION ?? profile.executor.duration,
    );
    if (config.sessionDurationMs < testDurationMs) {
      throw new Error(
        "SESSION_DURATION_MS must be at least the idle profile duration",
      );
    }
    if (
      config.client.heartbeatIntervalMs === 0 ||
      config.sessionDurationMs <= config.client.heartbeatIntervalMs
    ) {
      throw new Error(
        "idle sessions must exceed a non-zero HEARTBEAT_INTERVAL_MS",
      );
    }
  }
  return Object.freeze(config);
}

export function clientConfigForVu(config, vu) {
  const index =
    (Math.max(vu, 1) - 1 + config.loadGeneratorIndex) % config.targets.length;
  return Object.freeze({ ...config.client, targetUrl: config.targets[index] });
}
