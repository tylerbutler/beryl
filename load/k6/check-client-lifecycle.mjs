import assert from "node:assert/strict";
import { registerHooks } from "node:module";

const sockets = [];

class FakeWebSocket {
  constructor() {
    this.readyState = 0;
    this.listeners = new Map();
    this.sent = [];
    this.closeCalls = [];
    sockets.push(this);
  }

  addEventListener(name, handler) {
    const handlers = this.listeners.get(name) ?? [];
    handlers.push(handler);
    this.listeners.set(name, handlers);
  }

  emit(name, event = {}) {
    for (const handler of this.listeners.get(name) ?? []) {
      handler(event);
    }
  }

  send(data) {
    this.sent.push(data);
  }

  close(code, reason) {
    this.readyState = 2;
    this.closeCalls.push({ code, reason });
  }
}

globalThis.__FakeWebSocket = FakeWebSocket;

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "k6/websockets" || specifier === "k6/metrics") {
      return { shortCircuit: true, url: `mock:${specifier}` };
    }
    return nextResolve(specifier, context);
  },

  load(url, context, nextLoad) {
    if (url === "mock:k6/websockets") {
      return {
        format: "module",
        shortCircuit: true,
        source: "export const WebSocket = globalThis.__FakeWebSocket;",
      };
    }
    if (url === "mock:k6/metrics") {
      return {
        format: "module",
        shortCircuit: true,
        source: `
          class Metric {
            add() {}
          }
          export class Counter extends Metric {}
          export class Gauge extends Metric {}
          export class Rate extends Metric {}
          export class Trend extends Metric {}
        `,
      };
    }
    return nextLoad(url, context);
  },
});

const { loadConfig } = await import("./lib/config.js");
const { PhoenixClient, PhoenixReplyError, PhoenixTimeoutError } =
  await import("./lib/phoenix.js");

function metricRecorder() {
  const calls = {
    closed: 0,
    errors: [],
    timeouts: [],
  };
  return {
    calls,
    metrics: {
      connected() {},
      connectFailed() {},
      closed() {
        calls.closed += 1;
      },
      reply() {},
      rejected() {},
      timeout(kind) {
        calls.timeouts.push(kind);
      },
      lateReply() {},
      decodeError() {},
      error(type) {
        calls.errors.push(type);
      },
      protocolError() {},
      unmatchedReply() {},
    },
  };
}

function testConfig() {
  return loadConfig({
    TARGET_URL: "ws://example.invalid/socket",
    HEARTBEAT_INTERVAL_MS: "0",
    CONNECT_TIMEOUT_MS: "100",
    REPLY_TIMEOUT_MS: "20",
    LEAVE_TIMEOUT_MS: "20",
  });
}

async function open(client) {
  const connecting = client.connect();
  const socket = sockets.at(-1);
  socket.readyState = 1;
  socket.emit("open");
  await connecting;
  return socket;
}

{
  const recorder = metricRecorder();
  const client = new PhoenixClient(testConfig(), { metrics: recorder.metrics });
  client.onError(() => {});
  const socket = await open(client);

  await assert.rejects(
    client._request(null, client.refs.next(), "phoenix", "heartbeat", {}, 1, "heartbeat"),
    PhoenixTimeoutError,
  );
  assert.equal(client.state, "closed");
  assert.equal(client.socket, null);
  assert.deepEqual(socket.closeCalls, [{ code: 1000, reason: "heartbeat timeout" }]);
  assert.deepEqual(recorder.calls.timeouts, ["heartbeat"]);
  assert.deepEqual(recorder.calls.errors, ["heartbeat_timeout"]);
  assert.equal(recorder.calls.closed, 1);

  socket.emit("close", { code: 1000 });
  assert.deepEqual(recorder.calls.errors, ["heartbeat_timeout"]);
  assert.equal(recorder.calls.closed, 1);

  const reconnected = await open(client);
  assert.equal(client.state, "open");
  const closing = client.close();
  reconnected.emit("close", { code: 1000 });
  await closing;
}

{
  const recorder = metricRecorder();
  const client = new PhoenixClient(testConfig(), { metrics: recorder.metrics });
  let closeFromError = null;
  client.onError((_, type) => {
    if (type === "heartbeat_timeout") {
      closeFromError = client.close();
    }
  });
  const socket = await open(client);

  await assert.rejects(
    client._request(null, client.refs.next(), "phoenix", "heartbeat", {}, 1, "heartbeat"),
    PhoenixTimeoutError,
  );
  await closeFromError;

  assert.equal(client.state, "closed");
  assert.equal(client.closeWaiters.length, 0);
  assert.deepEqual(socket.closeCalls, [{ code: 1000, reason: "heartbeat timeout" }]);
  assert.deepEqual(recorder.calls.timeouts, ["heartbeat"]);
  assert.deepEqual(recorder.calls.errors, ["heartbeat_timeout"]);
  assert.equal(recorder.calls.closed, 1);

  socket.emit("close", { code: 1000 });
  assert.deepEqual(recorder.calls.errors, ["heartbeat_timeout"]);
  assert.equal(recorder.calls.closed, 1);
}

{
  const recorder = metricRecorder();
  const client = new PhoenixClient(testConfig(), { metrics: recorder.metrics });
  client.onError(() => {});
  const socket = await open(client);

  const heartbeat = client._request(
    null,
    client.refs.next(),
    "phoenix",
    "heartbeat",
    {},
    50,
    "heartbeat",
  );
  const heartbeatRejected = assert.rejects(heartbeat, /client closing/);
  let closeSettlements = 0;
  const closing = client.close().then(() => {
    closeSettlements += 1;
  });
  socket.emit("close", { code: 1000 });
  await Promise.all([heartbeatRejected, closing]);

  assert.equal(client.state, "closed");
  assert.equal(client.closeWaiters.length, 0);
  assert.equal(closeSettlements, 1);
  assert.deepEqual(recorder.calls.timeouts, []);
  assert.deepEqual(recorder.calls.errors, []);
  assert.equal(recorder.calls.closed, 1);

  socket.emit("close", { code: 1000 });
  await Promise.resolve();
  assert.equal(closeSettlements, 1);
  assert.equal(recorder.calls.closed, 1);
}

{
  const recorder = metricRecorder();
  const client = new PhoenixClient(testConfig(), { metrics: recorder.metrics });
  const observedErrors = [];
  client.onError((error, type) => {
    observedErrors.push({ error, type });
  });
  const socket = await open(client);

  const joining = client.join("guardrail:forbidden", {});
  const [, joinRef] = JSON.parse(socket.sent.at(-1));
  socket.emit("message", {
    data: JSON.stringify([
      joinRef,
      joinRef,
      "guardrail:forbidden",
      "phx_reply",
      { status: "error", response: { reason: "forbidden" } },
    ]),
  });
  const joinError = await joining.catch((error) => error);
  assert.ok(joinError instanceof PhoenixReplyError);
  assert.equal(joinError.status, "error");
  assert.deepEqual(joinError.response, { reason: "forbidden" });
  assert.equal(observedErrors.at(-1).error, joinError);
  assert.equal(observedErrors.at(-1).type, "join_rejected");

  client.channels.set("room:timeout", { joinRef: "join-timeout", state: "joined" });
  await assert.rejects(client.leave("room:timeout", 1), PhoenixTimeoutError);
  assert.equal(client.channels.has("room:timeout"), false);
  await assert.rejects(client.push("room:timeout", "echo", {}), /before joining/);

  client.channels.set("room:rejected", {
    joinRef: "join-rejected",
    state: "joined",
  });
  const leaving = client.leave("room:rejected", 20);
  const [, ref] = JSON.parse(socket.sent.at(-1));
  socket.emit("message", {
    data: JSON.stringify([
      "join-rejected",
      ref,
      "room:rejected",
      "phx_reply",
      { status: "error", response: { reason: "already left" } },
    ]),
  });
  await assert.rejects(leaving, PhoenixReplyError);
  assert.equal(client.channels.has("room:rejected"), false);
  await assert.rejects(client.push("room:rejected", "echo", {}), /before joining/);

  const closing = client.close();
  socket.emit("close", { code: 1000 });
  await closing;
}

console.log("k6 client lifecycle checks passed");
