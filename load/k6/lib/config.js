const DEFAULTS = Object.freeze({
  path: "",
  token: "",
  tokenParam: "token",
  topics: [],
  transport: "unknown",
  connectTimeoutMs: 10_000,
  replyTimeoutMs: 5_000,
  leaveTimeoutMs: 2_000,
  heartbeatIntervalMs: 30_000,
  heartbeatTimeoutMs: 5_000,
  expiredRefLimit: 256,
});

function integer(env, name, fallback, minimum) {
  const raw = env[name];
  if (raw === undefined || raw === "") {
    return fallback;
  }
  if (!/^\d+$/.test(raw)) {
    throw new Error(`${name} must be an integer`);
  }
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed) || parsed < minimum) {
    throw new Error(`${name} must be at least ${minimum}`);
  }
  return parsed;
}

function text(env, name, fallback) {
  const value = env[name];
  return value === undefined ? fallback : value.trim();
}

function targetUrl(value) {
  const url = value.trim();
  if (!/^wss?:\/\/[^/\s]+(?:[/?#].*)?$/i.test(url)) {
    throw new Error("TARGET_URL must be an absolute ws:// or wss:// URL");
  }
  if (url.includes("#")) {
    throw new Error("TARGET_URL must not contain a URL fragment");
  }
  return url;
}

function path(value) {
  if (value === "") {
    return "";
  }
  if (!value.startsWith("/") || value.includes("?") || value.includes("#")) {
    throw new Error("WS_PATH must start with / and contain no query or fragment");
  }
  return value;
}

function topics(value) {
  if (value.trim() === "") {
    return [];
  }
  const parsed = value
    .split(",")
    .map((topic) => topic.trim())
    .filter(Boolean);
  if (parsed.length === 0) {
    throw new Error("TOPICS must contain at least one topic");
  }
  return parsed;
}

export function buildWebSocketUrl(config) {
  let url = config.targetUrl;
  if (config.path) {
    const queryIndex = url.indexOf("?");
    const base = queryIndex === -1 ? url : url.slice(0, queryIndex);
    const query = queryIndex === -1 ? "" : url.slice(queryIndex);
    url = `${base.replace(/\/+$/, "")}${config.path}${query}`;
  }
  if (config.token) {
    const separator = url.includes("?") ? "&" : "?";
    url += `${separator}${encodeURIComponent(config.tokenParam)}=${encodeURIComponent(
      config.token,
    )}`;
  }

  const queryIndex = url.indexOf("?");
  if (queryIndex === -1) {
    return `${url}?vsn=2.0.0`;
  }

  const query = url.slice(queryIndex + 1);
  let hasVersion = false;
  for (const part of query.split("&")) {
    if (part === "") continue;
    const [rawKey, ...rawValueParts] = part.split("=");
    let key;
    let value;
    try {
      key = decodeURIComponent(rawKey);
      value = decodeURIComponent(rawValueParts.join("="));
    } catch {
      throw new Error("TARGET_URL contains an invalid query encoding");
    }
    if (key === "vsn") {
      hasVersion = true;
      if (value !== "2.0.0") {
        throw new Error("TARGET_URL vsn must be 2.0.0");
      }
    }
  }

  if (hasVersion) {
    return url;
  }
  return query === "" ? `${url}vsn=2.0.0` : `${url}&vsn=2.0.0`;
}

export function loadConfig(env = globalThis.__ENV ?? {}) {
  const rawTarget = text(env, "TARGET_URL", "");
  if (rawTarget === "") {
    throw new Error("TARGET_URL is required");
  }

  const config = {
    targetUrl: targetUrl(rawTarget),
    path: path(text(env, "WS_PATH", DEFAULTS.path)),
    token: text(env, "TOKEN", DEFAULTS.token),
    tokenParam: text(env, "TOKEN_PARAM", DEFAULTS.tokenParam),
    topics: topics(text(env, "TOPICS", "")),
    transport: text(env, "TRANSPORT", DEFAULTS.transport),
    connectTimeoutMs: integer(
      env,
      "CONNECT_TIMEOUT_MS",
      DEFAULTS.connectTimeoutMs,
      1,
    ),
    replyTimeoutMs: integer(env, "REPLY_TIMEOUT_MS", DEFAULTS.replyTimeoutMs, 1),
    leaveTimeoutMs: integer(env, "LEAVE_TIMEOUT_MS", DEFAULTS.leaveTimeoutMs, 1),
    heartbeatIntervalMs: integer(
      env,
      "HEARTBEAT_INTERVAL_MS",
      DEFAULTS.heartbeatIntervalMs,
      0,
    ),
    heartbeatTimeoutMs: integer(
      env,
      "HEARTBEAT_TIMEOUT_MS",
      DEFAULTS.heartbeatTimeoutMs,
      1,
    ),
    expiredRefLimit: integer(
      env,
      "EXPIRED_REF_LIMIT",
      DEFAULTS.expiredRefLimit,
      1,
    ),
  };

  if (!config.tokenParam) {
    throw new Error("TOKEN_PARAM must not be empty");
  }
  if (!config.transport) {
    throw new Error("TRANSPORT must not be empty");
  }
  if (
    config.heartbeatIntervalMs > 0 &&
    config.heartbeatTimeoutMs >= config.heartbeatIntervalMs
  ) {
    throw new Error(
      "HEARTBEAT_TIMEOUT_MS must be less than HEARTBEAT_INTERVAL_MS",
    );
  }

  buildWebSocketUrl(config);
  return Object.freeze({ ...config, topics: Object.freeze(config.topics) });
}

export { DEFAULTS };
