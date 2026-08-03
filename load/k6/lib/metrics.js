import { Counter, Gauge, Rate, Trend } from "k6/metrics";

export const websocketEstablishDuration = new Trend(
  "phoenix_ws_establish_duration",
  true,
);
export const joinDuration = new Trend("phoenix_join_duration", true);
export const pushReplyDuration = new Trend("phoenix_push_reply_duration", true);
export const heartbeatReplyDuration = new Trend(
  "phoenix_heartbeat_reply_duration",
  true,
);

export const sessionsActive = new Gauge("phoenix_sessions_active");
export const sessionsOpened = new Counter("phoenix_sessions_opened");
export const sessionsClosed = new Counter("phoenix_sessions_closed");
export const repliesReceived = new Counter("phoenix_replies_received");
export const clientErrors = new Counter("phoenix_client_errors");
export const protocolErrors = new Counter("phoenix_protocol_errors");
export const decodeErrors = new Counter("phoenix_decode_errors");
export const unmatchedReplies = new Counter("phoenix_unmatched_replies");
export const pushTimeouts = new Counter("phoenix_push_timeouts");
export const heartbeatTimeouts = new Counter("phoenix_heartbeat_timeouts");

export const websocketFailureRate = new Rate("phoenix_ws_failure_rate");
export const joinRejectionRate = new Rate("phoenix_join_rejection_rate");
export const pushTimeoutRate = new Rate("phoenix_push_timeout_rate");
export const heartbeatTimeoutRate = new Rate("phoenix_heartbeat_timeout_rate");

function add(metric, value, tags) {
  metric.add(value, tags);
}

export const clientMetrics = Object.freeze({
  connected(durationMs, tags) {
    add(websocketEstablishDuration, durationMs, tags);
    add(websocketFailureRate, false, tags);
    add(sessionsOpened, 1, tags);
    add(sessionsActive, 1, tags);
  },

  connectFailed(durationMs, tags) {
    add(websocketEstablishDuration, durationMs, tags);
    add(websocketFailureRate, true, tags);
  },

  closed(tags) {
    add(sessionsClosed, 1, tags);
    add(sessionsActive, 0, tags);
  },

  reply(kind, durationMs, tags) {
    add(repliesReceived, 1, tags);
    if (kind === "join") {
      add(joinDuration, durationMs, tags);
      add(joinRejectionRate, false, tags);
    } else if (kind === "heartbeat") {
      add(heartbeatReplyDuration, durationMs, tags);
      add(heartbeatTimeoutRate, false, tags);
    } else {
      add(pushReplyDuration, durationMs, tags);
      add(pushTimeoutRate, false, tags);
    }
  },

  rejected(kind, durationMs, tags) {
    if (kind === "join") {
      add(joinDuration, durationMs, tags);
      add(joinRejectionRate, true, tags);
    } else {
      add(pushReplyDuration, durationMs, tags);
    }
  },

  timeout(kind, tags) {
    if (kind === "heartbeat") {
      add(heartbeatTimeouts, 1, tags);
      add(heartbeatTimeoutRate, true, tags);
    } else {
      add(pushTimeouts, 1, tags);
      add(pushTimeoutRate, true, tags);
    }
  },

  decodeError(tags) {
    add(decodeErrors, 1, tags);
  },

  error(type, tags) {
    add(clientErrors, 1, { ...tags, error_type: type });
  },

  protocolError(type, tags) {
    add(protocolErrors, 1, { ...tags, error_type: type });
  },

  unmatchedReply(tags) {
    add(unmatchedReplies, 1, tags);
  },
});
