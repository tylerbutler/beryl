import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
	plugins: [
		cloudflareTest({
			wrangler: { configPath: "./wrangler.jsonc" },
			miniflare: { bindings: { JOIN_TOKEN: "test-only-credential" } },
		}),
	],
	test: {
		include: ["test/**/*.test.mjs"],
	},
});
