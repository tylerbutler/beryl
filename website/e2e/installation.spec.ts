import { expect, test } from "@playwright/test";

test("installation pins core and transport to the same minor release", async ({ page, request }) => {
	await page.goto("/installation/");
	const lines = await page.locator('pre[data-language="toml"] .ec-line').allTextContents();
	const dependencies = lines.join("\n");
	const refs = [...dependencies.matchAll(/ref = "(v\d+\.\d+)"/g)].map((match) => match[1]);
	expect(refs).toHaveLength(2);
	expect(refs[0]).toBe(refs[1]);
	expect(dependencies).toContain('path = "packages/beryl"');
	expect(dependencies).toContain('path = "packages/beryl_mist"');

	const llms = await request.get("/llms-full.txt");
	expect(llms.ok()).toBe(true);
	expect(await llms.text()).toContain(dependencies);
});
