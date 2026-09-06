export function durationMilliseconds(value) {
  const match = /^(\d+)(ms|s|m|h)$/.exec(String(value).trim());
  if (!match) throw new Error(`invalid duration ${value}`);
  const multipliers = { ms: 1, s: 1_000, m: 60_000, h: 3_600_000 };
  return Number(match[1]) * multipliers[match[2]];
}

export function participantId(loadGeneratorIndex, vu) {
  return `generator-${loadGeneratorIndex}-vu-${vu}`;
}

export function broadcastGroupTopic(
  baseTopic,
  loadGeneratorIndex,
  vu,
  groupSize,
) {
  const group = Math.floor((Math.max(vu, 1) - 1) / groupSize);
  return `${baseTopic}:generator-${loadGeneratorIndex}:group-${group}`;
}

export function presenceDiffContains(payload, kind, key) {
  const entries = kind === "join" ? payload?.joins : payload?.leaves;
  return (
    entries !== null &&
    typeof entries === "object" &&
    Object.prototype.hasOwnProperty.call(entries, key)
  );
}

export function replyContainsMarker(response, marker) {
  return (
    response !== null &&
    typeof response === "object" &&
    response.marker === marker
  );
}

export function isForbiddenReply(status, response) {
  return (
    typeof status === "string" &&
    status !== "ok" &&
    response !== null &&
    typeof response === "object" &&
    typeof response.reason === "string" &&
    response.reason === "forbidden"
  );
}

export class PendingAcknowledgements {
  constructor() {
    this.promises = [];
  }

  add(promise) {
    this.promises.push(promise);
  }

  async drain() {
    await Promise.all(this.promises);
  }
}

export async function finalizeClient(client) {
  try {
    await client.shutdown();
    return true;
  } catch {
    try {
      await client.close();
    } catch {
      // Best-effort cleanup does not change the recorded shutdown failure.
    }
    return false;
  }
}
