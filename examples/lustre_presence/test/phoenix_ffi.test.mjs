import assert from "node:assert/strict";
import test from "node:test";
import {
  channel,
  newSocket,
  onMessage,
  unsubscribe,
} from "../client/src/lustre_presence_client/phoenix_ffi.mjs";

test("unsubscribe removes only its channel callback", () => {
  const socket = newSocket("/socket");
  const topic = channel(socket, "page:dashboard", {});
  let firstCalls = 0;
  let secondCalls = 0;

  const first = onMessage(topic, "presence_diff", () => {
    firstCalls += 1;
  });
  onMessage(topic, "presence_diff", () => {
    secondCalls += 1;
  });

  topic.trigger("presence_diff", {});
  unsubscribe(first);
  topic.trigger("presence_diff", {});

  assert.equal(firstCalls, 1);
  assert.equal(secondCalls, 2);
});
