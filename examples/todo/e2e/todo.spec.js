// @ts-check
import { expect, test } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.goto("/");
  await page.evaluate(() => window.localStorage.clear());
  await page.reload();
});

test("adds, toggles, and deletes todos", async ({ page }) => {
  const input = page.getByRole("textbox", { name: "New todo" });

  await input.fill("   ");
  await page.getByRole("button", { name: "Add todo" }).click();
  await expect(page.getByRole("alert")).toContainText(
    "Enter a todo before adding it.",
  );
  await expect(page.getByRole("listitem")).toHaveCount(0);

  await input.fill("Write the guide");
  await input.press("Enter");
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

test("restores the saved list after reload", async ({ page }) => {
  const input = page.getByRole("textbox", { name: "New todo" });

  await input.fill("Survive a reload");
  await input.press("Enter");
  await page.getByRole("checkbox", { name: "Survive a reload" }).check();
  await expect(page.locator("#app-status")).toHaveText("Saved locally.");

  await page.reload();

  await expect(
    page.getByRole("checkbox", { name: "Survive a reload" }),
  ).toBeChecked();
  await expect(page.locator("#items-left")).toHaveText("0 items left");
  await expect(page.locator("#app-status")).toHaveText(
    "Saved todos restored.",
  );
});

test("recovers from malformed saved data", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(() => {
    window.localStorage.setItem("lustre.todo.v1", "{not json");
  });
  await page.reload();

  await expect(page.getByRole("alert")).toContainText(
    "Saved todos could not be read",
  );
  await expect(page.getByRole("listitem")).toHaveCount(0);

  const input = page.getByRole("textbox", { name: "New todo" });
  await input.fill("Replace damaged data");
  await input.press("Enter");

  await expect(page.getByRole("alert")).toHaveCount(0);
  await page.reload();
  await expect(
    page.getByRole("checkbox", { name: "Replace damaged data" }),
  ).toBeVisible();
});
