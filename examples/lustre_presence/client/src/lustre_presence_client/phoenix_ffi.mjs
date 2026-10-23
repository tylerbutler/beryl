import { Socket } from "phoenix";

export function newSocket(url) {
  return new Socket(url);
}

export function connect(socket) {
  socket.connect();
}

export function disconnect(socket) {
  socket.disconnect();
}

export function onOpen(socket, callback) {
  const ref = socket.onOpen(callback);
  return () => socket.off([ref]);
}

export function onClose(socket, callback) {
  const ref = socket.onClose(callback);
  return () => socket.off([ref]);
}

export function onError(socket, callback) {
  const ref = socket.onError(callback);
  return () => socket.off([ref]);
}

export function channel(socket, topic, params) {
  return socket.channel(topic, params);
}

export function join(channel) {
  return channel.join();
}

export function leave(channel) {
  return channel.leave();
}

export function onMessage(channel, event, callback) {
  const ref = channel.on(event, callback);
  return () => channel.off(event, ref);
}

export function onChannelClose(channel, callback) {
  const event = "phx_close";
  const ref = channel.on(event, callback);
  return () => channel.off(event, ref);
}

export function onChannelError(channel, callback) {
  const ref = channel.onError(callback);
  return () => channel.off("phx_error", ref);
}

export function push(channel, event, payload) {
  return channel.push(event, payload);
}

export function receiveOk(push, callback) {
  push.receive("ok", callback);
}

export function receiveError(push, callback) {
  push.receive("error", callback);
}

export function receiveTimeout(push, callback) {
  push.receive("timeout", callback);
}

export function unsubscribe(subscription) {
  subscription();
}

export function onPageHide(callback) {
  globalThis.addEventListener("pagehide", callback, { once: true });
  return () => globalThis.removeEventListener("pagehide", callback);
}
