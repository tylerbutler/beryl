import { Presence, Socket } from "phoenix";

const clients = new Map();

function clientMap(topic) {
  let current = clients.get(topic);
  if (!current) {
    current = new Map();
    clients.set(topic, current);
  }
  return current;
}

export function scenarioId() {
  return crypto.randomUUID().replaceAll("-", "");
}

/// Sets the `reset-token` attribute on the custom element host, triggering a
/// synchronous (queueMicrotask) Lustre dispatch via attributeChangedCallback.
/// Used by the reset button click handler to avoid the rAF render delay.
export function setResetToken(event) {
  const host = event.target?.getRootNode?.()?.host;
  if (host) host.setAttribute("reset-token", scenarioId());
}

export function connect(
  role,
  serviceUrl,
  topic,
  name,
  compatibilityVersion,
  reconnectDelay,
  onOpen,
  onJoin,
  onJoinError,
  onPresenceDiff,
  onPresenceState,
  onClose,
) {
  disconnect(topic, role);
  const map = clientMap(topic);

  const clientId = crypto.randomUUID();
  let client;
  const socket = new Socket(`${serviceUrl}/socket`, {
    params: { vsn: "2.0.0" },
    reconnectAfterMs(tries) {
      const delay = reconnectDelay(tries);
      if (delay >= 0) return delay;

      queueMicrotask(() => {
        if (!client.manual && !client.exhausted) {
          client.exhausted = true;
          client.manual = true;
          socket.disconnect();
          onClose("reconnect_exhausted");
        }
      });
      return 60_000;
    },
  });
  const channel = socket.channel(topic, {
    client_id: clientId,
    compatibility_version: compatibilityVersion,
    name,
    color: role === "primary" ? "emerald" : "magenta",
  });
  client = { socket, channel, manual: false, exhausted: false, offlineFired: false };
  const presence = new Presence(channel);
  const active = () => !client.manual && clients.get(topic)?.get(role) === client;
  presence.onSync(() => {
    if (active()) onPresenceState(JSON.stringify(presence.state));
  });

  socket.onOpen(() => {
    if (!active()) return;
    client.offlineFired = false;
    onOpen();
  });
  socket.onClose(() => {
    if (!client.manual && !client.offlineFired) {
      onClose(navigator.onLine ? "socket_closed" : "offline");
    }
  });
  socket.onError(() => {
    if (!client.manual && !client.offlineFired) {
      onClose(navigator.onLine ? "socket_error" : "offline");
    }
  });

  const handleOffline = () => {
    if (!client.manual && !client.offlineFired) {
      client.offlineFired = true;
      onClose("offline");
      // Force the underlying WebSocket closed so Phoenix schedules a reconnect.
      // Playwright's setOffline blocks packets but doesn't terminate TCP, so
      // Phoenix would otherwise sit connected indefinitely.
      client.socket.conn?.close();
    }
  };
  const handleOnline = () => {
    client.offlineFired = false;
  };
  window.addEventListener("offline", handleOffline);
  window.addEventListener("online", handleOnline);
  client.cleanup = () => {
    window.removeEventListener("offline", handleOffline);
    window.removeEventListener("online", handleOnline);
  };

  channel.on("presence_diff", (payload) => {
    if (active()) onPresenceDiff(JSON.stringify(payload));
  });
  channel.onClose(() => {
    if (!client.manual && !client.offlineFired) onClose("session_expired");
  });

  map.set(role, client);
  socket.connect();
  channel
    .join()
    .receive("ok", (payload) => {
      if (!active()) return;
      onJoin(JSON.stringify(payload));
      // A round trip after the reply orders this snapshot behind router indexing.
      channel.push("sync_presence", {});
    })
    .receive("error", (payload) => {
      if (active()) onJoinError(JSON.stringify(payload));
    })
    .receive("timeout", () => {
      if (active()) onJoinError("join_timeout");
    });
}

export function disconnect(topic, role) {
  const map = clients.get(topic);
  const client = map?.get(role);
  if (!client) return;
  client.manual = true;
  client.cleanup?.();
  client.channel.leave();
  client.socket.disconnect();
  map.delete(role);
  if (map.size === 0) clients.delete(topic);
}

export function disconnectAll(topic) {
  const map = clients.get(topic);
  if (!map) return;
  for (const role of [...map.keys()]) disconnect(topic, role);
  clients.delete(topic);
}
