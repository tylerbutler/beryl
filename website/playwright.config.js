// @ts-check
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  retries: 0,
  use: {
    baseURL: "http://127.0.0.1:4321",
    headless: true,
  },
  webServer: [
    {
      command: "gleam run",
      cwd: "./demo_server",
      url: "http://127.0.0.1:4100/healthz",
      reuseExistingServer: !process.env.CI,
      timeout: 60_000,
      env: {
        ...process.env,
        PORT: "4100",
        BIND_ADDRESS: "127.0.0.1",
        ALLOWED_ORIGINS: "http://127.0.0.1:4321",
        BERYL_VERSION: "test",
      },
    },
    {
      command:
        "pnpm run build:interactive && pnpm exec astro dev --host 127.0.0.1 --port 4321",
      url: "http://127.0.0.1:4321/examples/",
      reuseExistingServer: !process.env.CI,
      timeout: 60_000,
      env: {
        ...process.env,
        PUBLIC_BERYL_DEMO_URL: "http://127.0.0.1:4100",
      },
    },
  ],
  projects: [
    {
      name: "chromium",
      grepInvert: /static fallback/,
      use: { browserName: "chromium" },
    },
    {
      name: "no-javascript",
      use: { browserName: "chromium", javaScriptEnabled: false },
      grep: /static fallback/,
    },
  ],
});
