import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
	cpSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	utimesSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
	prepareDependencies,
	retryHexRateLimits,
	selectDependencyMembers,
} from "./prepare-gleam-deps.mjs";

const members = [
	{ name: "beryl", path: "packages/beryl" },
	{ name: "load_test", path: "examples/load_test" },
	{ name: "beryl_codec_bench", path: "benchmarks/codec" },
];

test("default dependency preparation omits opt-in benchmarks", () => {
	assert.deepEqual(selectDependencyMembers(members), members.slice(0, 2));
});

test("explicit dependency selection can include benchmarks", () => {
	assert.deepEqual(selectDependencyMembers(members, ["beryl_codec_bench"]), [
		members[2],
	]);
});

test("explicit dependency selection preserves workspace order", () => {
	assert.deepEqual(selectDependencyMembers(members, ["load_test", "beryl"]), [
		members[0],
		members[1],
	]);
});

test("unknown dependency selections fail before preparing any package", () => {
	assert.throws(
		() => selectDependencyMembers(members, ["beryl", "missing"]),
		/Unknown workspace package: missing/,
	);
});

test("retries Hex rate limits and fails fast for other errors", () => {
	let attempts = 0;
	const result = retryHexRateLimits(() => {
		attempts += 1;
		if (attempts < 3) {
			const error = new Error("dependency download failed");
			error.stderr = "The rate limit for the Hex API has been exceeded";
			throw error;
		}
		return "downloaded";
	}, [0, 0]);
	assert.equal(result, "downloaded");
	assert.equal(attempts, 3);

	const otherError = new Error("invalid dependency");
	assert.throws(
		() =>
			retryHexRateLimits(() => {
				throw otherError;
			}, [0]),
		(error) => error === otherError,
	);
});

function fakeGleamProject(t, script) {
	const directory = mkdtempSync(path.join(tmpdir(), "beryl-deps-recovery-"));
	const bin = path.join(directory, "bin");
	mkdirSync(bin);
	writeFileSync(
		path.join(bin, "gleam"),
		`#!${process.execPath}
const fs = require("node:fs");
const assert = require("node:assert/strict");
assert.deepEqual(process.argv.slice(2), ["deps", "download"]);
const manifest = fs.existsSync("manifest.toml")
	? fs.readFileSync("manifest.toml", "utf8") : null;
fs.appendFileSync("calls.jsonl", JSON.stringify(manifest) + "\\n");
${script}
`,
		{ mode: 0o755 },
	);
	writeFileSync(path.join(directory, "manifest.toml"), "cached lock");
	const previousPath = process.env.PATH;
	process.env.PATH = `${bin}${path.delimiter}${previousPath}`;
	t.after(() => {
		process.env.PATH = previousPath;
		rmSync(directory, { recursive: true, force: true });
	});
	return directory;
}

for (const diagnostic of [
	"error: incompatible locked version",
	`error: Dependency resolution failed
There's no compatible version of \`ewe\`:
  - You require beryl_ewe 0.2.3
    - beryl_ewe requires ewe >= 9.0.0 and < 10.0.0
  - You require ewe 4.0.1`,
]) {
	test(`recovers cached lock: ${diagnostic.split("\n")[0]}`, (t) => {
		const directory = fakeGleamProject(t, `
if (manifest === "cached lock") {
	console.error(${JSON.stringify(diagnostic)});
	process.exit(1);
}
fs.writeFileSync("manifest.toml", "resolved lock");
`);
		prepareDependencies(directory, 0);
		assert.equal(
			readFileSync(path.join(directory, "manifest.toml"), "utf8"),
			"resolved lock",
		);
		assert.deepEqual(
			readFileSync(path.join(directory, "calls.jsonl"), "utf8")
				.trim().split("\n").map(JSON.parse),
			["cached lock", null, "resolved lock"],
		);
	});
}

test("restores the lock when unlocked dependencies still cannot resolve", (t) => {
	const directory = fakeGleamProject(t, `
console.error("There's no compatible version of \`ewe\`");
process.exit(1);
`);
	assert.throws(() => prepareDependencies(directory, 0), /Command failed/);
	assert.equal(
		readFileSync(path.join(directory, "manifest.toml"), "utf8"),
		"cached lock",
	);
	assert.deepEqual(
		readFileSync(path.join(directory, "calls.jsonl"), "utf8")
			.trim().split("\n").map(JSON.parse),
		["cached lock", null],
	);
});

test("preserves the lock and does not retry unrelated download failures", (t) => {
	const directory = fakeGleamProject(t, `
console.error("Package not found");
process.exit(1);
`);
	assert.throws(() => prepareDependencies(directory, 0), /Command failed/);
	assert.equal(
		readFileSync(path.join(directory, "manifest.toml"), "utf8"),
		"cached lock",
	);
	assert.equal(
		readFileSync(path.join(directory, "calls.jsonl"), "utf8"),
		'"cached lock"\n',
	);
});

test("cold, changed, and restored path dependencies need no further resolution", (t) => {
	const directory = mkdtempSync(path.join(tmpdir(), "beryl-deps-"));
	t.after(() => rmSync(directory, { recursive: true, force: true }));
	for (const name of ["first", "second"]) {
		const dependency = path.join(directory, `${name}_directory`);
		mkdirSync(path.join(dependency, "src"), { recursive: true });
		writeFileSync(
			path.join(dependency, "gleam.toml"),
			`name = "${name}"\nversion = "1.0.0"\n`,
		);
	}
	const project = path.join(directory, "project");
	mkdirSync(path.join(project, "src"), { recursive: true });
	writeFileSync(
		path.join(project, "src", "deps_test.gleam"),
		"pub fn main() -> Nil { Nil }\n",
	);
	writeFileSync(
		path.join(project, "gleam.toml"),
		`name = "deps_test"
version = "1.0.0"
[dependencies]
first = { path = "../first_directory" }
second = { path = "../second_directory" }
`,
	);
	function assertNoResolution(cwd, args) {
		const result = spawnSync("gleam", args, {
			cwd,
			env: { ...process.env, GLEAM_LOG: "debug" },
			encoding: "utf8",
		});
		const output = `${result.stdout}${result.stderr}`;
		assert.equal(result.status, 0, output);
		assert.doesNotMatch(output, /manifest_outdated|Resolving versions/);
	}
	prepareDependencies(project, 2);
	assertNoResolution(project, ["check"]);
	writeFileSync(
		path.join(directory, "first_directory", "gleam.toml"),
		'name = "first"\nversion = "1.0.1"\n',
	);
	prepareDependencies(project, 2);
	assert.match(
		readFileSync(path.join(project, "manifest.toml"), "utf8"),
		/1\.0\.1/,
	);
	assertNoResolution(project, ["check"]);

	const fingerprints = ["first", "second"].map((name) =>
		path.join(project, "build/packages", `${name}.config_fingerprint`),
	);
	const previous = fingerprints.map((file) => readFileSync(file, "utf8"));
	for (const name of ["first", "second"]) {
		writeFileSync(
			path.join(directory, `${name}_directory`, "gleam.toml"),
			`name = "${name}"\nversion = "1.0.0"\ndescription = "Changed config"\n`,
		);
	}
	prepareDependencies(project, 2);
	for (const [index, file] of fingerprints.entries()) {
		assert.notEqual(readFileSync(file, "utf8"), previous[index]);
	}
	assertNoResolution(project, ["check"]);

	const restored = path.join(directory, "restored");
	mkdirSync(restored);
	for (const file of ["gleam.toml", "manifest.toml", "src", "build/packages"]) {
		cpSync(path.join(project, file), path.join(restored, file), {
			recursive: true,
			preserveTimestamps: true,
		});
	}
	// A fresh checkout has newer config mtimes than the restored cache.
	const checkoutTime = new Date(Date.now() + 1000);
	for (const name of ["first", "second"]) {
		utimesSync(
			path.join(directory, `${name}_directory`, "gleam.toml"),
			checkoutTime,
			checkoutTime,
		);
	}
	assertNoResolution(restored, ["build"]);
	assertNoResolution(restored, ["run"]);

	rmSync(path.join(directory, "first_directory"), { recursive: true });
	assert.throws(() => prepareDependencies(project, 2), /Command failed/);
});
