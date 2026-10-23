import assert from "node:assert/strict";
import test from "node:test";
import {
  channel,
  newSocket,
  onMessage,
  onPageHide,
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

test("unsubscribe removes the page cleanup callback", () => {
  const target = new EventTarget();
  const addEventListener = globalThis.addEventListener;
  const removeEventListener = globalThis.removeEventListener;
  globalThis.addEventListener = target.addEventListener.bind(target);
  globalThis.removeEventListener = target.removeEventListener.bind(target);

  try {
    let calls = 0;
    const subscription = onPageHide(() => {
      calls += 1;
    });

    target.dispatchEvent(new Event("pagehide"));
    unsubscribe(subscription);
    target.dispatchEvent(new Event("pagehide"));

    assert.equal(calls, 1);
  } finally {
    globalThis.addEventListener = addEventListener;
    globalThis.removeEventListener = removeEventListener;
  }
});
