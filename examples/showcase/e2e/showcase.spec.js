// @ts-check
import { test, expect } from "@playwright/test";

// The showcase is the acceptance gate for beryl's app-side dispatch model
// (ADR 0002): three independent channel apps (cursors, chatrooms,
// collab_docs) composed onto ONE WebSocket through a single app-owned
// update function. These tests drive all three flows over a single raw
// Phoenix-framed socket and assert the ordering guarantees the design
// depends on (join ack before subsequent frames, per-channel isolation).

/**
 * Drive a raw Phoenix V2 socket from inside the page. Returns a transcript
 * of every received frame (parsed arrays) after running the given steps.
 * Each step is { send: frameArray } or { waitFor: eventName }.
 */
async function driveSocket(page, steps) {
  return page.evaluate(async (steps) => {
    const ws = new WebSocket(
      `ws://${location.host}/socket/websocket?vsn=2.0.0`
    );
    const received = [];
    const waiters = [];
    ws.onmessage = (msg) => {
      try {
        const frame = JSON.parse(msg.data);
        received.push(frame);
        for (const w of [...waiters]) {
          if (w.matches(frame)) {
            waiters.splice(waiters.indexOf(w), 1);
            w.resolve(frame);
          }
        }
      } catch {
        // ignore non-JSON frames
      }
    };
    await new Promise((resolve, reject) => {
      ws.onopen = resolve;
      ws.onerror = () => reject(new Error("websocket failed to open"));
    });

    const waitFor = (predicate) =>
      new Promise((resolve, reject) => {
        const existing = received.find(predicate);
        if (existing) return resolve(existing);
        const timer = setTimeout(
          () => reject(new Error("timed out waiting for frame")),
          10_000
        );
        waiters.push({
          matches: predicate,
          resolve: (frame) => {
            clearTimeout(timer);
            resolve(frame);
          },
        });
      });

    for (const step of steps) {
      if (step.send) {
        ws.send(JSON.stringify(step.send));
      } else if (step.waitReply) {
        // [join_ref, ref, topic, "phx_reply", ...] matching a ref
        await waitFor((f) => f[3] === "phx_reply" && f[1] === step.waitReply);
      } else if (step.waitEvent) {
        await waitFor(
          (f) => f[3] === step.waitEvent && (!step.topic || f[2] === step.topic)
        );
      }
    }
    ws.close();
    return received;
  }, steps);
}

const repliesFor = (frames, ref) =>
  frames.filter((f) => f[3] === "phx_reply" && f[1] === ref);
const replyStatus = (frame) => frame[4]?.response !== undefined
  ? frame[4].status
  : frame[4]?.status;

test.describe("Showcase (app-side dispatch)", () => {
  test("landing page and health check respond", async ({ page }) => {
    await page.goto("/");
    await expect(page).toHaveTitle(/beryl/);
    const health = await page.request.get("/healthz");
    expect(health.ok()).toBeTruthy();
  });

  test("one socket joins chat, cursors, and docs channels independently", async ({
    page,
  }) => {
    await page.goto("/");
    const frames = await driveSocket(page, [
      // Join a chat room and a cursor room on the SAME socket.
      {
        send: ["1", "1", "room:general", "phx_join", { username: "e2e-user" }],
      },
      { waitReply: "1" },
      { send: ["2", "2", "cursor:main", "phx_join", { username: "e2e-user" }] },
      { waitReply: "2" },
      // The document channel requires a tenant token: joining without one
      // must be rejected by the docs app through the same router.
      { send: ["3", "3", "document:demo:welcome", "phx_join", {}] },
      { waitReply: "3" },
      // Channel isolation: a chat message gets its ack while the cursor
      // channel stays silent, and a cursor move produces no error.
      { send: ["1", "4", "room:general", "new_msg", { text: "hello" }] },
      { waitReply: "4" },
      { send: ["2", null, "cursor:main", "cursor_move", { x: 10, y: 20 }] },
      // Leaving the chat room must not disturb the cursor channel.
      { send: ["1", "5", "room:general", "phx_leave", {}] },
      { waitEvent: "phx_close", topic: "room:general" },
    ]);

    // Both real joins accepted, on one socket.
    expect(replyStatus(repliesFor(frames, "1")[0])).toBe("ok");
    expect(replyStatus(repliesFor(frames, "2")[0])).toBe("ok");
    // Docs join rejected for the missing token — the union router reached
    // the docs app and its channel-level auth.
    const docsReply = repliesFor(frames, "3")[0];
    expect(replyStatus(docsReply)).toBe("error");
    expect(JSON.stringify(docsReply[4])).toContain("missing_token");
    // The chat message was acked.
    expect(replyStatus(repliesFor(frames, "4")[0])).toBe("ok");
    // No phx_error anywhere: nothing crashed across the three channels.
    expect(frames.filter((f) => f[3] === "phx_error")).toHaveLength(0);
    // The leave closed only the chat topic.
    const closes = frames.filter((f) => f[3] === "phx_close");
    expect(closes.map((f) => f[2])).toEqual(["room:general"]);
  });

  test("join ack arrives before the join's own follow-up broadcasts", async ({
    page,
  }) => {
    await page.goto("/");
    const frames = await driveSocket(page, [
      {
        send: ["1", "1", "room:general", "phx_join", { username: "order-user" }],
      },
      { waitReply: "1" },
      { waitEvent: "presence_list", topic: "room:general" },
    ]);

    // The chat join's effect list is [AcceptJoin, PresenceTrack,
    // Broadcast(new_msg), Broadcast(presence_list)] — the ack must hit the
    // wire before every frame those later effects produce.
    const ackIndex = frames.findIndex(
      (f) => f[3] === "phx_reply" && f[1] === "1"
    );
    const presenceIndex = frames.findIndex((f) => f[3] === "presence_list");
    const sysMsgIndex = frames.findIndex((f) => f[3] === "new_msg");
    expect(ackIndex).toBeGreaterThanOrEqual(0);
    expect(presenceIndex).toBeGreaterThan(ackIndex);
    expect(sysMsgIndex).toBeGreaterThan(ackIndex);
    // presence_diff (from PresenceTrack) also lands after the ack.
    const diffIndex = frames.findIndex((f) => f[3] === "presence_diff");
    if (diffIndex !== -1) {
      expect(diffIndex).toBeGreaterThan(ackIndex);
    }
  });

  test("chat page works end to end against the shared socket", async ({
    page,
  }) => {
    page.on("dialog", (dialog) => dialog.accept("showcase-user"));
    await page.goto("/chat");
    // The chat UI auto-joins a room over the shared endpoint; sending a
    // message must render it back through the broadcast.
    await expect(page.locator("#user-list li").first()).toContainText(
      "showcase-user",
      { timeout: 10_000 }
    );
    await page.locator("#msg-input").fill("hello from the gate");
    await page.locator("#send-btn").click();
    await expect(
      page.locator("#messages").getByText("hello from the gate").first()
    ).toBeVisible();
  });

  test("cursors page joins its channel over the shared socket", async ({
    page,
  }) => {
    page.on("dialog", (dialog) => dialog.accept("showcase-user"));
    const joinReply = new Promise((resolve, reject) => {
      const timeout = setTimeout(
        () => reject(new Error("No phx_reply received")),
        10_000
      );
      page.on("websocket", (ws) => {
        ws.on("framereceived", (frame) => {
          try {
            const data = JSON.parse(
              typeof frame.payload === "string" ? frame.payload : ""
            );
            if (Array.isArray(data) && data[3] === "phx_reply") {
              clearTimeout(timeout);
              resolve(data);
            }
          } catch {
            // ignore non-JSON frames
          }
        });
      });
    });
    await page.goto("/cursors/");
    const reply = await joinReply;
    expect(JSON.stringify(reply)).toContain('"ok"');
  });
});
