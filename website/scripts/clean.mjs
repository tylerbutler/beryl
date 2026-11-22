import { readdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";

const root = dirname(import.meta.dirname);
for (const name of await readdir(root)) {
	const output = name === "dist" || name === ".astro";
	const buildFile =
		!name.startsWith(".") && (name.endsWith(".tsbuildinfo") || name.endsWith(".done.build.log"));
	if (output || buildFile) {
		await rm(join(root, name), { recursive: true, force: true, maxRetries: 3 });
	}
}
