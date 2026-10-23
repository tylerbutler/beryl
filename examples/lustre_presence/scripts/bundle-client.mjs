import { build } from "esbuild";
import { mkdir, stat } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const exampleRoot = resolve(here, "..");
const packageName = "lustre_presence_client";
const profile = process.env.GLEAM_BUILD_PROFILE ?? process.env.GLEAM_ENV;
const profiles = profile ? [profile] : ["dev", "prod"];

async function builtEntrypoint() {
  const entries = [];

  for (const buildProfile of profiles) {
    const entry = resolve(
      exampleRoot,
      "client/build",
      buildProfile,
      "javascript",
      packageName,
      `${packageName}.mjs`,
    );

    try {
      entries.push({ entry, modifiedAt: (await stat(entry)).mtimeMs });
    } catch {
      // Try the next build profile.
    }
  }

  if (entries.length === 0) {
    throw new Error(
      `Could not find built ${packageName} entrypoint. Run gleam build in client first.`,
    );
  }

  entries.sort((first, second) => second.modifiedAt - first.modifiedAt);
  return entries[0].entry;
}

const entry = await builtEntrypoint();
const outfile = resolve(
  exampleRoot,
  "priv/static/lustre_presence_client.js",
);

await mkdir(dirname(outfile), { recursive: true });
await build({
  entryPoints: [entry],
  outfile,
  bundle: true,
  format: "esm",
  minify: true,
  platform: "browser",
});
