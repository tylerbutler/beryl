import { test, expect, openDemo, pauseNextMotion, finishMotion } from "./demo-test";

test("each voter receives a reply and only its peer receives a broadcast", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	const root = await openDemo(page, 1);
	const alice = root.getByRole("region", { name: "Alice's socket" });
	const bob = root.getByRole("region", { name: "Bob's socket" });
	for (const client of [alice, bob]) {
		await expect(client.locator("[data-private]")).toHaveText('topics: {"poll:demo"}');
		await expect(client.locator("[data-delivery]")).toHaveText("Reply to get_state");
	}
	await alice.getByRole("button", { name: "Vote Gleam" }).click();
	await expect(alice.locator("[data-delivery]")).toHaveText("Reply to vote");
	await expect(bob.locator("[data-delivery]")).toHaveText("Peer broadcast: poll_state");
	await bob.getByRole("button", { name: "Vote Erlang" }).click();
	await expect(bob.locator("[data-delivery]")).toHaveText("Reply to vote");
	await expect(alice.locator("[data-delivery]")).toHaveText("Peer broadcast: poll_state");
	await bob.getByRole("button", { name: "Vote Erlang" }).click();
	for (const client of [alice, bob]) {
		await expect(client.locator("[data-receipt]")).toHaveText("Gleam 1 / Erlang 2");
		await expect(client.locator("[data-private]")).toHaveText('topics: {"poll:demo"}');
	}
	await expect(root.locator("[data-effects]")).toContainText('BroadcastFrom("poll:demo"');
});

test("reconnect fetches existing totals; final disconnect removes the room", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	const root = await openDemo(page, 1);
	const alice = root.locator('[data-client="Alice"]');
	const bob = root.locator('[data-client="Bob"]');
	await alice.getByRole("button", { name: "Vote Gleam" }).click();
	await root.getByRole("button", { name: "Disconnect Alice" }).click();
	await expect(alice.getByRole("button", { name: "Vote Gleam" })).toBeDisabled();
	await expect(alice.locator("[data-private]")).toContainText("No model");
	await bob.getByRole("button", { name: "Vote Erlang" }).click();
	await expect(alice.locator("[data-receipt]")).toHaveText("Gleam 1 / Erlang 0");
	await expect(root.locator("[data-members]")).toHaveText("Room members: 1");
	await root.getByRole("button", { name: "Reconnect Alice" }).click();
	await expect(alice.locator("[data-receipt]")).toHaveText("Gleam 1 / Erlang 1");
	await expect(alice.locator("[data-delivery]")).toHaveText("Reply to get_state");
	await root.getByRole("button", { name: "Disconnect Alice" }).click();
	await root.getByRole("button", { name: "Disconnect Bob" }).click();
	await expect(root.locator("[data-room]")).toHaveText("Room removed");
	await expect(root.locator("[data-members]")).toHaveText("Room members: 0");
	await expect(root.getByText("Shared store actor: running", { exact: true })).toBeVisible();
	await root.getByRole("button", { name: "Reconnect Bob" }).click();
	await expect(bob.locator("[data-receipt]")).toHaveText("Gleam 0 / Erlang 0");
});

test("disconnect during flight skips that instance but preserves its peer delivery", async ({ page }) => {
	const root = await openDemo(page, 1);
	await pauseNextMotion(root);
	await root.locator('[data-client="Alice"]').getByRole("button", { name: "Vote Gleam" }).click();
	await root.getByRole("button", { name: "Disconnect Alice" }).click();
	await root.getByRole("button", { name: "Reconnect Alice" }).click();
	await finishMotion(root);
	await expect(root).toHaveAttribute("data-busy", "false");
	await expect(root.locator('[data-client="Alice"] [data-delivery]')).toHaveText("Reply to get_state");
	await expect(root.locator('[data-client="Bob"] [data-delivery]')).toHaveText("Peer broadcast: poll_state");
	await expect(root.locator('[data-client="Bob"] [data-receipt]')).toHaveText("Gleam 1 / Erlang 0");
});

test("an old vote cannot recreate a deleted room or overwrite a new socket", async ({ page }) => {
	const root = await openDemo(page, 1);
	await pauseNextMotion(root);
	await root.locator('[data-client="Alice"]').getByRole("button", { name: "Vote Gleam" }).click();
	await root.getByRole("button", { name: "Disconnect Alice" }).click();
	await root.getByRole("button", { name: "Disconnect Bob" }).click();
	await root.getByRole("button", { name: "Reconnect Alice" }).click();
	await finishMotion(root);
	await expect(root).toHaveAttribute("data-busy", "false");
	await expect(root.locator("[data-totals]")).toHaveText("Gleam 0 / Erlang 0");
	await expect(root.locator('[data-client="Alice"] [data-receipt]')).toHaveText("Gleam 0 / Erlang 0");
	await expect(root.locator('[data-client="Alice"] [data-delivery]')).toHaveText("Reply to get_state");
});

test("reset cancels pending vote delivery and restores both initial fetches", async ({ page }) => {
	const root = await openDemo(page, 1);
	await pauseNextMotion(root);
	await root.locator('[data-client="Alice"]').getByRole("button", { name: "Vote Gleam" }).click();
	const pending = await root.evaluateHandle((element) => element.getAnimations({ subtree: true }));
	await root.getByRole("button", { name: "Reset", exact: true }).click();
	await pending.evaluate((animations) => {
		for (const animation of animations) animation.dispatchEvent(new Event("finish"));
	});
	await expect(root).toHaveAttribute("data-busy", "false");
	await expect(root.locator("[data-totals]")).toHaveText("Gleam 0 / Erlang 0");
	await expect(root.locator("[data-members]")).toHaveText("Room members: 2");
	for (const name of ["Alice", "Bob"]) {
		await expect(root.locator(`[data-client="${name}"] [data-delivery]`)).toHaveText("Reply to get_state");
	}
});

test("client totals stay at the last receipt while the request travels", async ({ page }) => {
	const root = await openDemo(page, 1);
	await pauseNextMotion(root);
	await root.locator('[data-client="Alice"]').getByRole("button", { name: "Vote Gleam" }).click();
	await expect(root.locator("[data-totals]")).toHaveText("Gleam 1 / Erlang 0");
	for (const name of ["Alice", "Bob"]) {
		const client = root.locator(`[data-client="${name}"]`);
		await expect(client.locator("[data-receipt]")).toHaveText("Gleam 0 / Erlang 0");
		await expect(client.getByRole("button", { name: "Vote Gleam" })).toBeDisabled();
	}
	await finishMotion(root);
	await expect(root).toHaveAttribute("data-busy", "false");
	await expect(root.locator('[data-client="Alice"] [data-receipt]')).toHaveText("Gleam 1 / Erlang 0");
});
