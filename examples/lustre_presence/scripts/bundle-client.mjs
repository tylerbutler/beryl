import { build } from "esbuild";
import { mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { builtEntrypoint } from "../../scripts/built-entrypoint.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const exampleRoot = resolve(here, "..");
const packageName = "lustre_presence_client";
const entry = await builtEntrypoint(exampleRoot, packageName);
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
