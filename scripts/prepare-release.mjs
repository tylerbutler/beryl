import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(import.meta.url);
const branch = "release/pending";
const reference = `refs/heads/${branch}`;
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
		const error = new Error(
			`${command} ${args.join(" ")} failed (${result.status})\n${result.stderr ?? ""}`,
		);
		error.status = result.status;
		error.stderr = result.stderr ?? "";
		throw error;
	}
	return result.stdout?.trim() ?? "";
}

const git = (...args) => run("git", args);
const clean = () => git("status", "--porcelain") === "";
const remoteHead = () => git("ls-remote", "--refs", "origin", reference).split("\t")[0];

function refresh() {
	run("just", ["namespace-test"], { stdio: "inherit" });
	run("just", ["site-reference"], { stdio: "inherit" });
	const changed = [
		...git("diff", "--name-only", "-z").split("\0"),
		...git("ls-files", "--others", "--exclude-standard", "-z").split("\0"),
	].filter(Boolean);
	if (changed.some((file) => !generated.some(
		(target) => file === target || file.startsWith(`${target}/`),
	))) {
		throw new Error(`Generation changed files outside the release outputs:\n${changed.join("\n")}`);
	}
	git("add", "--", ...generated);
}

class ConcurrentUpdate extends Error {}

function retryConcurrent(operation) {
	for (let attempt = 1; ; attempt += 1) {
		try {
			return operation();
		} catch (error) {
			if (!(error instanceof ConcurrentUpdate) || attempt === 3 || !clean()) {
				throw error;
			}
			console.error(`${error.message}; re-reading release state (${attempt}/3).`);
			Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, attempt * 1000);
		}
	}
}

function pending(repo, number) {
	const pr = JSON.parse(run("gh", ["api", `repos/${repo}/pulls/${number}`]));
	if (
		pr.number !== number || pr.state !== "open" || pr.merged_at !== null
		|| pr.head?.ref !== branch || pr.base?.ref !== "main"
		|| pr.head?.repo?.full_name?.toLowerCase() !== repo.toLowerCase()
		|| pr.base?.repo?.full_name?.toLowerCase() !== repo.toLowerCase()
		|| !/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(pr.head?.sha ?? "")
	) {
		throw new Error("Release PR was closed, merged, retargeted, or has invalid identity; inspect it before retrying.");
	}
	return pr.head.sha;
}

function verifyHead(repo, number, expected) {
	const head = pending(repo, number);
	const remote = remoteHead();
	if (head !== expected || remote !== expected) {
		throw new ConcurrentUpdate("Release PR and branch head changed or have not converged");
	}
}

function repair(number) {
	const repo = run("gh", ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]);
	retryConcurrent(() => {
		const head = pending(repo, number);
		verifyHead(repo, number, head);
		git("fetch", "--no-tags", "origin", head);
		git("checkout", "--detach", head);
		refresh();
		if (!git("diff", "--cached", "--name-only")) {
			verifyHead(repo, number, head);
			console.log("Release fixture lock and reference docs are up to date.");
			return;
		}
		git("commit", "-m", "chore: refresh fixture lock and API reference for release");
		verifyHead(repo, number, head);
		try {
			// The repair is a child of the verified head; the lease also guards deletion/recreation.
			git("push", `--force-with-lease=${reference}:${head}`, "origin", `HEAD:${reference}`);
		} catch (error) {
			if (error.stderr.includes("(stale info)")) {
				throw new ConcurrentUpdate("Release branch changed before the repair push");
			}
			throw error;
		}
	});
}

function prepare(args) {
	if (!clean()) throw new Error("Release preparation requires a clean working tree.");
	const original = git("rev-parse", "--abbrev-ref", "HEAD") === "HEAD"
		? git("rev-parse", "HEAD")
		: git("symbolic-ref", "--short", "HEAD");
	const count = Number(process.env.GIT_CONFIG_COUNT ?? 0);
	if (!Number.isSafeInteger(count) || count < 0) throw new Error("Invalid GIT_CONFIG_COUNT");
	const hooks = mkdtempSync(path.join(tmpdir(), "beryl-release-hooks-"));
	const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`;
	// shortcut: Trellis 1.4 has no generation hook; replace these hooks when upstream supports one.
	writeFileSync(
		path.join(hooks, "pre-commit"),
		`#!/bin/sh\nexec ${quote(process.execPath)} ${quote(script)} --refresh\n`,
		{ mode: 0o755 },
	);
	const preparedHead = path.join(hooks, "prepared-head");
	writeFileSync(
		path.join(hooks, "post-commit"),
		`#!/bin/sh\ngit rev-parse HEAD > ${quote(preparedHead)}\n`,
		{ mode: 0o755 },
	);
	const env = {
		...process.env,
		GIT_CONFIG_COUNT: String(count + 1),
		[`GIT_CONFIG_KEY_${count}`]: "core.hooksPath",
		[`GIT_CONFIG_VALUE_${count}`]: hooks,
	};
	let pushedBeforeConflict = false;
	try {
		const document = retryConcurrent(() => {
			const before = remoteHead();
			rmSync(preparedHead, { force: true });
			try {
				return JSON.parse(run("trellis", [
					"release", "pr", ...args, "--base", "main", "--branch", branch, "--json",
				], { env }));
			} catch (error) {
				// Trellis 1.4 checks the API head both before and after its leased push.
				if (error.status === 3 && (
					error.stderr.trim().endsWith("error: release PR changed during preparation; retry against its current head")
					|| error.stderr.trim().endsWith("error: release branch differs from the selected PR head; retry")
					|| (error.stderr.includes("failed to push branch release/pending")
						&& error.stderr.includes("(stale info)"))
				)) {
					const after = remoteHead();
					const prepared = existsSync(preparedHead)
						? readFileSync(preparedHead, "utf8").trim() : null;
					if (after !== before && after !== prepared) {
						throw new Error(`${error.message}\nConcurrent release edit preserved; inspect the current head before retrying.`);
					}
					if (after === prepared) pushedBeforeConflict = true;
					throw new ConcurrentUpdate(error.message);
				}
				throw error;
			}
		});
		if (document.schema !== "trellis.release_pr/1"
			|| !["prepared", "unchanged", "no_changes"].includes(document.outcome)
			|| document.base !== "main" || document.branch !== branch) {
			throw new Error("Unexpected Trellis release result");
		}
		// Native no-op detection does not check generated files, including old partial preparations.
		if (document.pr_number !== undefined && document.pr_number !== null) {
			if (!Number.isSafeInteger(document.pr_number) || document.pr_number < 1) {
				throw new Error("Invalid Trellis release PR number");
			}
			repair(document.pr_number);
		} else if (document.outcome === "prepared") {
			throw new Error("Prepared release has no PR number");
		}
		if (pushedBeforeConflict && document.outcome !== "prepared") {
			console.error("Release files are valid, but Trellis's no-op retry does not finalize PR metadata; see tylerbutler/trellis#158.");
		}
		console.log(`Release preparation: ${document.outcome}`);
	} finally {
		rmSync(hooks, { recursive: true, force: true });
		if (clean()) git("checkout", original);
		else console.error("Local preparation changes remain for inspection; no cleanup was attempted.");
	}
}

try {
	if (process.argv[2] === "--refresh") refresh();
	else prepare(process.argv.slice(2));
} catch (error) {
	console.error(error.message);
	process.exitCode = 1;
}
