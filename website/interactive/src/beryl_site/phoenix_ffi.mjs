import { Socket } from "phoenix";

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
  client = { socket, channel, manual: false, exhausted: false };

  socket.onOpen(onOpen);
  socket.onClose(() => {
    if (!client.manual) {
      onClose(navigator.onLine ? "socket_closed" : "offline");
    }
  });
  socket.onError(() => {
    if (!client.manual) {
      onClose(navigator.onLine ? "socket_error" : "offline");
    }
  });
  channel.on("presence_diff", (payload) => {
    onPresenceDiff(JSON.stringify(payload));
  });
  channel.onClose(() => {
    if (!client.manual) onClose("session_expired");
  });

  map.set(role, client);
  socket.connect();
  channel
    .join()
    .receive("ok", (payload) => onJoin(JSON.stringify(payload)))
    .receive("error", (payload) => onJoinError(JSON.stringify(payload)))
    .receive("timeout", () => onJoinError("join_timeout"));
}

export function disconnect(topic, role) {
  const map = clients.get(topic);
  const client = map?.get(role);
  if (!client) return;
  client.manual = true;
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
