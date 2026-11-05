import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
	chmodSync,
	lstatSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	readlinkSync,
	realpathSync,
	rmSync,
	symlinkSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const archiveScript = fileURLToPath(
	new URL("./archive-gleam-deps.sh", import.meta.url),
);

test("artifacts restore prepared dependencies without the Actions cache", (t) => {
	const directory = mkdtempSync(path.join(tmpdir(), "beryl-deps-artifact-"));
	t.after(() => rmSync(directory, { recursive: true, force: true }));
	const workspace = path.join(directory, "workspace");
	const home = path.join(directory, "home");
	const artifacts = path.join(directory, "artifacts");
	const restored = path.join(directory, "restored");
	const restoredHex = path.join(directory, "restored-hex");
	for (const folder of [workspace, artifacts, restored, restoredHex]) {
		mkdirSync(folder, { recursive: true });
	}
	const files = {
		"packages/core/build/packages/tool/bin/tool": "#!/bin/sh\nexit 0\n",
		"packages/core/build/packages/local.config_fingerprint": "fingerprint",
		"examples/app/build/packages/packages.toml": "prepared app",
		"examples/app/client/build/packages/packages.toml": "prepared client",
		"build/snippet-check/manifest.toml": "snippet lock",
		"build/snippet-check/build/packages/packages.toml": "prepared snippets",
	};
	for (const [file, content] of Object.entries(files)) {
		const target = path.join(workspace, file);
		mkdirSync(path.dirname(target), { recursive: true });
		writeFileSync(target, content);
	}
	const executable = "packages/core/build/packages/tool/bin/tool";
	chmodSync(path.join(workspace, executable), 0o755);
	const link = "examples/app/build/packages/core";
	symlinkSync("../../../../packages/core", path.join(workspace, link));
	const hex = path.join(home, ".cache/gleam/hex/hexpm/packages");
	mkdirSync(hex, { recursive: true });
	writeFileSync(path.join(hex, "dependency.tar"), "downloaded Hex package");

	execFileSync("bash", [archiveScript, artifacts], {
		cwd: workspace,
		env: { ...process.env, HOME: home },
	});
	// A later job has only the artifacts, with no producer workspace or cache.
	rmSync(workspace, { recursive: true });
	rmSync(home, { recursive: true });
	execFileSync("tar", [
		"-xzf", path.join(artifacts, "gleam-dependencies.tar.gz"), "-C", restored,
	]);
	execFileSync("tar", [
		"-xzf", path.join(artifacts, "gleam-hex-cache.tar.gz"), "-C", restoredHex,
	]);
	for (const [file, content] of Object.entries(files)) {
		assert.equal(readFileSync(path.join(restored, file), "utf8"), content);
	}
	assert.equal(lstatSync(path.join(restored, executable)).mode & 0o777, 0o755);
	assert.equal(
		readlinkSync(path.join(restored, link)),
		"../../../../packages/core",
	);
	assert.equal(
		realpathSync(path.join(restored, link)),
		realpathSync(path.join(restored, "packages/core")),
	);
	assert.equal(
		readFileSync(path.join(restoredHex, "packages/dependency.tar"), "utf8"),
		"downloaded Hex package",
	);
});
