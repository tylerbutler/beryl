// @ts-check
import { defineConfig } from "@playwright/test";

// The showcase runs on its own port so it can execute alongside the other
// examples' suites (and any local service already holding :8000).
const PORT = 8010;

export default defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  retries: 0,
  use: {
    baseURL: `http://localhost:${PORT}`,
    headless: true,
  },
  // Start the Gleam server before tests
  webServer: {
    command: "gleam run",
    url: `http://localhost:${PORT}`,
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
    env: { PORT: `${PORT}` },
  },
  projects: [
    {
      name: "chromium",
      use: { browserName: "chromium" },
    },
  ],
});
