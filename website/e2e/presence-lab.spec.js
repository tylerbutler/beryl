import { expect, test } from "@playwright/test";

test("static fallback remains readable without JavaScript", async ({ page }) => {
  await page.goto("/examples/");
  await expect(page.getByText("Enable JavaScript to run the live scenario")).toBeVisible();
});

test("connects two clients and records join and leave diffs", async ({ page }) => {
  await page.goto("/examples/");
  const lab = page.locator("beryl-presence-lab");
  const control = (testId) => lab.getByTestId(testId);

  await control("primary-name").fill("Alice");
  await control("connect-primary").click();
  await expect(control("presence-status")).toContainText("Connected");
  await expect(control("presence-list").locator("li")).toHaveCount(1);

  await control("add-secondary").click();
  await expect(control("presence-list").locator("li")).toHaveCount(2);
  await expect(control("event-transcript")).toContainText("presence_diff");

  await control("disconnect-secondary").click();
  await expect(control("presence-list").locator("li")).toHaveCount(1);
  await expect(control("event-transcript")).toContainText("leave");
});

test("reset creates a fresh isolated scenario", async ({ page }) => {
  await page.goto("/examples/");
  const lab = page.locator("beryl-presence-lab");
  const control = (testId) => lab.getByTestId(testId);
  await control("connect-primary").click();
  await expect(control("presence-status")).toContainText("Connected");
  const firstTopic = await control("scenario-topic").textContent();

  await control("reset-scenario").click();
  await expect(control("presence-status")).toContainText("Connected");
  const secondTopic = await control("scenario-topic").textContent();

  expect(secondTopic).not.toBe(firstTopic);
});

test("recovers after the browser goes offline", async ({ page, context }) => {
  await page.goto("/examples/");
  const lab = page.locator("beryl-presence-lab");
  const control = (testId) => lab.getByTestId(testId);
  await control("connect-primary").click();
  await expect(control("presence-status")).toContainText("Connected");

  await context.setOffline(true);
  await expect(control("presence-status")).toContainText("Offline");
  await expect(
    page.getByText("This lab connects two short-lived Phoenix clients"),
  ).toBeVisible();

  await context.setOffline(false);
  await expect(control("presence-status")).toContainText("Connected", {
    timeout: 20_000,
  });
});

test("blocks incompatible component versions", async ({ page }) => {
  await page.goto("/examples/");
  const lab = page.locator("beryl-presence-lab");
  const control = (testId) => lab.getByTestId(testId);
  await lab.evaluate((element) => {
    element.setAttribute("compatibility-version", "99");
  });

  await control("connect-primary").click();
  await expect(control("presence-status")).toContainText("Incompatible");
  await expect(control("connect-primary")).toBeDisabled();
});

test("supports keyboard operation at a mobile width", async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 812 });
  await page.goto("/examples/");
  const lab = page.locator("beryl-presence-lab");
  const control = (testId) => lab.getByTestId(testId);

  await control("connect-primary").focus();
  await page.keyboard.press("Enter");
  await expect(control("presence-status")).toContainText("Connected");

  const hasHorizontalOverflow = await page.evaluate(
    () => document.documentElement.scrollWidth > window.innerWidth,
  );
  expect(hasHorizontalOverflow).toBe(false);
});
