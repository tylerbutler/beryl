import { test, expect, demos } from "./demo-test";

for (const demo of demos) {
	test(`${demo.tag}: keyboard, motion preference, and reattachment`, async ({ page }) => {
		await page.emulateMedia({ reducedMotion: "reduce" });
		await page.goto(`/tutorial/${demo.path}/`);
		const root = page.locator(demo.tag);
		await expect(root).toHaveAttribute("data-ready", "true");
		const button = root.getByRole("button", { name: demo.action, exact: true }).first();
		await button.focus();
		await expect(button).toBeFocused();
		expect(await button.evaluate((node) => getComputedStyle(node).outlineStyle)).not.toBe("none");
		await button.press("Enter");
		expect(await root.evaluate((node) => node.getAnimations({ subtree: true }).length)).toBe(0);
		await expect(root.getByRole("status")).not.toBeEmpty();
		if (demo.tag === "socket-loop-demo") {
			await root.getByRole("button", { name: "Request count" }).click();
			await expect(root.locator("[data-client]")).toHaveText("1");
		}
		await root.evaluate((node) => {
			const parent = node.parentElement;
			if (!parent) throw new Error("Demo has no parent.");
			node.remove();
			parent.append(node);
		});
		await button.click();
		if (demo.tag === "socket-loop-demo") {
			await expect(root.locator("[data-model]")).toHaveText("1");
		} else {
			await expect(root.locator("[data-totals]")).toHaveText("Gleam 1 / Erlang 0");
		}
	});

	for (const theme of ["light", "dark"]) {
		test(`${demo.tag}: ${theme} theme and narrow layouts`, async ({ page }, testInfo) => {
			await page.goto(`/tutorial/${demo.path}/`);
			const root = page.locator(demo.tag);
			await expect(root).toHaveAttribute("data-ready", "true");
			await page.evaluate((theme) => { document.documentElement.dataset["theme"] = theme; }, theme);
			for (const width of [320, 375, 1280]) {
				await page.setViewportSize({ width, height: 900 });
				const sizes = await root.evaluate((node) => ({
					scroll: node.scrollWidth,
					width: node.clientWidth,
					buttons: [...node.querySelectorAll("button, .demo-view")].map((control) => ({
						width: control.getBoundingClientRect().width,
						height: control.getBoundingClientRect().height,
					})),
				}));
				expect(sizes.scroll).toBeLessThanOrEqual(sizes.width + 1);
				for (const control of sizes.buttons) {
					expect(control.height).toBeGreaterThanOrEqual(44);
					expect(control.width).toBeGreaterThanOrEqual(44);
				}
				if (width === 320) await root.screenshot({ path: testInfo.outputPath("mobile.png") });
			}
			if (demo.tag === "topic-composition-demo") {
				await page.setViewportSize({ width: 320, height: 900 });
				await root.getByRole("radio", { name: "Raw dispatch", exact: true }).focus();
				await page.keyboard.press("ArrowRight");
				await expect(root.getByRole("radio", { name: "Channels", exact: true })).toBeChecked();
				await expect(root.locator("[data-model]")).toContainText("Accepted instances");
				expect(await root.evaluate((node) => node.scrollWidth <= node.clientWidth + 1)).toBe(true);
			}
		});
	}

	test(`${demo.tag}: static explanation without JavaScript`, async ({ browser, baseURL }) => {
		if (!baseURL) throw new Error("The demo tests require a local baseURL.");
		const context = await browser.newContext({ javaScriptEnabled: false, baseURL });
		const page = await context.newPage();
		await page.goto(`/tutorial/${demo.path}/`);
		const root = page.locator(demo.tag);
		await expect(root.locator("noscript")).not.toBeEmpty();
		await expect(root.getByRole("button", { name: demo.action, exact: true }).first()).toBeDisabled();
		await expect(root.locator("figcaption")).toBeVisible();
		await context.close();
	});
}
