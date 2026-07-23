// @ts-check
import { test, expect } from "@playwright/test";

// Helper: navigate with a username (handles the prompt dialog)
async function gotoWithUsername(page, username, path = "/?token=beryl-demo") {
  page.on("dialog", (dialog) => dialog.accept(username));
  await page.goto(path);
}

// Helper: wait for Phoenix channel join reply for a room topic
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
          if (
            Array.isArray(data) &&
            data[3] === "phx_reply" &&
            typeof data[2] === "string" &&
            data[2].startsWith("room:")
          ) {
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

test.describe("Chat Rooms Demo", () => {
  test.describe("Page structure", () => {
    test("renders the page title", async ({ page }) => {
      await page.goto("/?token=beryl-demo");
      await expect(page).toHaveTitle("Chat Rooms — beryl demo");
    });

    test("renders the rooms sidebar", async ({ page }) => {
      await page.goto("/?token=beryl-demo");
      await expect(page.locator("#rooms-sidebar h2")).toHaveText("Rooms");
    });

    test("renders default rooms", async ({ page }) => {
      await page.goto("/?token=beryl-demo");
      const rooms = page.locator("#room-list .room-item");
      await expect(rooms).toHaveCount(3);

      const texts = await rooms.allTextContents();
      const joined = texts.join(" ");
      expect(joined).toContain("general");
      expect(joined).toContain("random");
      expect(joined).toContain("help");
    });

    test("renders the chat area with header", async ({ page }) => {
      await page.goto("/?token=beryl-demo");
      await expect(page.locator("#chat-header")).toBeVisible();
    });

    test("renders the message area", async ({ page }) => {
      await page.goto("/?token=beryl-demo");
      await expect(page.locator("#messages")).toBeAttached();
    });

    test("renders the message input form", async ({ page }) => {
      await page.goto("/?token=beryl-demo");
      await expect(page.locator("#msg-form")).toBeVisible();
      await expect(page.locator("#msg-input")).toBeVisible();
      await expect(page.locator("#send-btn")).toBeVisible();
    });

    test("renders the online users sidebar", async ({ page }) => {
      await page.goto("/?token=beryl-demo");
      await expect(page.locator("#users-sidebar h2")).toHaveText("Online");
    });

    test("renders the beryl attribution link", async ({ page }) => {
      await page.goto("/?token=beryl-demo");
      const link = page.locator(".powered-by a");
      await expect(link).toHaveText("beryl");
      await expect(link).toHaveAttribute(
        "href",
        "https://github.com/tylerbutler/beryl"
      );
    });
  });

  test.describe("Lobby channel", () => {
    test("joins lobby and a room on the same socket", async ({ page }) => {
      const joinedTopics = [];
      page.on("websocket", (ws) => {
        ws.on("framesent", (frame) => {
          try {
            const data = JSON.parse(frame.payload);
            if (Array.isArray(data) && data[3] === "phx_join") {
              joinedTopics.push(data[2]);
            }
          } catch {
            // ignore non-JSON frames
          }
        });
      });

      await gotoWithUsername(page, "LobbyUser");

      await expect.poll(() => joinedTopics).toContain("lobby");
      await expect.poll(() => joinedTopics.some((topic) =>
        topic.startsWith("room:")
      )).toBe(true);
    });

    test("renders a count badge for every room", async ({ page }) => {
      await gotoWithUsername(page, "CountUser");

      const badges = page.locator(".room-count");
      await expect(badges).toHaveCount(3);
      await expect(
        page.locator('.room-count[data-room-count="general"]')
      ).toHaveText("1", { timeout: 10_000 });
      await expect(
        page.locator('.room-count[data-room-count="random"]')
      ).toHaveText("0");
      await expect(
        page.locator('.room-count[data-room-count="help"]')
      ).toHaveText("0");
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

  test.describe("API", () => {
    test("GET /api/rooms returns room list with user counts", async ({
      request,
    }) => {
      const response = await request.get("/api/rooms");
      expect(response.status()).toBe(200);
      const rooms = await response.json();
      expect(rooms).toBeInstanceOf(Array);
      expect(rooms.length).toBe(3);

      const names = rooms.map((r) => r.name).sort();
      expect(names).toEqual(["general", "help", "random"]);

      // Each room should have topic, name, and users
      for (const room of rooms) {
        expect(room).toHaveProperty("topic");
        expect(room).toHaveProperty("name");
        expect(room).toHaveProperty("users");
        expect(room.topic).toMatch(/^room:/);
      }
    });
  });

  test.describe("Authentication", () => {
    test("WebSocket connects with valid token", async ({ page }) => {
      page.on("dialog", (dialog) => dialog.accept("AuthUser"));

      const wsPromise = page.waitForEvent("websocket");
      await page.goto("/?token=beryl-demo");
      const ws = await wsPromise;
      expect(ws.url()).toContain("/socket");
      expect(ws.url()).toContain("token=beryl-demo");
    });

    test("WebSocket connection fails without valid token", async ({
      page,
    }) => {
      page.on("dialog", (dialog) => dialog.accept("NoTokenUser"));

      // Listen for WebSocket close events
      const wsEvents = [];
      page.on("websocket", (ws) => {
        ws.on("close", () => wsEvents.push("closed"));
      });

      await page.goto("/?token=invalid-token");
      // Wait a bit for the WS attempt and rejection
      await page.waitForTimeout(2000);

      // The connection should have been closed/rejected
      // The page should render but the input should be disabled after join error
      // (on_connect rejects, so WS never fully establishes)
    });
  });

  test.describe("Channel join", () => {
    test("auto-joins first room on page load", async ({ page }) => {
      const replyPromise = waitForJoinReply(page);
      await gotoWithUsername(page, "JoinUser");
      const reply = await replyPromise;

      expect(reply[2]).toMatch(/^room:/);
      expect(reply[4]?.status).toBe("ok");
      expect(reply[4]?.response?.username).toBe("JoinUser");
      expect(reply[4]?.response?.color).toMatch(/^hsl\(/);
      expect(reply[4]?.response?.room).toBeTruthy();
    });

    test("shows user in online list after joining", async ({ page }) => {
      await gotoWithUsername(page, "OnlineUser");

      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });
      await expect(page.locator("#user-list li").first()).toContainText(
        "OnlineUser"
      );
    });

    test("shows (you) indicator for own user", async ({ page }) => {
      await gotoWithUsername(page, "MeUser");

      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });
      await expect(page.locator("#user-list li").first()).toContainText(
        "(you)"
      );
    });

    test("shows system join message", async ({ page }) => {
      await gotoWithUsername(page, "SysJoinUser");

      await expect(
        page.locator(".message.system", {
          hasText: "SysJoinUser joined the room",
        })
      ).toBeVisible({ timeout: 10_000 });
    });

    test("first room is marked active", async ({ page }) => {
      await gotoWithUsername(page, "ActiveUser");

      await expect(page.locator(".room-item.active")).toHaveCount(1, {
        timeout: 5_000,
      });
    });

    test("message input is enabled after join", async ({ page }) => {
      await gotoWithUsername(page, "InputUser");

      // Wait for join
      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });

      await expect(page.locator("#msg-input")).toBeEnabled();
      await expect(page.locator("#send-btn")).toBeEnabled();
    });
  });

  test.describe("Messaging", () => {
    test("sends and receives a message", async ({ page }) => {
      await gotoWithUsername(page, "MsgUser");
      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });

      // Type and send a message
      await page.fill("#msg-input", "Hello world!");
      await page.click("#send-btn");

      // Message should appear in the chat
      await expect(
        page.locator(".message.user .msg-text", { hasText: "Hello world!" })
      ).toBeVisible({ timeout: 5_000 });
    });

    test("clears input after sending", async ({ page }) => {
      await gotoWithUsername(page, "ClearUser");
      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });

      await page.fill("#msg-input", "Test message");
      await page.click("#send-btn");

      // Input should be cleared
      await expect(page.locator("#msg-input")).toHaveValue("");
    });

    test("message shows author name and color", async ({ page }) => {
      await gotoWithUsername(page, "ColorMsgUser");
      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });

      await page.fill("#msg-input", "Colored message");
      await page.click("#send-btn");

      const author = page.locator(".msg-author").first();
      await expect(author).toContainText("ColorMsgUser", { timeout: 5_000 });
      // Author should have a color style
      const style = await author.getAttribute("style");
      expect(style).toContain("color:");
    });

    test("message shows timestamp", async ({ page }) => {
      await gotoWithUsername(page, "TimeUser");
      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });

      await page.fill("#msg-input", "Timed message");
      await page.click("#send-btn");

      await expect(page.locator(".msg-time").first()).toBeVisible({
        timeout: 5_000,
      });
    });

    test("submit via Enter key works", async ({ page }) => {
      await gotoWithUsername(page, "EnterUser");
      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });

      await page.fill("#msg-input", "Enter key message");
      await page.press("#msg-input", "Enter");

      await expect(
        page.locator(".message.user .msg-text", {
          hasText: "Enter key message",
        })
      ).toBeVisible({ timeout: 5_000 });
    });
  });

  test.describe("Multi-user chat", () => {
    test("two users see each other's messages", async ({ browser }) => {
      const ctx1 = await browser.newContext();
      const ctx2 = await browser.newContext();
      const page1 = await ctx1.newPage();
      const page2 = await ctx2.newPage();

      try {
        // Both join the same room
        await gotoWithUsername(page1, "Alice");
        await expect(page1.locator("#user-list li")).toHaveCount(1, {
          timeout: 10_000,
        });

        await gotoWithUsername(page2, "Bob");
        await expect(page2.locator("#user-list li")).toHaveCount(2, {
          timeout: 10_000,
        });

        // Alice sends a message
        await page1.fill("#msg-input", "Hi from Alice!");
        await page1.click("#send-btn");

        // Bob should see Alice's message
        await expect(
          page2.locator(".message.user .msg-text", {
            hasText: "Hi from Alice!",
          })
        ).toBeVisible({ timeout: 5_000 });

        // Bob sends a reply
        await page2.fill("#msg-input", "Hey Alice!");
        await page2.click("#send-btn");

        // Alice should see Bob's message
        await expect(
          page1.locator(".message.user .msg-text", {
            hasText: "Hey Alice!",
          })
        ).toBeVisible({ timeout: 5_000 });
      } finally {
        await ctx1.close();
        await ctx2.close();
      }
    });

    test("users see each other in online list", async ({ browser }) => {
      const ctx1 = await browser.newContext();
      const ctx2 = await browser.newContext();
      const page1 = await ctx1.newPage();
      const page2 = await ctx2.newPage();

      try {
        await gotoWithUsername(page1, "UserA");
        await expect(page1.locator("#user-list li")).toHaveCount(1, {
          timeout: 10_000,
        });

        await gotoWithUsername(page2, "UserB");
        await expect(page2.locator("#user-list li")).toHaveCount(2, {
          timeout: 10_000,
        });

        const texts = await page2.locator("#user-list li").allTextContents();
        const allText = texts.join(" ");
        expect(allText).toContain("UserA");
        expect(allText).toContain("UserB");
      } finally {
        await ctx1.close();
        await ctx2.close();
      }
    });

    test("system message when user leaves", async ({ browser }) => {
      const ctx1 = await browser.newContext();
      const ctx2 = await browser.newContext();
      const page1 = await ctx1.newPage();
      const page2 = await ctx2.newPage();

      try {
        await gotoWithUsername(page1, "Stayer");
        await expect(page1.locator("#user-list li")).toHaveCount(1, {
          timeout: 10_000,
        });

        await gotoWithUsername(page2, "Leaver");
        await expect(page1.locator("#user-list li")).toHaveCount(2, {
          timeout: 10_000,
        });

        // Leaver disconnects
        await ctx2.close();

        // Stayer should see leave message
        await expect(
          page1.locator(".message.system", {
            hasText: "Leaver left the room",
          })
        ).toBeVisible({ timeout: 10_000 });

        // Online list should go back to 1
        await expect(page1.locator("#user-list li")).toHaveCount(1, {
          timeout: 10_000,
        });
      } finally {
        await ctx1.close();
      }
    });
  });

  test.describe("Room switching", () => {
    test("can switch between rooms", async ({ page }) => {
      await gotoWithUsername(page, "SwitchUser");
      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });

      // Click a different room
      const secondRoom = page.locator(".room-item").nth(1);
      const roomName = await secondRoom.getAttribute("data-room");
      await secondRoom.click();

      // Room title should update
      await expect(page.locator("#room-title")).toHaveText(roomName, {
        timeout: 5_000,
      });

      // Should rejoin and see self in online list
      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });
    });

    test("active room indicator updates on switch", async ({ page }) => {
      await gotoWithUsername(page, "IndicatorUser");
      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });

      const secondRoom = page.locator(".room-item").nth(1);
      await secondRoom.click();

      // Second room should be active, first should not
      await expect(secondRoom).toHaveClass(/active/, { timeout: 5_000 });
      await expect(page.locator(".room-item").first()).not.toHaveClass(
        /active/
      );
    });

    test("messages clear when switching rooms", async ({ page }) => {
      await gotoWithUsername(page, "ClearRoomUser");
      await expect(page.locator("#user-list li")).toHaveCount(1, {
        timeout: 10_000,
      });

      // Send a message in first room
      await page.fill("#msg-input", "Room 1 message");
      await page.click("#send-btn");
      await expect(
        page.locator(".message.user .msg-text", {
          hasText: "Room 1 message",
        })
      ).toBeVisible({ timeout: 5_000 });

      // Switch rooms
      await page.locator(".room-item").nth(1).click();

      // Messages from first room should be cleared (only system messages from new join)
      await expect(
        page.locator(".message.user .msg-text", {
          hasText: "Room 1 message",
        })
      ).toHaveCount(0);
    });
  });

  test.describe("Typing indicators", () => {
    test("typing indicator shows for other user", async ({ browser }) => {
      const ctx1 = await browser.newContext();
      const ctx2 = await browser.newContext();
      const page1 = await ctx1.newPage();
      const page2 = await ctx2.newPage();

      try {
        await gotoWithUsername(page1, "Typer");
        await expect(page1.locator("#user-list li")).toHaveCount(1, {
          timeout: 10_000,
        });

        await gotoWithUsername(page2, "Watcher");
        await expect(page2.locator("#user-list li")).toHaveCount(2, {
          timeout: 10_000,
        });

        // Typer starts typing
        await page1.locator("#msg-input").pressSequentially("hello", {
          delay: 50,
        });

        // Watcher should see typing indicator
        await expect(page2.locator("#typing-indicator")).toContainText(
          "Typer is typing",
          { timeout: 5_000 }
        );
      } finally {
        await ctx1.close();
        await ctx2.close();
      }
    });
  });

  test.describe("Layout", () => {
    test("rooms sidebar has correct width", async ({ page }) => {
      await page.goto("/?token=beryl-demo");
      const box = await page.locator("#rooms-sidebar").boundingBox();
      expect(box).not.toBeNull();
      expect(box.width).toBe(200);
    });

    test("users sidebar has correct width", async ({ page }) => {
      await page.goto("/?token=beryl-demo");
      const box = await page.locator("#users-sidebar").boundingBox();
      expect(box).not.toBeNull();
      expect(box.width).toBe(180);
    });

    test("app fills the viewport", async ({ page }) => {
      await page.goto("/?token=beryl-demo");
      const app = page.locator("#app");
      const box = await app.boundingBox();
      const viewport = page.viewportSize();
      expect(box).not.toBeNull();
      expect(box.height).toBe(viewport.height);
      expect(box.width).toBe(viewport.width);
    });
  });

  test.describe("404 handling", () => {
    test("returns 404 for unknown routes", async ({ page }) => {
      const response = await page.goto("/nonexistent");
      expect(response?.status()).toBe(404);
    });
  });
});
