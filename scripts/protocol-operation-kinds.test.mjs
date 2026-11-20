import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../packages/beryl_protocol/", import.meta.url));

for (const target of ["erlang", "javascript"]) {
	test(`operation kinds reject mismatched host inputs on ${target}`, () => {
		mkdirSync(path.join(root, "build"), { recursive: true });
		const fixture = mkdtempSync(path.join(root, "build", "operation-kinds-"));
		try {
			mkdirSync(path.join(fixture, "src"));
			for (const file of [
				"gleam.toml",
				"manifest.toml",
				"src/beryl_protocol.gleam",
			]) {
				copyFileSync(path.join(root, file), path.join(fixture, file));
			}
			const cases = [
				["JoinKind", "ReplyKind", "protocol.Discard(operation)"],
				["ReplyKind", "JoinKind", "protocol.CallbackFinished(operation)"],
				["AdmissionKind", "CleanupKind", "protocol.CleanupFinished(operation)"],
				["CleanupKind", "AdmissionKind", "protocol.AdmissionFinished(operation, True)"],
			];
			for (const [wrong, correct, input] of cases) {
				for (const kind of [correct, wrong]) {
					writeFileSync(
						path.join(fixture, "src/host.gleam"),
						`import beryl_protocol as protocol
pub fn complete(operation: protocol.Operation(protocol.${kind})) -> protocol.Input {
  ${input}
}
`,
					);
					const result = spawnSync(
						"gleam",
						["build", "--target", target, "--warnings-as-errors"],
						{ cwd: fixture, encoding: "utf8" },
					);
					assert.ifError(result.error);
					const output = result.stdout + result.stderr;
					if (kind === correct) {
						assert.equal(result.status, 0, output);
					} else {
						assert.notEqual(result.status, 0, output);
						assert.match(output, /Type mismatch/);
						assert.ok(output.includes(wrong), output);
						assert.ok(output.includes(correct), output);
					}
				}
			}
		} finally {
			rmSync(fixture, { recursive: true, force: true });
		}
	});
}
