import { Counter, Rate, Trend } from "k6/metrics";

export const websocketEstablishDuration = new Trend(
  "phoenix_ws_establish_duration",
  true,
);
export const joinDuration = new Trend("phoenix_join_duration", true);
export const pushReplyDuration = new Trend("phoenix_push_reply_duration", true);
export const leaveReplyDuration = new Trend("phoenix_leave_reply_duration", true);
export const heartbeatReplyDuration = new Trend(
  "phoenix_heartbeat_reply_duration",
  true,
);
export const broadcastDeliveryDuration = new Trend(
  "phoenix_broadcast_delivery_duration",
  true,
);
export const presenceDeliveryDuration = new Trend(
  "phoenix_presence_delivery_duration",
  true,
);

export const sessionsOpened = new Counter("phoenix_sessions_opened");
export const sessionsClosed = new Counter("phoenix_sessions_closed");
export const joinReplies = new Counter("phoenix_join_replies");
export const pushReplies = new Counter("phoenix_push_replies");
export const leaveReplies = new Counter("phoenix_leave_replies");
export const heartbeatReplies = new Counter("phoenix_heartbeat_replies");
export const lateReplies = new Counter("phoenix_late_replies");
export const clientErrors = new Counter("phoenix_client_errors");
export const protocolErrors = new Counter("phoenix_protocol_errors");
export const decodeErrors = new Counter("phoenix_decode_errors");
export const unmatchedReplies = new Counter("phoenix_unmatched_replies");
export const joinTimeouts = new Counter("phoenix_join_timeouts");
export const pushTimeouts = new Counter("phoenix_push_timeouts");
export const leaveTimeouts = new Counter("phoenix_leave_timeouts");
export const heartbeatTimeouts = new Counter("phoenix_heartbeat_timeouts");
export const broadcastDeliveries = new Counter("phoenix_broadcast_deliveries");
export const presenceEvents = new Counter("phoenix_presence_events");
export const unexpectedClientErrors = new Counter(
  "phoenix_unexpected_client_errors",
);

export const websocketFailureRate = new Rate("phoenix_ws_failure_rate");
export const joinRejectionRate = new Rate("phoenix_join_rejection_rate");
export const joinTimeoutRate = new Rate("phoenix_join_timeout_rate");
export const pushTimeoutRate = new Rate("phoenix_push_timeout_rate");
export const leaveTimeoutRate = new Rate("phoenix_leave_timeout_rate");
export const heartbeatTimeoutRate = new Rate("phoenix_heartbeat_timeout_rate");
export const broadcastDeliveryRate = new Rate(
  "phoenix_broadcast_delivery_rate",
);
export const presenceDeliveryRate = new Rate("phoenix_presence_delivery_rate");
export const scenarioOperationRate = new Rate(
  "phoenix_scenario_operation_rate",
);

function add(metric, value, tags) {
  metric.add(value, tags);
}

export const clientMetrics = Object.freeze({
  connected(durationMs, tags) {
    add(websocketEstablishDuration, durationMs, tags);
    add(websocketFailureRate, false, tags);
    add(sessionsOpened, 1, tags);
  },

  connectFailed(durationMs, tags) {
    add(websocketEstablishDuration, durationMs, tags);
    add(websocketFailureRate, true, tags);
  },

  closed(tags) {
    add(sessionsClosed, 1, tags);
  },

  reply(kind, durationMs, tags) {
    if (kind === "join") {
      add(joinReplies, 1, tags);
      add(joinDuration, durationMs, tags);
      add(joinRejectionRate, false, tags);
      add(joinTimeoutRate, false, tags);
    } else if (kind === "heartbeat") {
      add(heartbeatReplies, 1, tags);
      add(heartbeatReplyDuration, durationMs, tags);
      add(heartbeatTimeoutRate, false, tags);
    } else if (kind === "leave") {
      add(leaveReplies, 1, tags);
      add(leaveReplyDuration, durationMs, tags);
      add(leaveTimeoutRate, false, tags);
    } else {
      add(pushReplies, 1, tags);
      add(pushReplyDuration, durationMs, tags);
      add(pushTimeoutRate, false, tags);
    }
  },

  rejected(kind, durationMs, tags) {
    if (kind === "join") {
      add(joinReplies, 1, tags);
      add(joinDuration, durationMs, tags);
      add(joinRejectionRate, true, tags);
      add(joinTimeoutRate, false, tags);
    } else if (kind === "heartbeat") {
      add(heartbeatReplies, 1, tags);
      add(heartbeatReplyDuration, durationMs, tags);
      add(heartbeatTimeoutRate, false, tags);
    } else if (kind === "leave") {
      add(leaveReplies, 1, tags);
      add(leaveReplyDuration, durationMs, tags);
      add(leaveTimeoutRate, false, tags);
    } else {
      add(pushReplies, 1, tags);
      add(pushReplyDuration, durationMs, tags);
      add(pushTimeoutRate, false, tags);
    }
  },

  timeout(kind, tags) {
    if (kind === "heartbeat") {
      add(heartbeatTimeouts, 1, tags);
      add(heartbeatTimeoutRate, true, tags);
    } else if (kind === "join") {
      add(joinTimeouts, 1, tags);
      add(joinTimeoutRate, true, tags);
    } else if (kind === "leave") {
      add(leaveTimeouts, 1, tags);
      add(leaveTimeoutRate, true, tags);
    } else {
      add(pushTimeouts, 1, tags);
      add(pushTimeoutRate, true, tags);
    }
  },

  lateReply(kind, tags) {
    add(lateReplies, 1, { ...tags, operation: kind });
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

  broadcastDelivery(durationMs, delivered, tags) {
    add(broadcastDeliveryRate, delivered, tags);
    if (delivered) {
      add(broadcastDeliveries, 1, tags);
      add(broadcastDeliveryDuration, durationMs, tags);
    }
  },

  presenceDelivery(kind, durationMs, delivered, tags) {
    add(presenceDeliveryRate, delivered, { ...tags, presence_kind: kind });
    if (delivered) {
      add(presenceEvents, 1, { ...tags, presence_kind: kind });
      add(presenceDeliveryDuration, durationMs, {
        ...tags,
        presence_kind: kind,
      });
    }
  },

  scenarioOperation(success, operation, tags) {
    add(scenarioOperationRate, success, { ...tags, operation });
  },

  unexpectedError(type, tags) {
    add(unexpectedClientErrors, 1, { ...tags, error_type: type });
  },
});
