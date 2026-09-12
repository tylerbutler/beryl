import { test, expect, openDemo } from "./demo-test";

for (const view of ["Raw dispatch", "Channels"]) {
	test(`${view}: poll leave preserves guide; rejoin creates a fresh room`, async ({ page }) => {
		const root = await openDemo(page, 2);
		await root.getByRole("radio", { name: view, exact: true }).check();
		await expect(root.locator("[data-guide-state]")).toContainText("Deliveries: 1");
		await expect(root.locator("[data-route]")).toContainText(view === "Channels" ? "Join-time matching" : "Join branches");
		await root.getByRole("button", { name: "Vote Gleam" }).click();
		await root.getByRole("button", { name: "Vote Gleam" }).click();
		await root.getByRole("button", { name: "Vote Erlang" }).click();
		await expect(root.locator("[data-totals]")).toHaveText("Gleam 2 / Erlang 1");
		await expect(root.locator("[data-guide-state]")).toContainText("Deliveries: 1");
		await expect(root.locator("[data-output]")).toContainText("Peer broadcast: 0 recipients");
		await root.getByRole("button", { name: "Send guide tip" }).click();
		await expect(root.locator("[data-guide-state]")).toContainText("Deliveries: 2");
		await expect(root.locator("[data-totals]")).toHaveText("Gleam 2 / Erlang 1");
		await expect(root.locator("[data-route]")).toContainText(view === "Channels" ? "on_info" : "Info(GuideReady");
		await root.getByRole("button", { name: "Leave poll" }).click();
		await expect(root.locator("[data-room]")).toHaveText("Room removed. Room members: 0.");
		await expect(root.locator("[data-connection]")).toHaveText("One connection: connected. Topics: guide.");
		await expect(root.locator("[data-route]")).toContainText(view === "Channels" ? "on_terminate" : "Closed");
		await expect(root.getByRole("button", { name: "Vote Gleam" })).toBeDisabled();
		await root.getByRole("button", { name: "Send guide tip" }).click();
		await expect(root.locator("[data-guide-state]")).toContainText("Deliveries: 3");
		await root.getByRole("button", { name: "Rejoin poll" }).click();
		await expect(root.locator("[data-totals]")).toHaveText("Gleam 0 / Erlang 0");
		await expect(root.locator("[data-guide-state]")).toContainText("Deliveries: 3");
		await root.getByRole("button", { name: "Reset", exact: true }).click();
		await expect(root.locator("[data-guide-state]")).toContainText("Deliveries: 1");
		await expect(root.locator("[data-room]")).toHaveText("poll:demo: open. Room members: 1.");
	});
}

test("switching views only changes routing and output explanations", async ({ page }) => {
	const root = await openDemo(page, 2);
	await root.getByRole("button", { name: "Vote Gleam" }).click();
	const originalReply = await root.locator("[data-poll-receipt]").innerText();
	await root.getByRole("radio", { name: "Channels", exact: true }).check();
	await expect(root.locator("[data-poll-receipt]")).toHaveText(originalReply);
	await expect(root.locator("[data-model]")).toContainText('state String = "demo"; info PollInfo = ClosePoll');
	await expect(root.locator("[data-model]")).toContainText("state Int = 1; info GuideInfo = Ready(String)");
	await expect(root.locator("[data-route]")).toContainText("No handler rematch");
	await expect(root.locator("[data-output]")).toContainText('broadcast_from("poll_state"');
	await root.getByRole("radio", { name: "Raw dispatch", exact: true }).check();
	await expect(root.locator("[data-output]")).toContainText('BroadcastFrom("poll:demo"');
	await root.getByRole("button", { name: "Leave poll" }).click();
	await root.getByRole("radio", { name: "Channels", exact: true }).check();
	await expect(root.locator("[data-model]")).toContainText("poll:demo: no instance");
	await expect(root.locator("[data-guide-state]")).toContainText("Deliveries: 1");
	await expect(root.locator("[data-room]")).toHaveText("Room removed. Room members: 0.");
});
