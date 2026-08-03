const FRAME_LENGTH = 5;
const PHOENIX_REPLY = "phx_reply";

export class ProtocolError extends Error {
  constructor(message, cause) {
    super(message);
    this.name = "ProtocolError";
    if (cause !== undefined) {
      this.cause = cause;
    }
  }
}

export class RefGenerator {
  constructor(initialRef = 0) {
    if (!Number.isSafeInteger(initialRef) || initialRef < 0) {
      throw new TypeError("initialRef must be a non-negative safe integer");
    }
    this.current = initialRef;
  }

  next() {
    if (this.current === Number.MAX_SAFE_INTEGER) {
      throw new RangeError("Phoenix message ref space exhausted");
    }
    this.current += 1;
    return String(this.current);
  }
}

function isRef(value) {
  return (
    value === null ||
    typeof value === "string" ||
    (typeof value === "number" && Number.isSafeInteger(value))
  );
}

function isPayload(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function validateFrame(frame) {
  if (!Array.isArray(frame) || frame.length !== FRAME_LENGTH) {
    throw new ProtocolError("Phoenix V2 frames must be five-element arrays");
  }

  const [joinRef, ref, topic, event, payload] = frame;
  if (!isRef(joinRef)) {
    throw new ProtocolError("frame join_ref must be null, a string, or an integer");
  }
  if (!isRef(ref)) {
    throw new ProtocolError("frame ref must be null, a string, or an integer");
  }
  if (typeof topic !== "string" || topic.length === 0) {
    throw new ProtocolError("frame topic must be a non-empty string");
  }
  if (typeof event !== "string" || event.length === 0) {
    throw new ProtocolError("frame event must be a non-empty string");
  }
  if (!isPayload(payload)) {
    throw new ProtocolError("frame payload must be an object");
  }

  return { joinRef, ref, topic, event, payload };
}

export function encodeFrame(joinRef, ref, topic, event, payload = {}) {
  const frame = [joinRef, ref, topic, event, payload];
  validateFrame(frame);
  return JSON.stringify(frame);
}

export function decodeFrame(data) {
  if (typeof data !== "string") {
    throw new ProtocolError("expected a Phoenix V2 text frame");
  }

  let frame;
  try {
    frame = JSON.parse(data);
  } catch (error) {
    throw new ProtocolError("received invalid JSON", error);
  }
  return validateFrame(frame);
}

export function decodeReply(frame) {
  const decoded = Array.isArray(frame) ? validateFrame(frame) : frame;
  if (decoded.event !== PHOENIX_REPLY) {
    throw new ProtocolError(`expected phx_reply, received ${decoded.event}`);
  }

  const { status, response } = decoded.payload;
  if (typeof status !== "string" || status.length === 0) {
    throw new ProtocolError("phx_reply payload must contain a status string");
  }
  if (!Object.prototype.hasOwnProperty.call(decoded.payload, "response")) {
    throw new ProtocolError("phx_reply payload must contain a response");
  }

  return { ...decoded, status, response };
}
