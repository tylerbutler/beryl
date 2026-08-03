import { check } from "k6";
import http from "k6/http";

import { clientMetrics } from "../lib/metrics.js";
import { PhoenixClient, PhoenixReplyError } from "../lib/phoenix.js";
import { clientConfigForVu } from "../lib/scenario-config.js";
import {
  PendingAcknowledgements,
  broadcastGroupTopic,
  finalizeClient,
  isForbiddenReply,
  participantId,
  presenceDiffContains,
  replyContainsMarker,
} from "../lib/workload.js";

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function identity(label) {
  return `${label}-${__VU}-${__ITER}-${Date.now()}`;
}

function clientFor(config, operation, allowedErrorTypes = []) {
  const client = new PhoenixClient(clientConfigForVu(config, __VU), {
    tags: { scenario_operation: operation },
  });
  const allowed = new Set(allowedErrorTypes);
  client.unexpectedScenarioErrors = [];
  client.onError((error, type) => {
    if (allowed.has(type)) return;
    client.unexpectedScenarioErrors.push({ error, type });
    clientMetrics.unexpectedError(type, client.tags);
  });
  return client;
}

function includeShutdown(success, shutdownOk, client) {
  if (!shutdownOk) {
    clientMetrics.scenarioOperation(false, "shutdown", client.tags);
  }
  return success && shutdownOk;
}

function includeClientErrors(success, client) {
  const errorFree = client.unexpectedScenarioErrors.length === 0;
  check(errorFree, {
    "no unexpected asynchronous client errors": (value) => value,
  });
  return success && errorFree;
}

function messagePromise(client, predicate, timeoutMs) {
  return new Promise((resolve) => {
    let settled = false;
    let timer = null;
    const unsubscribe = client.onMessage((frame) => {
      if (settled || !predicate(frame)) return;
      settled = true;
      if (timer !== null) clearTimeout(timer);
      unsubscribe();
      resolve({ delivered: true, frame });
    });
    timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      unsubscribe();
      resolve({ delivered: false, frame: null });
    }, timeoutMs);
  });
}

async function connectedClient(config, operation, topic = config.topic) {
  const client = clientFor(config, operation);
  await client.connect();
  await client.join(topic, { vu: __VU });
  return client;
}

export async function protocolSmoke(config) {
  const operation = "protocol_smoke";
  const client = clientFor(config, operation);
  const marker = identity("smoke");
  let success = false;
  try {
    await client.connect();
    await client.join(config.topic, { marker });
    const response = await client.push(config.topic, config.event, { marker });
    success = replyContainsMarker(response, marker);
  } catch {
    success = false;
  }
  success = includeShutdown(success, await finalizeClient(client), client);
  success = includeClientErrors(success, client);
  check(success, { "protocol lifecycle succeeds": (value) => value });
  clientMetrics.scenarioOperation(success, operation, client.tags);
}

export async function idleConnections(config) {
  const operation = "idle_connection";
  const client = clientFor(config, operation);
  let success = false;
  try {
    await client.connect();
    if (config.topic) await client.join(config.topic, { vu: __VU });
    await delay(config.sessionDurationMs);
    success = client.state === "open";
  } catch {
    success = false;
  }
  success = includeShutdown(success, await finalizeClient(client), client);
  success = includeClientErrors(success, client);
  check(success, { "idle session remains healthy": (value) => value });
  clientMetrics.scenarioOperation(success, operation, client.tags);
}

export async function connectionRate(config) {
  const operation = "connection_open";
  const client = clientFor(config, operation);
  let success = false;
  try {
    await client.connect();
    success = true;
  } catch {
    success = false;
  }
  success = includeShutdown(success, await finalizeClient(client), client);
  success = includeClientErrors(success, client);
  check(success, { "connection opens successfully": (value) => value });
  clientMetrics.scenarioOperation(success, operation, client.tags);
}

export async function pushRoundTrip(config) {
  const operation = "push_round_trip";
  const client = clientFor(config, operation);
  let success = true;
  let operations = 0;
  try {
    await client.connect();
    await client.join(config.topic, { vu: __VU });
    const deadline = Date.now() + config.sessionDurationMs;
    do {
      const marker = identity("reply");
      const response = await client.push(config.topic, config.event, { marker });
      const replyOk = replyContainsMarker(response, marker);
      operations += 1;
      clientMetrics.scenarioOperation(replyOk, operation, client.tags);
      success = success && replyOk;
      if (config.operationIntervalMs) await delay(config.operationIntervalMs);
    } while (success && Date.now() < deadline);
  } catch {
    success = false;
    clientMetrics.scenarioOperation(false, operation, client.tags);
  }
  success = includeShutdown(success, await finalizeClient(client), client);
  success = includeClientErrors(success, client);
  check(success && operations > 0, {
    "pushes receive ok replies": (value) => value,
  });
}

export async function broadcastFanout(config) {
  const operation = "broadcast_fanout";
  const client = clientFor(config, operation);
  const participant = participantId(config.loadGeneratorIndex, __VU);
  const topic = broadcastGroupTopic(
    config.broadcastTopic,
    config.loadGeneratorIndex,
    __VU,
    config.broadcastGroupSize,
  );
  let success = true;
  let operations = 0;
  let acknowledgementsHealthy = true;
  const acknowledgementPushes = new PendingAcknowledgements();
  let stopPeerHandler = () => {};
  try {
    await client.connect();
    await client.join(topic, { participant });
    stopPeerHandler = client.onMessage((frame) => {
      if (
        frame.topic !== topic ||
        frame.event !== config.broadcastDeliveryEvent ||
        frame.payload?.publisher_id === participant
      ) {
        return;
      }
      const sentAt = Number(frame.payload?.sent_at);
      const duration = Number.isFinite(sentAt) ? Date.now() - sentAt : 0;
      clientMetrics.broadcastDelivery(duration, true, client.tags);
      const acknowledgement = client
        .push(topic, config.broadcastAckEvent, {
          marker: frame.payload?.marker,
          publisher_id: frame.payload?.publisher_id,
          recipient_id: participant,
          sent_at: frame.payload?.sent_at,
        })
        .catch(() => {
          acknowledgementsHealthy = false;
          clientMetrics.scenarioOperation(false, "broadcast_ack", client.tags);
        });
      acknowledgementPushes.add(acknowledgement);
    });
    await delay(config.broadcastWarmupMs);
    const deadline = Date.now() + config.sessionDurationMs;
    do {
      const marker = `${participant}-${identity("broadcast")}`;
      const sentAt = Date.now();
      const recipients = new Set();
      const delivery = messagePromise(
        client,
        (frame) => {
          if (
            frame.topic !== topic ||
            frame.event !== config.broadcastAckEvent ||
            frame.payload?.marker !== marker ||
            frame.payload?.publisher_id !== participant ||
            frame.payload?.recipient_id === participant
          ) {
            return false;
          }
          recipients.add(frame.payload.recipient_id);
          return recipients.size >= config.broadcastExpectedRecipients;
        },
        config.deliveryTimeoutMs,
      );
      await client.push(topic, config.broadcastEvent, {
        marker,
        publisher_id: participant,
        sent_at: sentAt,
      });
      const delivered = (await delivery).delivered;
      if (!delivered) {
        clientMetrics.broadcastDelivery(0, false, client.tags);
        success = false;
      }
      operations += 1;
      clientMetrics.scenarioOperation(delivered, operation, client.tags);
      if (config.operationIntervalMs) await delay(config.operationIntervalMs);
    } while (success && Date.now() < deadline);
  } catch {
    clientMetrics.broadcastDelivery(0, false, client.tags);
    clientMetrics.scenarioOperation(false, operation, client.tags);
    success = false;
  }
  stopPeerHandler();
  await acknowledgementPushes.drain();
  success = success && acknowledgementsHealthy;
  success = includeShutdown(success, await finalizeClient(client), client);
  success = includeClientErrors(success, client);
  check(success && operations > 0, {
    "broadcast deliveries are observed": (value) => value,
  });
}

export async function presenceChurn(config) {
  const operation = "presence_churn";
  const client = clientFor(config, operation);
  let success = true;
  let operations = 0;
  try {
    await client.connect();
    await client.join(config.topic, { vu: __VU });
    const deadline = Date.now() + config.sessionDurationMs;
    do {
      const key = `${participantId(config.loadGeneratorIndex, __VU)}-${identity(
        "presence",
      )}`;
      for (const [kind, event] of [
        ["join", config.presenceTrackEvent],
        ["leave", config.presenceUntrackEvent],
      ]) {
        const startedAt = Date.now();
        const delivery = messagePromise(
          client,
          (frame) =>
            frame.topic === config.topic &&
            frame.event === config.presenceDeliveryEvent &&
            presenceDiffContains(frame.payload, kind, key),
          config.deliveryTimeoutMs,
        );
        await client.push(config.topic, event, { key, meta: { vu: __VU } });
        const observed = (await delivery).delivered;
        clientMetrics.presenceDelivery(
          kind,
          Date.now() - startedAt,
          observed,
          client.tags,
        );
        clientMetrics.scenarioOperation(observed, operation, client.tags);
        operations += 1;
        if (!observed) throw new Error(`presence ${kind} was not observed`);
      }
      if (config.operationIntervalMs) await delay(config.operationIntervalMs);
    } while (Date.now() < deadline);
  } catch {
    success = false;
    clientMetrics.scenarioOperation(false, operation, client.tags);
  }
  success = includeShutdown(success, await finalizeClient(client), client);
  success = includeClientErrors(success, client);
  check(success && operations > 0, {
    "presence joins and leaves are observed": (value) => value,
  });
}

export async function mixedWsHttp(config) {
  const operation = "mixed_ws_http";
  const client = clientFor(config, operation);
  let success = true;
  let operations = 0;
  try {
    await client.connect();
    await client.join(config.topic, { vu: __VU });
    const deadline = Date.now() + config.sessionDurationMs;
    do {
      const marker = identity("mixed");
      const reply = await client.push(config.topic, config.event, { marker });
      const replyOk = replyContainsMarker(reply, marker);
      const httpResponse = http.get(config.httpTargetUrl, {
        tags: { operation: "mixed_http", transport: config.client.transport },
      });
      const operationOk =
        replyOk && httpResponse.status >= 200 && httpResponse.status < 400;
      clientMetrics.scenarioOperation(operationOk, operation, client.tags);
      success = success && operationOk;
      operations += 1;
      if (config.operationIntervalMs) await delay(config.operationIntervalMs);
    } while (success && Date.now() < deadline);
  } catch {
    success = false;
    clientMetrics.scenarioOperation(false, operation, client.tags);
  }
  success = includeShutdown(success, await finalizeClient(client), client);
  success = includeClientErrors(success, client);
  check(success && operations > 0, {
    "mixed WebSocket and HTTP operations succeed": (value) => value,
  });
}

export async function guardrailValidation(config) {
  const operation = "guardrail_rejection";
  const client = clientFor(config, operation, ["join_rejected"]);
  let rejected = false;
  try {
    await client.connect();
    await client.join(config.guardrailTopic, {
      guardrail_probe: true,
      vu: __VU,
    });
  } catch (error) {
    rejected =
      error instanceof PhoenixReplyError &&
      isForbiddenReply(error.status, error.response);
  }
  rejected = includeShutdown(rejected, await finalizeClient(client), client);
  rejected = includeClientErrors(rejected, client);
  check(rejected, { "guardrail rejects the probe": (value) => value });
  clientMetrics.scenarioOperation(rejected, operation, client.tags);
  if (config.operationIntervalMs) await delay(config.operationIntervalMs);
}

export { connectedClient, delay, messagePromise };
