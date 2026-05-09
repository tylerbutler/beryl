import { build } from "esbuild";
import { mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const exampleRoot = resolve(here, "..");
const entry = resolve(
  exampleRoot,
  "client/build/dev/javascript/collab_docs_client/collab_docs_client.mjs",
);
const outfile = resolve(exampleRoot, "priv/static/collab_docs_client.mjs");

await mkdir(dirname(outfile), { recursive: true });
await build({
  entryPoints: [entry],
  outfile,
  bundle: true,
  format: "esm",
  platform: "browser",
});
