import { execFileSync } from "node:child_process";
import { globSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../", import.meta.url));

function dependencyState(directory) {
	const files = globSync(["manifest.toml", "build/packages/*.config_fingerprint"], {
		cwd: directory,
	}).sort();
	return JSON.stringify(
		files.map((file) => [file, readFileSync(path.join(directory, file), "utf8")]),
	);
}

// Gleam 1.18.1 refreshes only one changed path fingerprint per invocation.
// Remove this loop once the pinned release includes gleam-lang/gleam#6246.
export function prepareDependencies(directory, pathDependencyCount) {
	let previous = dependencyState(directory);
	// Allow an initial manifest resolution, one pass per path dep, and a stable pass.
	for (let pass = 0; pass < pathDependencyCount + 2; pass++) {
		execFileSync("gleam", ["deps", "download"], {
			cwd: directory,
			stdio: "inherit",
		});
		const current = dependencyState(directory);
		if (current === previous) return;
		previous = current;
	}
	throw new Error(`Dependency state did not stabilize in ${directory}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	const { packages } = JSON.parse(
		execFileSync("trellis", ["list", "--json"], {
			cwd: repoRoot,
			encoding: "utf8",
		}),
	);
	for (const member of packages) {
		console.log(`Preparing dependencies for ${member.name}`);
		prepareDependencies(path.join(repoRoot, member.path), member.dependencies.length);
	}
}
