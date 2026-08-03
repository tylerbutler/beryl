import { WebSocket } from "k6/websockets";

import { buildWebSocketUrl } from "./config.js";
import {
  ProtocolError,
  RefGenerator,
  decodeFrame,
  decodeReply,
  encodeFrame,
} from "./protocol.js";
import { clientMetrics } from "./metrics.js";

const OPEN = 1;
const NORMAL_CLOSE = 1000;

export class PhoenixReplyError extends Error {
  constructor(topic, event, status, response) {
    super(`Phoenix ${event} on ${topic} returned status ${status}`);
    this.name = "PhoenixReplyError";
    this.topic = topic;
    this.event = event;
    this.status = status;
    this.response = response;
  }
}

export class PhoenixTimeoutError extends Error {
  constructor(topic, event, timeoutMs) {
    super(`Phoenix ${event} on ${topic} timed out after ${timeoutMs}ms`);
    this.name = "PhoenixTimeoutError";
    this.topic = topic;
    this.event = event;
    this.timeoutMs = timeoutMs;
  }
}

function sameRef(left, right) {
  if (left === null || right === null) {
    return left === right;
  }
  return String(left) === String(right);
}

export class PhoenixClient {
  constructor(config, options = {}) {
    this.config = config;
    this.url = buildWebSocketUrl(config);
    this.tags = Object.freeze({
      transport: config.transport,
      ...(options.tags ?? {}),
    });
    this.protocols = options.protocols ?? [];
    this.metricSink = options.metrics ?? clientMetrics;
    this.refs = new RefGenerator();
    this.socket = null;
    this.state = "idle";
    this.channels = new Map();
    this.pending = new Map();
    this.messageHandlers = new Set();
    this.errorHandlers = new Set();
    this.connectTimer = null;
    this.heartbeatTimer = null;
    this.heartbeatPending = false;
    this.closeWaiters = [];
    this.wasOpened = false;
  }

  onMessage(handler) {
    this.messageHandlers.add(handler);
    return () => this.messageHandlers.delete(handler);
  }

  onError(handler) {
    this.errorHandlers.add(handler);
    return () => this.errorHandlers.delete(handler);
  }

  connect() {
    if (this.state !== "idle" && this.state !== "closed") {
      return Promise.reject(new Error(`cannot connect while client is ${this.state}`));
    }

    this.state = "connecting";
    this.wasOpened = false;
    const startedAt = Date.now();

    return new Promise((resolve, reject) => {
      let settled = false;
      const fail = (error, type) => {
        if (settled) return;
        settled = true;
        this._clearConnectTimer();
        this.state = "closed";
        this.metricSink.connectFailed(Date.now() - startedAt, this.tags);
        this._observeError(error, type);
        reject(error);
      };

      this.connectTimer = setTimeout(() => {
        const error = new PhoenixTimeoutError(
          "websocket",
          "connect",
          this.config.connectTimeoutMs,
        );
        fail(error, "connect_timeout");
        this._closeSocket(NORMAL_CLOSE, "connect timeout");
      }, this.config.connectTimeoutMs);

      try {
        this.socket = new WebSocket(this.url, this.protocols, { tags: this.tags });
      } catch (error) {
        fail(error, "connect");
        return;
      }

      this.socket.addEventListener("open", () => {
        if (settled) {
          this._closeSocket(NORMAL_CLOSE, "late open");
          return;
        }
        settled = true;
        this._clearConnectTimer();
        this.state = "open";
        this.wasOpened = true;
        this.metricSink.connected(Date.now() - startedAt, this.tags);
        this._startHeartbeat();
        resolve(this);
      });

      this.socket.addEventListener("message", (event) => {
        this._handleMessage(event.data);
      });

      this.socket.addEventListener("error", (event) => {
        const error =
          event?.error instanceof Error
            ? event.error
            : new Error(event?.message || "WebSocket error");
        if (!settled) {
          fail(error, "connect");
        } else {
          this._observeError(error, "websocket");
        }
      });

      this.socket.addEventListener("close", (event) => {
        const opened = this.wasOpened;
        if (!settled) {
          fail(
            new Error(`WebSocket closed during connect (code ${event.code})`),
            "connect_close",
          );
        }
        if (opened) {
          this._handleClose(event);
        } else {
          this._cleanup(new Error("WebSocket closed during connect"));
        }
      });
    });
  }

  async join(topic, payload = {}, timeoutMs = this.config.replyTimeoutMs) {
    if (this.channels.has(topic)) {
      throw new Error(`already joined or joining ${topic}`);
    }
    this._requireOpen();

    const joinRef = this.refs.next();
    this.channels.set(topic, { joinRef, state: "joining" });
    try {
      const response = await this._request(
        joinRef,
        joinRef,
        topic,
        "phx_join",
        payload,
        timeoutMs,
        "join",
      );
      this.channels.set(topic, { joinRef, state: "joined" });
      return response;
    } catch (error) {
      this.channels.delete(topic);
      throw error;
    }
  }

  push(topic, event, payload = {}, timeoutMs = this.config.replyTimeoutMs) {
    if (event === "phx_join" || event === "phx_leave") {
      return Promise.reject(new Error(`${event} must use the lifecycle API`));
    }
    const channel = this.channels.get(topic);
    if (channel?.state !== "joined") {
      return Promise.reject(new Error(`cannot push before joining ${topic}`));
    }
    return this._request(
      channel.joinRef,
      this.refs.next(),
      topic,
      event,
      payload,
      timeoutMs,
      "push",
    );
  }

  async leave(topic, timeoutMs = this.config.leaveTimeoutMs) {
    const channel = this.channels.get(topic);
    if (channel?.state !== "joined") {
      throw new Error(`cannot leave unjoined topic ${topic}`);
    }
    channel.state = "leaving";
    try {
      const response = await this._request(
        channel.joinRef,
        this.refs.next(),
        topic,
        "phx_leave",
        {},
        timeoutMs,
        "leave",
      );
      this.channels.delete(topic);
      return response;
    } catch (error) {
      channel.state = "joined";
      throw error;
    }
  }

  async leaveAll(timeoutMs = this.config.leaveTimeoutMs) {
    const topics = [...this.channels.entries()]
      .filter(([, channel]) => channel.state === "joined")
      .map(([topic]) => topic);
    const errors = [];
    for (const topic of topics) {
      try {
        await this.leave(topic, timeoutMs);
      } catch (error) {
        errors.push(error);
      }
    }
    if (errors.length > 0) {
      const error = new Error("one or more Phoenix leaves failed");
      error.errors = errors;
      throw error;
    }
  }

  close(code = NORMAL_CLOSE, reason = "normal", timeoutMs = this.config.leaveTimeoutMs) {
    if (this.state === "idle" || this.state === "closed") {
      this._cleanup(new Error("client closed"));
      return Promise.resolve();
    }
    if (this.state === "closing") {
      return new Promise((resolve, reject) => {
        this._addCloseWaiter(resolve, reject, timeoutMs);
      });
    }

    this.state = "closing";
    this._stopHeartbeat();
    return new Promise((resolve, reject) => {
      this._addCloseWaiter(resolve, reject, timeoutMs);
      this._closeSocket(code, reason);
    });
  }

  async shutdown() {
    let leaveError = null;
    try {
      await this.leaveAll();
    } catch (error) {
      leaveError = error;
      this._observeError(error, "leave");
    }
    await this.close();
    if (leaveError) {
      throw leaveError;
    }
  }

  _request(joinRef, ref, topic, event, payload, timeoutMs, kind) {
    try {
      this._requireOpen();
    } catch (error) {
      return Promise.reject(error);
    }

    return new Promise((resolve, reject) => {
      const startedAt = Date.now();
      const key = String(ref);
      const timer = setTimeout(() => {
        this.pending.delete(key);
        const error = new PhoenixTimeoutError(topic, event, timeoutMs);
        this.metricSink.timeout(kind, this.tags);
        this._observeError(error, `${kind}_timeout`);
        reject(error);
      }, timeoutMs);

      this.pending.set(key, {
        joinRef,
        topic,
        event,
        kind,
        startedAt,
        timer,
        resolve,
        reject,
      });

      try {
        this.socket.send(encodeFrame(joinRef, ref, topic, event, payload));
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(key);
        this._observeError(error, "send");
        reject(error);
      }
    });
  }

  _handleMessage(data) {
    let frame;
    try {
      frame = decodeFrame(data);
    } catch (error) {
      this.metricSink.decodeError(this.tags);
      this._observeError(error, "decode");
      return;
    }

    if (frame.event !== "phx_reply") {
      const channel = this.channels.get(frame.topic);
      if (channel && sameRef(channel.joinRef, frame.joinRef)) {
        if (frame.event === "phx_close") {
          this.channels.delete(frame.topic);
        } else if (frame.event === "phx_error") {
          this.channels.delete(frame.topic);
          this._observeError(
            new Error(`Phoenix channel errored on ${frame.topic}`),
            "channel_error",
          );
        }
      }
      this._dispatchMessage(frame);
      return;
    }

    const key = frame.ref === null ? "" : String(frame.ref);
    const pending = this.pending.get(key);
    if (!pending) {
      this.metricSink.unmatchedReply(this.tags);
      this.metricSink.protocolError("unmatched_ref", this.tags);
      this._observeError(
        new ProtocolError(`received phx_reply with unmatched ref ${key || "null"}`),
        "unmatched_ref",
      );
      return;
    }

    clearTimeout(pending.timer);
    this.pending.delete(key);
    const durationMs = Date.now() - pending.startedAt;

    let reply;
    try {
      reply = decodeReply(frame);
      if (reply.topic !== pending.topic || !sameRef(reply.joinRef, pending.joinRef)) {
        throw new ProtocolError("phx_reply topic or join_ref did not match its push");
      }
    } catch (error) {
      this.metricSink.protocolError("invalid_reply", this.tags);
      this._observeError(error, "invalid_reply");
      pending.reject(error);
      return;
    }

    if (reply.status !== "ok") {
      const error = new PhoenixReplyError(
        pending.topic,
        pending.event,
        reply.status,
        reply.response,
      );
      this.metricSink.rejected(pending.kind, durationMs, this.tags);
      this._observeError(error, `${pending.kind}_rejected`);
      pending.reject(error);
      return;
    }

    this.metricSink.reply(pending.kind, durationMs, this.tags);
    pending.resolve(reply.response);
  }

  _dispatchMessage(frame) {
    for (const handler of this.messageHandlers) {
      try {
        handler(frame);
      } catch (error) {
        this._observeError(error, "message_handler");
      }
    }
  }

  _startHeartbeat() {
    if (this.config.heartbeatIntervalMs === 0) return;
    this.heartbeatTimer = setInterval(() => {
      if (this.state !== "open" || this.heartbeatPending) return;
      this.heartbeatPending = true;
      this._request(
        null,
        this.refs.next(),
        "phoenix",
        "heartbeat",
        {},
        this.config.heartbeatTimeoutMs,
        "heartbeat",
      ).then(
        () => {
          this.heartbeatPending = false;
        },
        () => {
          this.heartbeatPending = false;
        },
      );
    }, this.config.heartbeatIntervalMs);
  }

  _stopHeartbeat() {
    if (this.heartbeatTimer !== null) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
    this.heartbeatPending = false;
  }

  _handleClose(event) {
    const error =
      this.state === "closing"
        ? new Error("client closed")
        : new Error(`WebSocket closed unexpectedly (code ${event.code})`);
    const unexpected = this.state !== "closing";
    this._cleanup(error);
    if (unexpected) {
      this._observeError(error, "unexpected_close");
    }
    for (const waiter of this.closeWaiters.splice(0)) {
      if (waiter.timer !== null) clearTimeout(waiter.timer);
      waiter.resolve();
    }
  }

  _addCloseWaiter(resolve, reject, timeoutMs) {
    const waiter = { resolve, reject, timer: null };
    waiter.timer = setTimeout(() => {
      const error = new PhoenixTimeoutError("websocket", "close", timeoutMs);
      this._observeError(error, "close_timeout");
      this._cleanup(error);
      for (const closeWaiter of this.closeWaiters.splice(0)) {
        if (closeWaiter.timer !== null) clearTimeout(closeWaiter.timer);
        closeWaiter.reject(error);
      }
    }, timeoutMs);
    this.closeWaiters.push(waiter);
  }

  _cleanup(error) {
    this._clearConnectTimer();
    this._stopHeartbeat();
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    this.channels.clear();
    this.state = "closed";
    this.socket = null;
    if (this.wasOpened) {
      this.metricSink.closed(this.tags);
      this.wasOpened = false;
    }
  }

  _clearConnectTimer() {
    if (this.connectTimer !== null) {
      clearTimeout(this.connectTimer);
      this.connectTimer = null;
    }
  }

  _closeSocket(code, reason) {
    if (this.socket && this.socket.readyState <= OPEN) {
      try {
        this.socket.close(code, reason);
      } catch (error) {
        this._observeError(error, "close");
      }
    }
  }

  _requireOpen() {
    if (this.state !== "open" || !this.socket || this.socket.readyState !== OPEN) {
      throw new Error(`Phoenix client is not open (state: ${this.state})`);
    }
  }

  _observeError(error, type) {
    this.metricSink.error(type, this.tags);
    if (this.errorHandlers.size === 0) {
      console.error(`[phoenix:${type}] ${error.message || String(error)}`);
      return;
    }
    for (const handler of this.errorHandlers) {
      try {
        handler(error, type);
      } catch (handlerError) {
        console.error(
          `[phoenix:error_handler] ${handlerError.message || String(handlerError)}`,
        );
      }
    }
  }
}
