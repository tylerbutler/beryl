import { test, expect, openDemo, pauseNextMotion, finishMotion } from "./demo-test";

test("model changes do not send frames; requests can deliver zero and later counts", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	const root = await openDemo(page, 0);
	await expect(root.locator("[data-client-label]")).toHaveText("No reply yet");
	await root.getByRole("button", { name: "Request count" }).click();
	await expect(root.locator("[data-client]")).toHaveText("0");
	await root.getByRole("button", { name: "Reset", exact: true }).click();
	for (let i = 0; i < 3; i++) await root.getByRole("button", { name: "Increment model" }).click();
	await expect(root.locator("[data-model]")).toHaveText("3");
	await expect(root.locator("[data-client-label]")).toHaveText("No reply yet");
	await expect(root.locator("[data-result]")).toContainText("Next(3, [])");
	await root.getByRole("button", { name: "Request count" }).click();
	await expect(root.locator("[data-client]")).toHaveText("3");
	await expect(root.locator("[data-result]")).toContainText("ReplyOk(request ref, 3)");
	await root.getByRole("button", { name: "Increment model" }).click();
	await expect(root.locator("[data-model]")).toHaveText("4");
	await expect(root.locator("[data-client]")).toHaveText("3");
	await expect(root.locator("[data-client-label]")).toHaveText("1 behind the server");
});

test("a reply captures its value and allows increments but not another request", async ({ page }) => {
	const root = await openDemo(page, 0);
	await root.getByRole("button", { name: "Increment model" }).click();
	await pauseNextMotion(root);
	await root.getByRole("button", { name: "Request count" }).click();
	await expect(root.locator("[data-request]")).toBeDisabled();
	await root.getByRole("button", { name: "Increment model" }).click();
	await expect(root.locator("[data-model]")).toHaveText("2");
	await expect(root.locator("[data-client]")).toHaveText("--");
	await finishMotion(root);
	await expect(root.locator("[data-client]")).toHaveText("1");
	await expect(root.locator("[data-request]")).toBeEnabled();
	await expect(root.locator("[data-status]")).toContainText("captured");
});

test("reset cancels the delivery callback as well as its animation", async ({ page }) => {
	const root = await openDemo(page, 0);
	await root.getByRole("button", { name: "Increment model" }).click();
	await pauseNextMotion(root);
	await root.getByRole("button", { name: "Request count" }).click();
	const pending = await root.evaluateHandle((element) => element.getAnimations({ subtree: true }));
	await root.getByRole("button", { name: "Reset", exact: true }).click();
	await pending.evaluate((animations) => {
		for (const animation of animations) animation.dispatchEvent(new Event("finish"));
	});
	await expect(root.locator("[data-model]")).toHaveText("0");
	await expect(root.locator("[data-client-label]")).toHaveText("No reply yet");
	await expect(root.locator("[data-request]")).toBeEnabled();
	expect(await root.evaluate((element) => element.getAnimations({ subtree: true }).length)).toBe(0);
});
