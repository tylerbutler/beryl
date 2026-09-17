import { defineConfig } from "@playwright/test";

export default defineConfig({
	testDir: "./e2e",
	timeout: 30_000,
	retries: 0,
	use: {
		baseURL: "http://127.0.0.1:4329",
		browserName: "chromium",
	},
	webServer: {
		command: "node node_modules/astro/bin/astro.mjs preview --host 127.0.0.1 --port 4329",
		url: "http://127.0.0.1:4329/tutorial/",
		reuseExistingServer: false,
	},
});
