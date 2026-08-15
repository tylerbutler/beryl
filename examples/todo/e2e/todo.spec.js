// @ts-check
import { expect, test } from "@playwright/test";

const PHOENIX_FRAME = {
  topic: 2,
  event: 3,
  payload: 4,
  length: 5,
};

function parsePhoenixFrame(payload) {
  if (typeof payload !== "string") return undefined;

  try {
    const frame = JSON.parse(payload);
    if (!Array.isArray(frame) || frame.length !== PHOENIX_FRAME.length) {
      return undefined;
    }
    return {
      topic: frame[PHOENIX_FRAME.topic],
      event: frame[PHOENIX_FRAME.event],
      payload: frame[PHOENIX_FRAME.payload],
    };
  } catch {
    return undefined;
  }
}

async function waitForJoin(page) {
  await expect(page.locator("#connection-status")).toHaveText("Connected", {
    timeout: 10_000,
  });
  await expect(page.getByRole("textbox", { name: "New todo" })).toBeEnabled();
}

async function cleanTodos(page) {
  let count = await page.getByRole("listitem").count();
  while (count > 0) {
    await page.getByRole("listitem").first().getByRole("button").click();
    count -= 1;
    await expect(page.getByRole("listitem")).toHaveCount(count);
  }
}

async function openClient(browser) {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto("/");
  await waitForJoin(page);
  return { context, page };
}

test.beforeEach(async ({ page }) => {
  await page.goto("/");
  await waitForJoin(page);
  await cleanTodos(page);
});

test("rejects blank input and performs add, toggle, and delete", async ({
  page,
}) => {
  const input = page.getByRole("textbox", { name: "New todo" });

  await input.fill("   ");
  await page.getByRole("button", { name: "Add todo" }).click();
  await expect(page.getByRole("alert")).toContainText(
    "Enter a todo before adding it.",
  );
  await expect(page.getByRole("listitem")).toHaveCount(0);

  await input.fill("Write the guide");
  await input.press("Enter");
  await expect(input).toHaveValue("");
  await input.fill("Ship the example");
  await input.press("Enter");

  await expect(page.getByRole("listitem")).toHaveCount(2);
  await expect(page.locator("#items-left")).toHaveText("2 items left");

  await page.getByRole("checkbox", { name: "Write the guide" }).check();
  await expect(page.locator("#items-left")).toHaveText("1 item left");

  await page.getByRole("button", { name: "Delete Ship the example" }).click();
  await expect(page.getByRole("listitem")).toHaveCount(1);
  await expect(page.locator("#items-left")).toHaveText("0 items left");
});

test("synchronizes canonical mutations between two browsers", async ({
  browser,
  page: alice,
}) => {
  const bob = await openClient(browser);

  try {
    const input = alice.getByRole("textbox", { name: "New todo" });
    await input.fill("Shared task");
    await input.press("Enter");

    await expect(
      bob.page.getByRole("checkbox", { name: "Shared task" }),
    ).toBeVisible();

    await bob.page.getByRole("checkbox", { name: "Shared task" }).check();
    await expect(
      alice.getByRole("checkbox", { name: "Shared task" }),
    ).toBeChecked();

    await alice.getByRole("button", { name: "Delete Shared task" }).click();
    await expect(bob.page.getByRole("listitem")).toHaveCount(0);
  } finally {
    await bob.context.close();
  }
});

test("late join receives the complete server snapshot", async ({
  browser,
  page,
}) => {
  const input = page.getByRole("textbox", { name: "New todo" });
  await input.fill("Already on the server");
  await input.press("Enter");
  await page
    .getByRole("checkbox", { name: "Already on the server" })
    .check();

  const late = await openClient(browser);
  try {
    await expect(
      late.page.getByRole("checkbox", { name: "Already on the server" }),
    ).toBeChecked();
    await expect(late.page.locator("#items-left")).toHaveText("0 items left");
  } finally {
    await late.context.close();
  }
});

test("uses Phoenix join, push, reply, and broadcast frames", async ({
  browser,
}) => {
  const context = await browser.newContext();
  const page = await context.newPage();
  const sent = [];
  const received = [];

  page.on("websocket", (socket) => {
    socket.on("framesent", (frame) => {
      const parsed = parsePhoenixFrame(frame.payload);
      if (parsed) sent.push(parsed);
    });
    socket.on("framereceived", (frame) => {
      const parsed = parsePhoenixFrame(frame.payload);
      if (parsed) received.push(parsed);
    });
  });

  try {
    await page.goto("/");
    await waitForJoin(page);

    await expect
      .poll(() =>
        sent.some(
          (frame) => frame.topic === "todos" && frame.event === "phx_join",
        ),
      )
      .toBe(true);

    const input = page.getByRole("textbox", { name: "New todo" });
    await input.fill("Inspect the wire");
    await input.press("Enter");

    await expect
      .poll(() =>
        sent.some(
          (frame) =>
            frame.topic === "todos" &&
            frame.event === "add_todo" &&
            frame.payload?.text === "Inspect the wire",
        ),
      )
      .toBe(true);
    await expect
      .poll(() =>
        received.some(
          (frame) =>
            frame.topic === "todos" &&
            frame.event === "phx_reply" &&
            frame.payload?.status === "ok" &&
            frame.payload?.response?.text === "Inspect the wire",
        ),
      )
      .toBe(true);
    await expect
      .poll(() =>
        received.some(
          (frame) =>
            frame.topic === "todos" &&
            frame.event === "todo_added" &&
            frame.payload?.text === "Inspect the wire",
        ),
      )
      .toBe(true);
  } finally {
    await context.close();
  }
});
