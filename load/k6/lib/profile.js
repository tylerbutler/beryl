const PROFILE_NAMES = Object.freeze([
  "protocol-smoke",
  "idle-connections",
  "connection-rate",
  "push-round-trip",
  "broadcast-fanout",
  "presence-churn",
  "mixed-ws-http",
  "guardrail-validation",
]);

function positiveInteger(value, name) {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new Error(`${name} must be a positive integer`);
  }
}

export function parseProfile(document, expectedName) {
  let profile;
  try {
    profile = typeof document === "string" ? JSON.parse(document) : document;
  } catch (error) {
    throw new Error(`profile is not valid JSON: ${error.message}`);
  }
  if (!profile || typeof profile !== "object" || Array.isArray(profile)) {
    throw new Error("profile must be a JSON object");
  }
  if (!PROFILE_NAMES.includes(profile.name) || profile.name !== expectedName) {
    throw new Error(`profile name must be ${expectedName}`);
  }
  if (typeof profile.exec !== "string" || profile.exec.length === 0) {
    throw new Error("profile exec must be a non-empty string");
  }
  const executor = profile.executor;
  if (!executor || typeof executor !== "object" || Array.isArray(executor)) {
    throw new Error("profile executor must be an object");
  }
  const supported = [
    "constant-vus",
    "per-vu-iterations",
    "constant-arrival-rate",
  ];
  if (!supported.includes(executor.executor)) {
    throw new Error(`unsupported executor ${executor.executor}`);
  }
  if (executor.executor === "constant-arrival-rate") {
    positiveInteger(executor.rate, "executor.rate");
    positiveInteger(executor.preAllocatedVUs, "executor.preAllocatedVUs");
  } else {
    positiveInteger(executor.vus, "executor.vus");
  }
  if (
    !profile.thresholds ||
    typeof profile.thresholds !== "object" ||
    Array.isArray(profile.thresholds)
  ) {
    throw new Error("profile thresholds must be an object");
  }
  for (const expressions of Object.values(profile.thresholds)) {
    if (
      !Array.isArray(expressions) ||
      expressions.length === 0 ||
      expressions.some((expression) => typeof expression !== "string")
    ) {
      throw new Error("each profile threshold must be a non-empty string array");
    }
  }
  return Object.freeze(profile);
}

export function buildOptions(profile, env = {}) {
  const executor = { ...profile.executor };
  if (env.DURATION) executor.duration = env.DURATION;
  if (executor.executor === "constant-arrival-rate") {
    if (env.RATE) {
      executor.rate = Number(env.RATE);
      positiveInteger(executor.rate, "RATE");
    }
    if (env.PREALLOCATED_VUS) {
      executor.preAllocatedVUs = Number(env.PREALLOCATED_VUS);
      positiveInteger(executor.preAllocatedVUs, "PREALLOCATED_VUS");
    }
    if (env.MAX_VUS) {
      executor.maxVUs = Number(env.MAX_VUS);
      positiveInteger(executor.maxVUs, "MAX_VUS");
    }
    if (
      executor.maxVUs !== undefined &&
      executor.maxVUs < executor.preAllocatedVUs
    ) {
      throw new Error("MAX_VUS must be at least PREALLOCATED_VUS");
    }
  } else if (env.VUS) {
    executor.vus = Number(env.VUS);
    positiveInteger(executor.vus, "VUS");
  }
  executor.exec = profile.exec;

  const options = {
    scenarios: { workload: executor },
    thresholds: profile.thresholds,
    tags: { profile: profile.name },
    discardResponseBodies: true,
  };
  if (env.EXECUTION_SEGMENT) {
    options.executionSegment = env.EXECUTION_SEGMENT;
  }
  if (env.EXECUTION_SEGMENT_SEQUENCE) {
    options.executionSegmentSequence = env.EXECUTION_SEGMENT_SEQUENCE;
  }
  return options;
}

export { PROFILE_NAMES };
