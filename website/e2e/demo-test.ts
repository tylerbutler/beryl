import { test as base, expect, type Locator, type Page } from "@playwright/test";

export const test = base.extend<{ localPage: void }>({
	localPage: [async ({ page, baseURL }, use) => {
		const errors: string[] = [];
		page.on("pageerror", (error) => errors.push(error.message));
		await page.route("**/*", (route) => {
			return new URL(route.request().url()).origin === baseURL
				? route.continue() : route.abort();
		});
		await use();
		expect(errors).toEqual([]);
	}, { auto: true }],
});
export { expect };

export const demos = [
	{ tag: "socket-loop-demo", path: "the-elm-architecture-without-a-dom", action: "Increment model" },
	{ tag: "shared-poll-demo", path: "one-update-function-many-socket-events", action: "Vote Gleam" },
	{ tag: "topic-composition-demo", path: "composition-raw-dispatch-and-channels", action: "Vote Gleam" },
] as const;

export async function openDemo(page: Page, index: 0 | 1 | 2) {
	const demo = demos[index];
	await page.goto(`/tutorial/${demo.path}/`);
	const root = page.locator(demo.tag);
	await expect(root).toHaveAttribute("data-ready", "true");
	return root;
}

export async function pauseNextMotion(root: Locator) {
	await root.evaluate((element) => {
		element.addEventListener("click", () => {
			for (const animation of element.getAnimations({ subtree: true })) animation.pause();
		}, { once: true });
	});
}

export async function finishMotion(root: Locator) {
	await root.evaluate((element) => {
		for (const animation of element.getAnimations({ subtree: true })) animation.finish();
	});
}
