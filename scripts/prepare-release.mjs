import { spawnSync } from "node:child_process";
import { copyFileSync, lstatSync, mkdtempSync, readFileSync, readlinkSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const generated = [
	"scripts/fixtures/heirloom_namespace/manifest.toml",
	"website/src/content/docs/reference/api",
];

function run(command, args, options = {}) {
	const result = spawnSync(command, args, {
		encoding: "utf8",
		maxBuffer: 16 * 1024 * 1024,
		...options,
	});
	if (result.error) throw result.error;
	if (result.status !== 0) {
		throw new Error(`${command} ${args.join(" ")} failed (${result.status})\n${result.stderr ?? ""}`);
	}
	return result.stdout ?? "";
}

function outsideOutputs() {
	const paths = [".", ...generated.map((file) => `:(exclude)${file}`)];
	const untracked = run("git", ["ls-files", "--others", "--exclude-standard", "-z", "--", ...paths])
		.split("\0").filter(Boolean).map((file) => [
			file,
			lstatSync(file).isSymbolicLink() ? readlinkSync(file) : readFileSync(file).toString("hex"),
		]);
	return JSON.stringify([
		run("git", ["diff", "--binary", "HEAD", "--", ...paths]), untracked,
	]);
}

function refresh() {
	const before = outsideOutputs();
	run("just", ["namespace-test"], { stdio: "inherit" });
	run("just", ["site-reference"], { stdio: "inherit" });
	if (outsideOutputs() !== before) {
		throw new Error("Generation changed files outside the release outputs.");
	}
}

function prepare(args) {
	const directory = mkdtempSync(path.join(tmpdir(), "beryl-release-"));
	const generator = path.join(directory, "prepare-release.mjs");
	try {
		// Pending heads can predate this script; keep the caller's generator available.
		copyFileSync(fileURLToPath(import.meta.url), generator);
		const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`;
		run("trellis", [
			"release", "pr", ...args,
			"--base", "main", "--branch", "release/pending",
			"--prepare-command", `${quote(process.execPath)} ${quote(generator)} --refresh`,
		], { stdio: "inherit" });
	} finally {
		rmSync(directory, { recursive: true, force: true });
	}
}

try {
	if (process.argv[2] === "--refresh") refresh();
	else prepare(process.argv.slice(2));
} catch (error) {
	console.error(error.message);
	process.exitCode = 1;
}
