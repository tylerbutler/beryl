// @ts-check
import { defineConfig } from "@playwright/test";

const port = process.env.PORT ? parseInt(process.env.PORT) : 8000;

export default defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  retries: 0,
  use: {
    baseURL: `http://localhost:${port}`,
    headless: true,
  },
  // Start the Gleam server before tests
  webServer: {
    command: "gleam run",
    url: `http://localhost:${port}`,
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
    env: { PORT: String(port) },
  },
  projects: [
    {
      name: "chromium",
      use: { browserName: "chromium" },
    },
  ],
});
