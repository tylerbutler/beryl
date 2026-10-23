import { Socket } from "phoenix";

const push = (client, event, payload, onOk, onError) => {
  client.channel
    .push(event, payload)
    .receive("ok", onOk)
    .receive("error", onError)
    .receive("timeout", () =>
      onError({
        code: "timeout",
        message: "The Todo server did not acknowledge the request.",
      }),
    );
};

export const connect = (
  onConnecting,
  onJoined,
  onDisconnected,
  onAdded,
  onUpdated,
  onDeleted,
) => {
  const socket = new Socket("/socket");
  const channel = socket.channel("todos", {});
  const client = {
    socket, channel, closed: false, syncing: false,
    syncAgain: false, retryTimer: null, retryDelay: 250,
  };
  // Subscribe first, then read again: a mutation can race the join snapshot.
  const synchronize = () => {
    if (client.closed) return;
    if (!channel.canPush()) return;
    if (client.syncing) {
      client.syncAgain = true;
      return;
    }
    clearTimeout(client.retryTimer);
    client.syncing = true;
    client.syncAgain = false;
    const retry = (error) => {
      client.syncing = false;
      if (client.closed) return;
      onDisconnected(error);
      client.retryTimer = setTimeout(synchronize, client.retryDelay);
      client.retryDelay = Math.min(5000, client.retryDelay * 2);
    };
    channel.push("sync", {}, 5000)
      .receive("ok", (snapshot) => {
        client.syncing = false;
        if (client.closed) return;
        client.retryDelay = 250;
        onJoined(snapshot);
        if (client.syncAgain) synchronize();
      })
      .receive("error", retry)
      .receive("timeout", () => retry({
        message: "The Todo snapshot request timed out.",
      }));
  };

  socket.onOpen(() => {
    if (!client.closed) onConnecting();
  });
  socket.onClose(() => {
    if (!client.closed) {
      onDisconnected({ message: "Connection lost. Reconnecting…" });
    }
  });
  socket.onError(() => {
    if (!client.closed) {
      onDisconnected({ message: "Connection error. Reconnecting…" });
    }
  });
  channel.onError(() => {
    if (!client.closed) {
      onDisconnected({ message: "Channel error. Rejoining…" });
    }
  });
  channel.on("todo_added", synchronize);
  channel.on("todo_updated", synchronize);
  channel.on("todo_deleted", synchronize);

  socket.connect();
  channel
    .join()
    .receive("ok", () => synchronize())
    .receive("error", (error) =>
      onDisconnected({
        message:
          error?.message ?? "The Todo channel rejected the join. Retrying…",
      }),
    )
    .receive("timeout", () =>
      onDisconnected({ message: "The Todo channel join timed out. Retrying…" }),
    );

  return client;
};

export const addTodo = (client, text, onOk, onError) =>
  push(client, "add_todo", { text }, onOk, onError);

export const toggleTodo = (client, id, onOk, onError) =>
  push(client, "toggle_todo", { id }, onOk, onError);

export const deleteTodo = (client, id, onOk, onError) =>
  push(client, "delete_todo", { id }, onOk, onError);

export const close = (client) => {
  client.closed = true;
  clearTimeout(client.retryTimer);
  client.socket.disconnect();
};

export const reconnect = (client) => {
  client.closed = false;
  client.socket.disconnect(() => client.socket.connect());
};
