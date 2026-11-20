import assert from "node:assert/strict";
import test from "node:test";
import { Socket } from "phoenix";
import { connect, close } from "../src/todo_channel_ffi.mjs";

test("offline snapshot retries do not retain pushes and resume on rejoin", (context) => {
  let connected = true;
  let snapshots = 0;
  context.mock.timers.enable({ apis: ["setTimeout"] });
  context.mock.method(Socket.prototype, "connect", () => {});
  context.mock.method(Socket.prototype, "push", () => {});
  context.mock.method(Socket.prototype, "isConnected", () => connected);
  const client = connect(
    () => {},
    () => { snapshots += 1; },
    () => {},
    () => {},
    () => {},
    () => {},
  );
  const push = context.mock.method(client.channel, "push");
  client.channel.joinPush.trigger("ok", {});
  assert.equal(push.mock.calls.length, 1);

  connected = false;
  push.mock.calls[0].result.trigger("timeout", {});
  for (let cycle = 0; cycle < 10; cycle += 1) {
    context.mock.timers.tick(10_000);
  }
  assert.equal(client.channel.pushBuffer.length, 0);
  assert.equal(push.mock.calls.length, 1);

  connected = true;
  client.channel.rejoin();
  client.channel.joinPush.trigger("ok", {});
  assert.equal(push.mock.calls.length, 2);
  push.mock.calls[1].result.trigger("ok", { todos: [] });
  assert.equal(snapshots, 1);
  close(client);
  context.mock.timers.tick(10_000);
  assert.equal(push.mock.calls.length, 2);
});
