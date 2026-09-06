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
  const client = { socket, channel, closed: false };

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
  channel.on("todo_added", onAdded);
  channel.on("todo_updated", onUpdated);
  channel.on("todo_deleted", onDeleted);

  socket.connect();
  channel
    .join()
    .receive("ok", onJoined)
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
  client.socket.disconnect();
};

export const reconnect = (client) => {
  client.closed = false;
  client.socket.disconnect(() => client.socket.connect());
};
