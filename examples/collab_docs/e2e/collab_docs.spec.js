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

function countSyncFrames(frames) {
  return frames.filter((payload) => {
    try {
      const data = JSON.parse(payload);
      return Array.isArray(data) && data[3] === "sync_state";
    } catch {
      return false;
    }
  }).length;
}

async function openClient(browser, path) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const sentFrames = [];

  page.on("websocket", (ws) => {
    ws.on("framesent", (frame) => sentFrames.push(frame.payload));
  });

  await page.goto(path);
  await expect(page.locator("#status")).toHaveText("Connected", {
    timeout: 10_000,
  });

  return {
    context,
    page,
    syncCount: () => countSyncFrames(sentFrames),
  };
}

async function waitForSync(client, previousCount) {
  await expect
    .poll(() => client.syncCount(), { timeout: 5_000 })
    .toBeGreaterThan(previousCount);
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
        waitForSync(alice, aliceSyncs),
        waitForSync(bob, bobSyncs),
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
        waitForSync(defaultDoc, defaultSyncs),
        waitForSync(docTwo, twoSyncs),
      ]);

      await defaultDoc.page.waitForTimeout(250);
      await docTwo.page.waitForTimeout(250);

      await expect(defaultDoc.page.locator(".block textarea").last()).toHaveValue(
        defaultText,
      );
      await expect(docTwo.page.locator(".block textarea").last()).toHaveValue(
        twoText,
      );

      const defaultValues = await defaultDoc.page
        .locator(".block textarea")
        .evaluateAll((textareas) => textareas.map((textarea) => textarea.value));
      const twoValues = await docTwo.page
        .locator(".block textarea")
        .evaluateAll((textareas) => textareas.map((textarea) => textarea.value));
      expect(defaultValues).not.toContain(twoText);
      expect(twoValues).not.toContain(defaultText);
    } finally {
      await defaultDoc.context.close();
      await docTwo.context.close();
    }
  });
});
