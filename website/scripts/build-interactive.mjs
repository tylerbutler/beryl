import { copyFile, mkdir, rm } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const websiteRoot = path.resolve(scriptDir, "..");
const projectRoot = path.join(websiteRoot, "interactive");
const bundle = path.join(projectRoot, "dist", "beryl_site.js");
const outputDir = path.join(websiteRoot, "public", "interactive");
const output = path.join(outputDir, "beryl_site.mjs");

const build = spawnSync(
  "gleam",
  [
    "run",
    "-m",
    "lustre/dev",
    "build",
    "--minify",
    "--no-html",
    "beryl_site",
  ],
  { cwd: projectRoot, stdio: "inherit" },
);

if (build.status !== 0) process.exit(build.status ?? 1);

await rm(outputDir, { force: true, recursive: true });
await mkdir(outputDir, { recursive: true });
await copyFile(bundle, output);
