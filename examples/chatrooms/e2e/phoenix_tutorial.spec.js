// @ts-check
import { test, expect } from "@playwright/test";

async function openTutorial(page) {
  await page.goto("/phoenix");
  await expect.poll(() => page.evaluate(async () => {
    const { default: socket } = await import("/static/phoenix_tutorial.js");
    return socket.channels.find((channel) => channel.topic === "room:lobby")
      .isJoined();
  })).toBe(true);
}

test("the tutorial client exchanges exact bodies, including the sender", async ({
  page,
  browser,
}) => {
  const peerContext = await browser.newContext();
  try {
    const peer = await peerContext.newPage();
    await Promise.all([openTutorial(page), openTutorial(peer)]);
    for (const client of [page, peer]) {
      await client.evaluate(async () => {
        const { default: socket } = await import("/static/phoenix_tutorial.js");
        const channel = socket.channels.find((item) => item.topic === "room:lobby");
        window.tutorialMessages = [];
        channel.on("new_msg", (payload) => window.tutorialMessages.push(payload));
      });
    }

    const bodies = ["  Hello from the tutorial  ", "Hello from another tab", "", "<img src=x onerror=alert(1)>"];
    for (let index = 0; index < bodies.length; index++) {
      const sender = index % 2 === 0 ? page : peer;
      await sender.locator("#chat-input").fill(bodies[index]);
      await sender.locator("#chat-input").press("Enter");
      await expect(sender.locator("#chat-input")).toHaveValue("");
      const expected = bodies.slice(0, index + 1).map((body) => ({ body }));
      for (const client of [page, peer]) {
        await expect.poll(() => client.evaluate(() => window.tutorialMessages))
          .toEqual(expected);
        await expect(client.locator("#messages p")).toHaveCount(index + 1);
        const text = await client.locator("#messages p").last().textContent();
        expect(text.endsWith(`] ${bodies[index]}`)).toBe(true);
      }
    }
    await expect(page.locator("#messages img")).toHaveCount(0);
    await expect(peer.locator("#messages img")).toHaveCount(0);
  } finally {
    await peerContext.close();
  }
});

test("the official client handles rejected joins, invalid bodies, and leave/rejoin", async ({
  page,
  request,
}) => {
  await openTutorial(page);
  const result = await page.evaluate(async () => {
    const { default: socket } = await import("/static/phoenix_tutorial.js");
    const lobby = socket.channels.find((channel) => channel.topic === "room:lobby");
    const privateRoom = socket.channel("room:private", {});
    const rejection = await new Promise((resolve, reject) => {
      privateRoom.join()
        .receive("error", resolve)
        .receive("ok", () => reject(new Error("Private room was accepted")))
        .receive("timeout", () => reject(new Error("Private join timed out")));
    });
    const invalidBody = await new Promise((resolve, reject) => {
      lobby.push("new_msg", { body: 42 })
        .receive("error", resolve)
        .receive("ok", () => reject(new Error("Invalid body was accepted")))
        .receive("timeout", () => reject(new Error("Invalid body reply timed out")));
    });
    await new Promise((resolve, reject) => {
      lobby.leave()
        .receive("ok", resolve)
        .receive("timeout", () => reject(new Error("Leave timed out")));
    });
    const rejoined = socket.channel("room:lobby", {});
    const joinReply = await new Promise((resolve, reject) => {
      rejoined.join()
        .receive("ok", resolve)
        .receive("error", reject)
        .receive("timeout", () => reject(new Error("Rejoin timed out")));
    });
    const broadcastPromise = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("Broadcast timed out")), 5000);
      const reference = rejoined.on("new_msg", (payload) => {
        clearTimeout(timeout);
        rejoined.off("new_msg", reference);
        resolve(payload);
      });
    });
    const noReplyPromise = new Promise((resolve, reject) => {
      rejoined.push("new_msg", { body: "After rejoin" }, 1000)
        .receive("ok", () => reject(new Error("Tutorial sent a push acknowledgment")))
        .receive("error", () => reject(new Error("Valid tutorial body was rejected")))
        .receive("timeout", () => resolve("timeout"));
    });
    const [broadcast, pushStatus] = await Promise.all([broadcastPromise, noReplyPromise]);
    socket.disconnect();
    return { rejection, invalidBody, joinReply, broadcast, pushStatus };
  });
  expect(result).toEqual({
    rejection: { reason: "unauthorized" },
    invalidBody: { reason: "body must be a string" },
    joinReply: {},
    broadcast: { body: "After rejoin" },
    pushStatus: "timeout",
  });
  await expect(page.locator("#messages p")).toHaveCount(0);

  // The public tutorial does not bypass the original demo's token gate.
  expect((await request.get("/socket/websocket")).status()).toBe(403);
  expect((await request.get("/socket/websocket?token=beryl-demo")).status()).toBe(400);
});
