// @ts-check
import { test, expect } from "@playwright/test";

// Helper: navigate a page with a given username (handles the prompt dialog)
async function gotoWithUsername(page, username, path = "/") {
  page.on("dialog", (dialog) => dialog.accept(username));
  await page.goto(path);
}

// Helper: wait for the Phoenix channel join reply and return the response
async function waitForJoinReply(page) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error("No phx_reply received")),
      10_000
    );
    page.on("websocket", (ws) => {
      ws.on("framereceived", (frame) => {
        try {
          const data = JSON.parse(frame.payload);
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
}

// Helper: collect all received WS frames matching a given event name
function collectFrames(page, eventName) {
  const frames = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (frame) => {
      try {
        const data = JSON.parse(frame.payload);
        if (Array.isArray(data) && data[3] === eventName) {
          frames.push(data);
        }
      } catch {
        // ignore non-JSON
      }
    });
  });
  return frames;
}

test.describe("Collaborative Cursors Demo", () => {
  test.describe("Page structure", () => {
    test("renders the page title", async ({ page }) => {
      await page.goto("/");
      await expect(page).toHaveTitle("Collaborative Cursors — beryl demo");
    });

    test("renders the welcome heading", async ({ page }) => {
      await page.goto("/");
      await expect(page.locator("#welcome h1")).toHaveText(
        "🖱️ Collaborative Cursors"
      );
    });

    test("renders the welcome description", async ({ page }) => {
      await page.goto("/");
      await expect(page.locator("#welcome p").first()).toContainText(
        "Move your mouse to share your cursor position"
      );
    });

    test("renders the beryl attribution link", async ({ page }) => {
      await page.goto("/");
      const link = page.locator("#welcome .powered-by a");
      await expect(link).toHaveText("beryl");
      await expect(link).toHaveAttribute(
        "href",
        "https://github.com/tylerbutler/beryl"
      );
    });

    test("renders the canvas area", async ({ page }) => {
      await page.goto("/");
      await expect(page.locator("#canvas")).toBeVisible();
    });

    test("renders the sidebar with Online heading", async ({ page }) => {
      await page.goto("/");
      await expect(page.locator("#sidebar h2")).toHaveText("Online");
    });

    test("renders the user list container", async ({ page }) => {
      await page.goto("/");
      await expect(page.locator("#user-list")).toBeAttached();
    });
  });

  test.describe("Reaction toolbar", () => {
    test("renders five accessible reactions with thumbs up selected", async ({
      page,
    }) => {
      await page.goto("/");

      const toolbar = page.getByRole("toolbar", { name: "Choose reaction" });
      await expect(toolbar).toBeVisible();
      await expect(toolbar.getByRole("button")).toHaveCount(5);
      await expect(
        toolbar.getByRole("button", { name: "Thumbs up" })
      ).toHaveAttribute("aria-pressed", "true");
    });

    test("switches and clears the selected reaction", async ({ page }) => {
      await page.goto("/");

      const heart = page.getByRole("button", { name: "Heart" });
      const thumbsUp = page.getByRole("button", { name: "Thumbs up" });
      await heart.click();
      await expect(heart).toHaveAttribute("aria-pressed", "true");
      await expect(thumbsUp).toHaveAttribute("aria-pressed", "false");

      await heart.click();
      await expect(heart).toHaveAttribute("aria-pressed", "false");
    });

    test("spawns and removes the selected local reaction", async ({ page }) => {
      await page.goto("/");

      await page.locator("#canvas").click({ position: { x: 120, y: 140 } });
      const reaction = page.locator("#canvas .reaction-burst");
      await expect(reaction).toHaveText("👍");
      await expect(reaction).toHaveCount(0, { timeout: 3_000 });
    });

    test("toolbar clicks do not spawn reactions", async ({ page }) => {
      await page.goto("/");

      await page.getByRole("button", { name: "Party popper" }).click();
      await expect(page.locator("#canvas .reaction-burst")).toHaveCount(0);
    });

    test("canvas clicks do nothing after clearing selection", async ({
      page,
    }) => {
      await page.goto("/");

      await page.getByRole("button", { name: "Thumbs up" }).click();
      await page.locator("#canvas").click({ position: { x: 100, y: 100 } });
      await expect(page.locator("#canvas .reaction-burst")).toHaveCount(0);
    });

    test("keeps the selection active across rapid clicks", async ({ page }) => {
      await page.goto("/");

      const canvas = page.locator("#canvas");
      await canvas.click({ position: { x: 100, y: 100 } });
      await canvas.click({ position: { x: 140, y: 140 } });
      await expect(page.locator("#canvas .reaction-burst")).toHaveCount(2);
      await expect(
        page.getByRole("button", { name: "Thumbs up" })
      ).toHaveAttribute("aria-pressed", "true");
    });

    test("keeps the toolbar inside the canvas on mobile", async ({
      browser,
    }) => {
      const context = await browser.newContext({
        viewport: { width: 375, height: 667 },
      });
      const page = await context.newPage();

      try {
        await page.goto("/");
        const canvasBox = await page.locator("#canvas").boundingBox();
        const toolbarBox = await page.locator("#reaction-toolbar").boundingBox();
        expect(toolbarBox.x).toBeGreaterThanOrEqual(canvasBox.x);
        expect(toolbarBox.x + toolbarBox.width).toBeLessThanOrEqual(
          canvasBox.x + canvasBox.width
        );
      } finally {
        await context.close();
      }
    });

    test("uses the reduced-motion fade", async ({ browser }) => {
      const context = await browser.newContext({ reducedMotion: "reduce" });
      const page = await context.newPage();

      try {
        await page.goto("/");
        await page.locator("#canvas").click({ position: { x: 100, y: 100 } });
        const animationName = await page
          .locator("#canvas .reaction-burst")
          .evaluate((el) => getComputedStyle(el).animationName);
        expect(animationName).toBe("reaction-fade");
      } finally {
        await context.close();
      }
    });
  });

  test.describe("Collaborative reactions", () => {
    test("sends the selected reaction with normalized coordinates", async ({
      page,
    }) => {
      const sentFrames = [];
      page.on("websocket", (ws) => {
        ws.on("framesent", (frame) => {
          try {
            const data = JSON.parse(frame.payload);
            if (Array.isArray(data) && data[3] === "reaction") {
              sentFrames.push(data);
            }
          } catch {
            // ignore non-JSON frames
          }
        });
      });

      await gotoWithUsername(page, "Reactor");
      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });

      const canvas = page.locator("#canvas");
      const box = await canvas.boundingBox();
      await canvas.click({
        position: { x: box.width * 0.25, y: box.height * 0.75 },
      });
      await expect.poll(() => sentFrames.length).toBeGreaterThan(0);

      const payload = sentFrames[0][4];
      expect(payload.reaction).toBe("👍");
      expect(payload.x).toBeCloseTo(0.25, 2);
      expect(payload.y).toBeCloseTo(0.75, 2);
    });

    test("broadcasts a reaction to another user at the same relative point", async ({
      browser,
    }) => {
      const context1 = await browser.newContext();
      const context2 = await browser.newContext();
      const page1 = await context1.newPage();
      const page2 = await context2.newPage();

      try {
        await gotoWithUsername(page1, "Sender");
        await expect(page1.locator("#user-list li")).toHaveCount(1, {
          timeout: 10_000,
        });
        await gotoWithUsername(page2, "Watcher");
        await expect(page1.locator("#user-list li")).toHaveCount(2, {
          timeout: 10_000,
        });

        await page1.getByRole("button", { name: "Party popper" }).click();
        const senderCanvas = page1.locator("#canvas");
        const senderBox = await senderCanvas.boundingBox();
        await senderCanvas.click({
          position: { x: senderBox.width * 0.4, y: senderBox.height * 0.6 },
        });

        const remote = page2.locator("#canvas .reaction-burst");
        await expect(remote).toHaveText("🎉", { timeout: 5_000 });

        const watcherBox = await page2.locator("#canvas").boundingBox();
        const position = await remote.evaluate((el) => ({
          left: Number.parseFloat(el.style.left),
          top: Number.parseFloat(el.style.top),
        }));
        expect(position.left).toBeCloseTo(watcherBox.width * 0.4, 0);
        expect(position.top).toBeCloseTo(watcherBox.height * 0.6, 0);
      } finally {
        await context1.close();
        await context2.close();
      }
    });
  });

  test.describe("Static assets", () => {
    test("loads the stylesheet", async ({ page }) => {
      const response = await page.goto("/static/style.css");
      expect(response?.status()).toBe(200);
      expect(response?.headers()["content-type"]).toContain("text/css");
    });

    test("loads the client JavaScript", async ({ page }) => {
      const response = await page.goto("/static/app.js");
      expect(response?.status()).toBe(200);
      expect(response?.headers()["content-type"]).toContain("javascript");
    });

    test("rejects path traversal attempts", async ({ page }) => {
      const response = await page.goto("/static/../gleam.toml");
      expect(response?.status()).toBe(404);

      const encodedResponse = await page.goto("/static/%2E%2E/gleam.toml");
      expect(encodedResponse?.status()).toBe(404);
    });
  });

  test.describe("Layout", () => {
    test("canvas fills available width", async ({ page }) => {
      await page.goto("/");
      const canvas = page.locator("#canvas");
      const sidebar = page.locator("#sidebar");
      const canvasBox = await canvas.boundingBox();
      const sidebarBox = await sidebar.boundingBox();
      expect(canvasBox).not.toBeNull();
      expect(sidebarBox).not.toBeNull();
      // Canvas should be wider than the sidebar
      expect(canvasBox.width).toBeGreaterThan(sidebarBox.width);
    });

    test("sidebar has fixed width", async ({ page }) => {
      await page.goto("/");
      const sidebar = page.locator("#sidebar");
      const box = await sidebar.boundingBox();
      expect(box).not.toBeNull();
      expect(box.width).toBe(200);
    });

    test("app fills the viewport", async ({ page }) => {
      await page.goto("/");
      const app = page.locator("#app");
      const box = await app.boundingBox();
      const viewport = page.viewportSize();
      expect(box).not.toBeNull();
      expect(box.height).toBe(viewport.height);
      expect(box.width).toBe(viewport.width);
    });
  });

  test.describe("WebSocket connection", () => {
    test("connects to the WebSocket server", async ({ page }) => {
      page.on("dialog", (dialog) => dialog.accept("TestUser"));

      const wsPromise = page.waitForEvent("websocket");
      await page.goto("/");
      const ws = await wsPromise;
      expect(ws.url()).toContain("/socket");
    });

    test("joins the cursor channel", async ({ page }) => {
      const replyPromise = waitForJoinReply(page);
      await gotoWithUsername(page, "TestUser");
      const replyFrame = await replyPromise;

      expect(replyFrame[2]).toBe("cursor:lobby");
      expect(replyFrame[4]?.status).toBe("ok");
      expect(replyFrame[4]?.response?.socket_id).toBeTruthy();
    });

    test("join reply includes username and color", async ({ page }) => {
      const replyPromise = waitForJoinReply(page);
      await gotoWithUsername(page, "ColorUser");
      const replyFrame = await replyPromise;

      const response = replyFrame[4]?.response;
      expect(response?.username).toBe("ColorUser");
      // Color should be an HSL string
      expect(response?.color).toMatch(/^hsl\(\d+, 70%, 65%\)$/);
    });

    test("shows user in sidebar after joining", async ({ page }) => {
      await gotoWithUsername(page, "TestUser");

      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });
      await expect(page.locator("#user-list li").first()).toContainText(
        "TestUser"
      );
    });

    test("shows (you) indicator for own user", async ({ page }) => {
      await gotoWithUsername(page, "SelfUser");

      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });
      await expect(page.locator("#user-list li").first()).toContainText("(you)");
    });

    test("sidebar shows colored dot for user", async ({ page }) => {
      await gotoWithUsername(page, "DotUser");

      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });
      const dot = page.locator("#user-list .user-dot").first();
      await expect(dot).toBeVisible();
      // Dot should have an inline background color
      const style = await dot.getAttribute("style");
      expect(style).toContain("background:");
    });
  });

  test.describe("Username handling", () => {
    test("uses provided username in sidebar", async ({ page }) => {
      await gotoWithUsername(page, "CustomName");

      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });
      await expect(page.locator("#user-list li").first()).toContainText(
        "CustomName"
      );
    });

    test("falls back to Anonymous for empty username", async ({ page }) => {
      // Accept with empty string → client code falls through to "Anonymous"
      await gotoWithUsername(page, "");

      const replyPromise = waitForJoinReply(page);
      // Need to reload to get the join reply since gotoWithUsername already navigated
      await page.reload();
      // Re-handle dialog on reload
      page.on("dialog", (dialog) => dialog.accept(""));

      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });
      // The client code: prompt() || "Anonymous"
      await expect(page.locator("#user-list li").first()).toContainText(
        "Anonymous"
      );
    });
  });

  test.describe("Cursor movement", () => {
    test("sends cursor_move events on mousemove", async ({ page }) => {
      const sentFrames = [];
      page.on("websocket", (ws) => {
        ws.on("framesent", (frame) => {
          try {
            const data = JSON.parse(frame.payload);
            if (Array.isArray(data) && data[3] === "cursor_move") {
              sentFrames.push(data);
            }
          } catch {
            // ignore
          }
        });
      });

      await gotoWithUsername(page, "MoveUser");
      // Wait for channel join
      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });

      // Move mouse across the canvas
      const canvas = page.locator("#canvas");
      const box = await canvas.boundingBox();
      await page.mouse.move(box.x + 100, box.y + 100);
      await page.waitForTimeout(100);
      await page.mouse.move(box.x + 200, box.y + 200);
      await page.waitForTimeout(100);

      expect(sentFrames.length).toBeGreaterThanOrEqual(1);
      // Verify frame structure: [join_ref, ref, topic, event, payload]
      const frame = sentFrames[0];
      expect(frame[2]).toBe("cursor:lobby");
      expect(frame[3]).toBe("cursor_move");
      expect(frame[4]).toHaveProperty("x");
      expect(frame[4]).toHaveProperty("y");
    });

    test("cursor coordinates are relative to canvas", async ({ page }) => {
      const sentFrames = [];
      page.on("websocket", (ws) => {
        ws.on("framesent", (frame) => {
          try {
            const data = JSON.parse(frame.payload);
            if (Array.isArray(data) && data[3] === "cursor_move") {
              sentFrames.push(data);
            }
          } catch {
            // ignore
          }
        });
      });

      await gotoWithUsername(page, "CoordUser");
      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });

      const canvas = page.locator("#canvas");
      const box = await canvas.boundingBox();
      // Move to a known position relative to canvas
      await page.mouse.move(box.x + 50, box.y + 75);
      await page.waitForTimeout(100);

      expect(sentFrames.length).toBeGreaterThanOrEqual(1);
      const payload = sentFrames[0][4];
      // Coordinates should be approximately 50, 75 (relative to canvas top-left)
      expect(payload.x).toBeCloseTo(50, 0);
      expect(payload.y).toBeCloseTo(75, 0);
    });
  });

  test.describe("Multi-user presence", () => {
    test("two users see each other in the sidebar", async ({ browser }) => {
      const context1 = await browser.newContext();
      const context2 = await browser.newContext();
      const page1 = await context1.newPage();
      const page2 = await context2.newPage();

      try {
        // User 1 joins
        await gotoWithUsername(page1, "Alice");
        await expect(page1.locator("#user-list li")).toHaveCount(1, {
          timeout: 10_000,
        });

        // User 2 joins
        await gotoWithUsername(page2, "Bob");
        await expect(page2.locator("#user-list li")).toHaveCount(2, {
          timeout: 10_000,
        });

        // User 2's sidebar should list both Alice and Bob
        const page2Users = page2.locator("#user-list li");
        const userTexts = await page2Users.allTextContents();
        const allText = userTexts.join(" ");
        expect(allText).toContain("Alice");
        expect(allText).toContain("Bob");

        // User 1's sidebar should also update to show both
        await expect(page1.locator("#user-list li")).toHaveCount(2, {
          timeout: 10_000,
        });
      } finally {
        await context1.close();
        await context2.close();
      }
    });

    test("user disappears from sidebar when disconnected", async ({
      browser,
    }) => {
      const context1 = await browser.newContext();
      const context2 = await browser.newContext();
      const page1 = await context1.newPage();
      const page2 = await context2.newPage();

      try {
        // Both users join
        await gotoWithUsername(page1, "Stays");
        await expect(page1.locator("#user-list li")).toHaveCount(1, {
          timeout: 10_000,
        });

        await gotoWithUsername(page2, "Leaves");
        await expect(page1.locator("#user-list li")).toHaveCount(2, {
          timeout: 10_000,
        });

        // User 2 disconnects
        await context2.close();

        // User 1's sidebar should update to show only themselves
        await expect(page1.locator("#user-list li")).toHaveCount(1, {
          timeout: 10_000,
        });
        await expect(page1.locator("#user-list li").first()).toContainText(
          "Stays"
        );
      } finally {
        await context1.close();
      }
    });

    test("three users all appear in each sidebar", async ({ browser }) => {
      const contexts = await Promise.all([
        browser.newContext(),
        browser.newContext(),
        browser.newContext(),
      ]);
      const pages = await Promise.all(contexts.map((c) => c.newPage()));

      try {
        const names = ["Curly", "Larry", "Moe"];

        // Join sequentially to ensure stable presence
        for (let i = 0; i < 3; i++) {
          await gotoWithUsername(pages[i], names[i]);
          // Wait until this page sees itself
          await expect(pages[i].locator("#user-list li")).toHaveCount(
            i + 1,
            { timeout: 10_000 }
          );
        }

        // Each page should see all 3 users
        for (let i = 0; i < 3; i++) {
          await expect(pages[i].locator("#user-list li")).toHaveCount(3, {
            timeout: 10_000,
          });
        }
      } finally {
        await Promise.all(contexts.map((c) => c.close()));
      }
    });
  });

  test.describe("Remote cursor rendering", () => {
    test("remote cursor element appears on mousemove", async ({ browser }) => {
      const context1 = await browser.newContext();
      const context2 = await browser.newContext();
      const page1 = await context1.newPage();
      const page2 = await context2.newPage();

      try {
        await gotoWithUsername(page1, "Mover");
        await expect(page1.locator("#user-list li")).toHaveCount(1, {
          timeout: 10_000,
        });

        await gotoWithUsername(page2, "Watcher");
        await expect(page2.locator("#user-list li")).toHaveCount(2, {
          timeout: 10_000,
        });

        // User 1 moves their mouse on the canvas
        const canvas1 = page1.locator("#canvas");
        const box = await canvas1.boundingBox();
        await page1.mouse.move(box.x + 150, box.y + 150);
        await page1.waitForTimeout(200);
        await page1.mouse.move(box.x + 200, box.y + 200);
        await page1.waitForTimeout(200);

        // User 2 should see a remote cursor element with SVG and label
        await expect(page2.locator("#canvas .cursor")).toHaveCount(1, {
          timeout: 5_000,
        });
        await expect(page2.locator("#canvas .cursor svg")).toBeVisible();
        await expect(
          page2.locator("#canvas .cursor .cursor-label")
        ).toHaveText("Mover");
      } finally {
        await context1.close();
        await context2.close();
      }
    });

    test("remote cursor position updates on movement", async ({ browser }) => {
      const context1 = await browser.newContext();
      const context2 = await browser.newContext();
      const page1 = await context1.newPage();
      const page2 = await context2.newPage();

      try {
        await gotoWithUsername(page1, "MovingUser");
        await expect(page1.locator("#user-list li")).toHaveCount(1, {
          timeout: 10_000,
        });

        await gotoWithUsername(page2, "Observer");
        await expect(page2.locator("#user-list li")).toHaveCount(2, {
          timeout: 10_000,
        });

        // Move to first position
        const canvas1 = page1.locator("#canvas");
        const box = await canvas1.boundingBox();
        await page1.mouse.move(box.x + 100, box.y + 100);
        await page1.waitForTimeout(200);

        // Wait for cursor to appear on page2
        await expect(page2.locator("#canvas .cursor")).toHaveCount(1, {
          timeout: 5_000,
        });

        // Move to second position
        await page1.mouse.move(box.x + 300, box.y + 300);
        await page1.waitForTimeout(200);

        // Verify the cursor's transform updated
        const cursor = page2.locator("#canvas .cursor").first();
        const transform = await cursor.evaluate(
          (el) => el.style.transform
        );
        // Should contain translate with values near 300, 300
        expect(transform).toMatch(/translate\([\d.]+px,\s*[\d.]+px\)/);
        const match = transform.match(
          /translate\(([\d.]+)px,\s*([\d.]+)px\)/
        );
        expect(Number(match[1])).toBeGreaterThan(200);
        expect(Number(match[2])).toBeGreaterThan(200);
      } finally {
        await context1.close();
        await context2.close();
      }
    });

    test("cursor label shows remote username with color", async ({
      browser,
    }) => {
      const context1 = await browser.newContext();
      const context2 = await browser.newContext();
      const page1 = await context1.newPage();
      const page2 = await context2.newPage();

      try {
        await gotoWithUsername(page1, "ColoredUser");
        await expect(page1.locator("#user-list li")).toHaveCount(1, {
          timeout: 10_000,
        });

        await gotoWithUsername(page2, "Viewer");
        await expect(page2.locator("#user-list li")).toHaveCount(2, {
          timeout: 10_000,
        });

        // Trigger cursor broadcast
        const canvas1 = page1.locator("#canvas");
        const box = await canvas1.boundingBox();
        await page1.mouse.move(box.x + 100, box.y + 100);
        await page1.waitForTimeout(200);

        // Check label on page2
        const label = page2.locator("#canvas .cursor .cursor-label");
        await expect(label).toHaveText("ColoredUser", { timeout: 5_000 });
        // Label should have a background color set (browser may normalize HSL to RGB)
        const bg = await label.evaluate(
          (el) => el.style.background || el.style.backgroundColor
        );
        expect(bg).toBeTruthy();
        expect(bg).toMatch(/hsl|rgb/);
      } finally {
        await context1.close();
        await context2.close();
      }
    });
  });

  test.describe("Canvas interaction", () => {
    test("canvas hides the default cursor", async ({ page }) => {
      await page.goto("/");
      const cursor = await page.locator("#canvas").evaluate((el) => {
        return getComputedStyle(el).cursor;
      });
      expect(cursor).toBe("none");
    });

    test("canvas has a grid background pattern", async ({ page }) => {
      await page.goto("/");
      const bg = await page.locator("#canvas").evaluate((el) => {
        return getComputedStyle(el).backgroundImage;
      });
      // Should have a linear-gradient for the grid lines
      expect(bg).toContain("linear-gradient");
    });
  });

  test.describe("Responsive layout", () => {
    test("works at mobile viewport (375x667)", async ({ browser }) => {
      const context = await browser.newContext({
        viewport: { width: 375, height: 667 },
      });
      const page = await context.newPage();

      try {
        await page.goto("/");
        await expect(page.locator("#app")).toBeVisible();
        await expect(page.locator("#canvas")).toBeVisible();
        await expect(page.locator("#sidebar")).toBeVisible();
      } finally {
        await context.close();
      }
    });

    test("works at wide viewport (1920x1080)", async ({ browser }) => {
      const context = await browser.newContext({
        viewport: { width: 1920, height: 1080 },
      });
      const page = await context.newPage();

      try {
        await page.goto("/");
        const app = page.locator("#app");
        const box = await app.boundingBox();
        expect(box.width).toBe(1920);
        expect(box.height).toBe(1080);
      } finally {
        await context.close();
      }
    });
  });

  test.describe("404 handling", () => {
    test("returns 404 for unknown routes", async ({ page }) => {
      const response = await page.goto("/nonexistent");
      expect(response?.status()).toBe(404);
    });
  });
});
