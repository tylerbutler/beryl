import { execFileSync } from "node:child_process";
import { globSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../", import.meta.url));
const HEX_RATE_LIMIT = /rate limit .* exceeded|too many requests/i;
const RETRY_DELAYS_MS = [10_000, 30_000, 60_000];

function sleep(milliseconds) {
	Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

export function retryHexRateLimits(operation, retryDelays = RETRY_DELAYS_MS) {
	for (let attempt = 0; ; attempt++) {
		try {
			return operation();
		} catch (error) {
			const output = `${error?.stdout ?? ""}\n${error?.stderr ?? ""}\n${error}`;
			const delay = retryDelays[attempt];
			if (!HEX_RATE_LIMIT.test(output) || delay === undefined) throw error;
			console.error(
				`Hex API rate limit exceeded; retrying in ${delay / 1000} seconds.`,
			);
			sleep(delay);
		}
	}
}

function downloadDependencies(directory) {
	retryHexRateLimits(() => {
		try {
			const output = execFileSync("gleam", ["deps", "download"], {
				cwd: directory,
				encoding: "utf8",
			});
			process.stdout.write(output);
		} catch (error) {
			if (error?.stdout) process.stdout.write(error.stdout);
			if (error?.stderr) process.stderr.write(error.stderr);
			throw error;
		}
	});
}

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
		downloadDependencies(directory);
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
