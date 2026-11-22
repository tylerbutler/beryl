import { stat } from "node:fs/promises";
import { resolve } from "node:path";

export async function builtEntrypoint(root, packageName) {
  const profile = process.env.GLEAM_BUILD_PROFILE ?? process.env.GLEAM_ENV;
  let newest;
  let cause;
  for (const candidate of profile ? [profile] : ["dev", "prod"]) {
    const entry = resolve(
      root, "client/build", candidate, "javascript", packageName, `${packageName}.mjs`,
    );
    try {
      const { mtimeMs } = await stat(entry);
      if (!newest || mtimeMs > newest.mtimeMs) newest = { entry, mtimeMs };
    } catch (error) {
      // A profile can be missing or unreadable while another is usable.
      if (!error.code) throw error;
      cause ??= error;
    }
  }
  if (newest) return newest.entry;
  throw new Error(
    `Could not find built ${packageName} entrypoint. Run gleam build in client first.`,
    { cause },
  );
}
