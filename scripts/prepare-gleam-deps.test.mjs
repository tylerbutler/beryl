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
import { prepareDependencies } from "./prepare-gleam-deps.mjs";

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
