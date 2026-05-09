// @ts-check
import { test, expect } from "@playwright/test";

function uniqueDoc(testInfo, suffix = "doc") {
  return `${testInfo.workerIndex}-${Date.now()}-${Math.random()
    .toString(16)
    .slice(2)}-${suffix}`;
}

function docPath(doc) {
  return `/?doc=${encodeURIComponent(doc)}`;
}

function parseFrame(payload) {
  try {
    return JSON.parse(payload);
  } catch {
    return undefined;
  }
}

const PHOENIX_FRAME = {
  joinRef: 0,
  ref: 1,
  topic: 2,
  event: 3,
  payload: 4,
  length: 5,
};

function parsePhoenixFrame(payload) {
  const data = parseFrame(payload);
  if (!Array.isArray(data) || data.length !== PHOENIX_FRAME.length) {
    return undefined;
  }

  const joinRef = data[PHOENIX_FRAME.joinRef];
  const ref = data[PHOENIX_FRAME.ref];
  const topic = data[PHOENIX_FRAME.topic];
  const event = data[PHOENIX_FRAME.event];
  const framePayload = data[PHOENIX_FRAME.payload];
  if (typeof topic !== "string" || typeof event !== "string") {
    return undefined;
  }

  return { joinRef, ref, topic, event, payload: framePayload, raw: data };
}

function syncStatePayloads(frames) {
  return frames
    .map(parsePhoenixFrame)
    .filter((frame) => frame?.event === "sync_state")
    .map((frame) => frame.payload?.state)
    .filter((state) => typeof state === "string" && state.length > 0);
}

function countSyncFrames(frames) {
  return syncStatePayloads(frames).length;
}

function joinReplyState(replyFrame) {
  return replyFrame?.payload?.response?.state ?? replyFrame?.payload?.state;
}

async function expectNoTextareaValue(page, unexpectedValue, duration = 1_000) {
  let stableSince = Date.now();

  await expect
    .poll(
      async () => {
        const matchingValues = await page
          .locator(".block textarea")
          .evaluateAll(
            (textareas, value) =>
              textareas.filter((textarea) => textarea.value === value).length,
            unexpectedValue,
          );

        if (matchingValues > 0) {
          stableSince = Date.now();
        }

        return Date.now() - stableSince;
      },
      { timeout: duration + 1_000, intervals: [50, 50, 100] },
    )
    .toBeGreaterThanOrEqual(duration);
}

async function openClient(browser, path) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const sentFrames = [];
  const joinReplies = [];

  page.on("websocket", (ws) => {
    ws.on("framesent", (frame) => sentFrames.push(frame.payload));
    ws.on("framereceived", (frame) => {
      const phoenixFrame = parsePhoenixFrame(frame.payload);
      if (phoenixFrame?.event === "phx_reply") {
        joinReplies.push(phoenixFrame);
      }
    });
  });

  await page.goto(path);
  await expect(page.locator("#status")).toHaveText("Connected", {
    timeout: 10_000,
  });
  await expect
    .poll(() => joinReplies.length, { timeout: 5_000 })
    .toBeGreaterThan(0);

  return {
    context,
    page,
    joinReply: joinReplies[0],
    syncCount: () => countSyncFrames(sentFrames),
    syncStates: () => syncStatePayloads(sentFrames),
  };
}

async function waitForSync(client, previousCount, expectedContent) {
  await expect
    .poll(
      () =>
        client
          .syncStates()
          .slice(previousCount)
          .some((state) =>
            expectedContent === undefined
              ? state.length > 0
              : state.includes(expectedContent),
          ),
      { timeout: 5_000 },
    )
    .toBe(true);
}

async function addBlock(client, selector) {
  const previousSyncs = client.syncCount();
  await client.page.locator(selector).click();
  await waitForSync(client, previousSyncs);
}

test.describe("Collaborative docs demo", () => {
  test("two clients joining same document converge after independent block additions", async ({
    browser,
  }, testInfo) => {
    const doc = uniqueDoc(testInfo, "converge");
    const alice = await openClient(browser, docPath(doc));
    const bob = await openClient(browser, docPath(doc));

    try {
      await Promise.all([
        addBlock(alice, "#add-todo"),
        addBlock(bob, "#add-note"),
      ]);

      await expect(alice.page.locator(".block")).toHaveCount(2, {
        timeout: 10_000,
      });
      await expect(bob.page.locator(".block")).toHaveCount(2, {
        timeout: 10_000,
      });
      await expect(
        alice.page.locator(".block-type", { hasText: "Todo" }),
      ).toBeVisible();
      await expect(
        alice.page.locator(".block-type", { hasText: "Note" }),
      ).toBeVisible();
      await expect(
        bob.page.locator(".block-type", { hasText: "Todo" }),
      ).toBeVisible();
      await expect(
        bob.page.locator(".block-type", { hasText: "Note" }),
      ).toBeVisible();
    } finally {
      await alice.context.close();
      await bob.context.close();
    }
  });

  test("late joiner receives cached state from join reply", async ({
    browser,
  }, testInfo) => {
    const doc = uniqueDoc(testInfo, "late");
    const author = await openClient(browser, docPath(doc));

    try {
      await addBlock(author, "#add-note");
      await expect(author.page.locator(".block")).toHaveCount(1);

      const lateJoiner = await openClient(browser, docPath(doc));
      try {
        const cachedState = joinReplyState(lateJoiner.joinReply);
        expect(cachedState).toEqual(expect.any(String));
        expect(cachedState).not.toHaveLength(0);

        await expect(lateJoiner.page.locator(".block")).toHaveCount(1, {
          timeout: 10_000,
        });
        await expect(lateJoiner.page.locator(".block-type")).toHaveText("Note");
      } finally {
        await lateJoiner.context.close();
      }
    } finally {
      await author.context.close();
    }
  });

  test("same-block concurrent edits render conflict card with multiple versions", async ({
    browser,
  }, testInfo) => {
    const doc = uniqueDoc(testInfo, "conflict");
    const alice = await openClient(browser, docPath(doc));
    const bob = await openClient(browser, docPath(doc));

    try {
      await addBlock(alice, "#add-note");
      await expect(bob.page.locator(".block")).toHaveCount(1, {
        timeout: 10_000,
      });

      const aliceSyncs = alice.syncCount();
      const bobSyncs = bob.syncCount();
      await Promise.all([
        alice.page.locator(".block textarea").fill("Alice version"),
        bob.page.locator(".block textarea").fill("Bob version"),
      ]);
      await Promise.all([
        waitForSync(alice, aliceSyncs, "Alice version"),
        waitForSync(bob, bobSyncs, "Bob version"),
      ]);

      const conflict = alice.page.locator(".conflict");
      await expect(conflict).toBeVisible({ timeout: 10_000 });
      await expect(conflict.locator(".conflict-option")).toHaveCount(2);
      await expect(conflict).toContainText("Alice version");
      await expect(conflict).toContainText("Bob version");
      await expect(bob.page.locator(".conflict")).toBeVisible({
        timeout: 10_000,
      });
    } finally {
      await alice.context.close();
      await bob.context.close();
    }
  });

  test("document topics are isolated between default and selected docs", async ({
    browser,
  }, testInfo) => {
    const defaultText = `default-only-${uniqueDoc(testInfo, "text")}`;
    const twoText = `two-only-${uniqueDoc(testInfo, "text")}`;
    const defaultDoc = await openClient(browser, "/");
    const docTwo = await openClient(browser, "/?doc=two");

    try {
      await addBlock(defaultDoc, "#add-note");
      await addBlock(docTwo, "#add-todo");

      const defaultSyncs = defaultDoc.syncCount();
      const twoSyncs = docTwo.syncCount();
      await defaultDoc.page.locator(".block textarea").last().fill(defaultText);
      await docTwo.page.locator(".block textarea").last().fill(twoText);
      await Promise.all([
        waitForSync(defaultDoc, defaultSyncs, defaultText),
        waitForSync(docTwo, twoSyncs, twoText),
      ]);

      await expect(defaultDoc.page.locator(".block textarea").last()).toHaveValue(
        defaultText,
      );
      await expect(docTwo.page.locator(".block textarea").last()).toHaveValue(
        twoText,
      );

      await Promise.all([
        expectNoTextareaValue(defaultDoc.page, twoText),
        expectNoTextareaValue(docTwo.page, defaultText),
      ]);
    } finally {
      await defaultDoc.context.close();
      await docTwo.context.close();
    }
  });
});
