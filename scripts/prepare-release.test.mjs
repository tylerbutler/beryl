import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import {
	mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const script = fileURLToPath(new URL("./prepare-release.mjs", import.meta.url));
const reference = "refs/heads/release/pending";
const docs = "website/src/content/docs/reference/api/index.md";
const lock = "scripts/fixtures/heirloom_namespace/manifest.toml";
const trellis = execFileSync("mise", ["which", "trellis"], { encoding: "utf8" }).trim();
const realGit = execFileSync("which", ["git"], { encoding: "utf8" }).trim();

async function fixture(t, options = {}) {
	const root = mkdtempSync(path.join(tmpdir(), "beryl-release-test-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const remote = path.join(root, "origin.git");
	const cwd = path.join(root, "work");
	const bin = path.join(root, "bin");
	mkdirSync(cwd);
	mkdirSync(bin);
	symlinkSync(trellis, path.join(bin, "trellis"));
	const env = {
		...process.env,
		GIT_CONFIG_GLOBAL: "/dev/null",
		GIT_CONFIG_NOSYSTEM: "1",
		GIT_CONFIG_COUNT: "0",
		GITHUB_TOKEN: "test",
		GH_TOKEN: "test",
		TRELLIS_GITHUB_REPO: "fixture/release",
		TRELLIS_NO_UPDATE_CHECK: "1",
		PATH: `${bin}${path.delimiter}${process.env.PATH}`,
	};
	const git = (...args) => execFileSync("git", args, { cwd, env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
	const write = (file, content) => {
		mkdirSync(path.dirname(path.join(cwd, file)), { recursive: true });
		writeFileSync(path.join(cwd, file), content);
	};
	git("init", "--bare", remote);
	git("init", "-b", "main");
	git("config", "user.name", "Release test");
	git("config", "user.email", "release@example.invalid");
	git("config", "commit.gpgsign", "false");
	git("remote", "add", "origin", remote);
	write("gleam.toml", `[tools.trellis]
members = ["packages/*"]
[tools.trellis.release]
resume = true
auto_pre = true
skip_unchanged = true
[tools.trellis.publish.lifecycle]
default = "git_only"
`);
	write("packages/sample/gleam.toml", 'name = "sample"\nversion = "0.1.0"\n');
	write("packages/sample/src/source.txt", "release input\n");
	write(".changes/unreleased/sample.toml", 'package = "sample"\nkind = "Fixed"\nbody = "Fix sample."\n');
	write(docs, "sample 0.1.0\n");
	write(lock, "sample 0.1.0\n");
	write(".gitignore", "calls\n");
	write("scripts/prepare-release.mjs", readFileSync(script));
	git("add", ".");
	git("commit", "-m", "initial");
	git("push", "origin", "main");
	let pr = null;
	const requests = [];
	let laggedHead = null;
	let conflictCount = 0;
	let nativeConflict = false;
	const remoteHead = () => git("ls-remote", "origin", reference).split("\t")[0] || null;
	const prData = (head = remoteHead()) => ({
		number: 1,
		state: "open",
		merged_at: null,
		html_url: "https://github.com/fixture/release/pull/1",
		head: { ref: "release/pending", sha: head, repo: { full_name: "fixture/release" } },
		base: { ref: "main", repo: { full_name: "fixture/release" } },
	});
	const server = createServer(async (req, res) => {
		let body = "";
		for await (const chunk of req) body += chunk;
		requests.push({ method: req.method, url: req.url, body, repair: Boolean(req.headers["x-release-repair"]) });
		res.setHeader("Content-Type", "application/json");
		if (options.apiError) {
			res.writeHead(500).end('{"message":"unrelated API failure"}');
		} else if (req.method === "GET" && req.url.includes("?")) {
			res.end(JSON.stringify(pr ? [prData()] : []));
		} else if (req.method === "GET") {
			if (options.nativeConflict && !nativeConflict && !req.headers["x-release-repair"]) {
				nativeConflict = true;
				git("clone", "--quiet", "--branch", "release/pending", remote, path.join(root, "peer"));
				writeFileSync(path.join(root, "peer", "concurrent.txt"), "preserve this edit\n");
				git("-C", path.join(root, "peer"), "add", ".");
				git("-C", path.join(root, "peer"), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "concurrent edit");
				git("-C", path.join(root, "peer"), "push", "origin", "HEAD:release/pending");
			}
			const head = remoteHead();
			if (options.lagAfterPush && laggedHead && laggedHead !== head && conflictCount++ === 0) {
				res.end(JSON.stringify(prData(laggedHead)));
			} else {
				laggedHead = head;
				const data = prData();
				if (req.headers["x-release-repair"]) {
					if (options.closed) data.state = "closed";
					if (options.retargeted) data.base.ref = "other";
					if (options.staleRepair) data.head.sha = git("rev-parse", "main");
				}
				res.end(JSON.stringify(data));
			}
		} else if (req.method === "POST") {
			pr = prData();
			laggedHead = remoteHead();
			res.writeHead(201).end(JSON.stringify(pr));
		} else if (options.apiErrorOnUpdate) {
			res.writeHead(500).end('{"message":"PR metadata update failed"}');
		} else {
			pr = prData();
			res.end(JSON.stringify(pr));
		}
	});
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	t.after(() => server.close());
	env.TRELLIS_GITHUB_API_URL = `http://127.0.0.1:${server.address().port}`;
	writeFileSync(path.join(bin, "gh"), `#!${process.execPath}
const args = process.argv.slice(2);
if (args[0] === "repo") console.log("fixture/release");
else {
  fetch(process.env.TRELLIS_GITHUB_API_URL + "/" + args[1], {headers: {"X-Release-Repair": "true"}}).then(async response => {
    if (!response.ok) throw new Error(await response.text());
    console.log(await response.text());
  }).catch(error => { console.error(error.message); process.exitCode = 1; });
}
`, { mode: 0o755 });
	writeFileSync(path.join(bin, "just"), `#!${process.execPath}
const fs = require("node:fs");
const { execFileSync } = require("node:child_process");
const command = process.argv[2];
fs.appendFileSync("calls", command + "\\n");
const version = fs.readFileSync("packages/sample/gleam.toml", "utf8").match(/version = "([^"]+)"/)[1];
if (command === "namespace-test") fs.writeFileSync(${JSON.stringify(lock)}, "sample " + version + "\\n");
else if (command === "site-reference") {
  ${options.generationError ? 'console.error("reference generation failed"); process.exit(1);' : ""}
  fs.writeFileSync(${JSON.stringify(docs)}, "sample " + version + "\\n");
  ${options.unexpectedFile ? 'fs.writeFileSync("unexpected", "do not publish");' : ""}
  ${options.onGenerate ?? ""}
} else throw new Error("unexpected command " + command);
`, { mode: 0o755 });
	if (options.pushRace) {
		writeFileSync(path.join(bin, "git"), `#!${process.execPath}
const fs = require("node:fs");
const { execFileSync, spawnSync } = require("node:child_process");
const git = ${JSON.stringify(realGit)};
const args = process.argv.slice(2);
if (args[0] === "push" && args[1].startsWith("--force-with-lease=") && !fs.existsSync("../push-race")) {
  fs.writeFileSync("../push-race", args[1]);
  execFileSync(git, ["clone", "--quiet", "--branch", "release/pending", "../origin.git", "../peer"]);
  fs.writeFileSync("../peer/concurrent.txt", "preserve this edit\\n");
  execFileSync(git, ["-C", "../peer", "add", "."]);
  execFileSync(git, ["-C", "../peer", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "concurrent edit"]);
  execFileSync(git, ["-C", "../peer", "push", "origin", "HEAD:release/pending"]);
}
const result = spawnSync(git, args, {stdio:"inherit"});
if (result.error) throw result.error;
process.exit(result.status ?? 1);
`, { mode: 0o755 });
	}
	const run = (args = []) => new Promise((resolve, reject) => {
		const child = spawn(process.execPath, [path.join(cwd, "scripts/prepare-release.mjs"), ...args], { cwd, env });
		let stdout = "";
		let stderr = "";
		child.stdout.on("data", (chunk) => { stdout += chunk; });
		child.stderr.on("data", (chunk) => { stderr += chunk; });
		child.on("error", reject);
		child.on("close", (status) => resolve({ status, stdout, stderr }));
	});
	const partial = () => {
		git("checkout", "--detach", "main");
		write("packages/sample/gleam.toml", 'name = "sample"\nversion = "0.1.1"\n');
		write("packages/sample/CHANGELOG.md", "## v0.1.1\n\n### Fixed\n\n- Fix sample.\n");
		git("rm", ".changes/unreleased/sample.toml");
		git("rm", "scripts/prepare-release.mjs");
		git("add", ".");
		git("commit", "-m", "old partial preparation");
		git("push", "origin", `HEAD:${reference}`);
		pr = prData();
		laggedHead = remoteHead();
		git("checkout", "main");
		return remoteHead();
	};
	const output = (file) => {
		const head = remoteHead();
		git("fetch", "--no-tags", "origin", head);
		return git("show", `${head}:${file}`);
	};
	return { root, remote, git, write, run, partial, output, remoteHead, requests };
}

test("the first native Trellis push includes refreshed docs and fixture lock; rerun is a no-op", async (t) => {
	const f = await fixture(t);
	const result = await f.run();
	assert.equal(result.status, 0, result.stderr);
	assert.equal(f.output(docs), "sample 0.1.1");
	assert.equal(f.output(lock), "sample 0.1.1");
	assert.equal(f.git("rev-list", "--count", `main..${f.remoteHead()}`), "1");
	assert.equal(f.git("log", "-1", "--format=%s", f.remoteHead()), "release: sample v0.1.1");
	const head = f.remoteHead();
	const again = await f.run();
	assert.equal(again.status, 0, again.stderr);
	assert.match(again.stdout, /unchanged/);
	assert.equal(f.remoteHead(), head);
	assert.equal(f.git("branch", "--show-current"), "main");
});

test("generation failure prevents the first release push and PR creation", async (t) => {
	const f = await fixture(t, { generationError: true });
	const result = await f.run();
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /reference generation failed/);
	assert.equal(f.remoteHead(), null);
	assert.equal(f.requests.filter((r) => r.method !== "GET").length, 0);
});

test("unchanged native preparation repairs an old partial release without a second version bump", async (t) => {
	const f = await fixture(t);
	const before = f.partial();
	const result = await f.run();
	assert.equal(result.status, 0, result.stderr);
	assert.match(result.stdout, /unchanged/);
	assert.equal(f.output(docs), "sample 0.1.1");
	assert.equal(f.output(lock), "sample 0.1.1");
	assert.equal(f.git("rev-parse", `${f.remoteHead()}^`), before);
});

test("failed recovery leaves the previously partial remote unchanged", async (t) => {
	const f = await fixture(t, { generationError: true });
	const before = f.partial();
	const result = await f.run();
	assert.notEqual(result.status, 0);
	assert.equal(f.remoteHead(), before);
	assert.equal(f.output(docs), "sample 0.1.0");
});

test("a stale API response after the native push re-reads current state and recovers", async (t) => {
	const f = await fixture(t, { lagAfterPush: true });
	f.partial();
	f.write("packages/sample/src/source.txt", "updated release input\n");
	f.git("add", ".");
	f.git("commit", "-m", "new input");
	const result = await f.run();
	assert.equal(result.status, 0, result.stderr);
	assert.match(result.stderr, /re-reading release state/);
	assert.match(result.stderr, /no-op retry does not finalize PR metadata/);
	assert.equal(f.output(docs), "sample 0.1.1");
	assert.equal(f.output(lock), "sample 0.1.1");
});

test("recovery preserves a concurrent edit and retries from the new remote head", async (t) => {
	const f = await fixture(t, {
		onGenerate: `
  if (!fs.existsSync("../concurrent")) {
    fs.writeFileSync("../concurrent", "once");
    execFileSync("git", ["clone", "--quiet", "--branch", "release/pending", "../origin.git", "../peer"]);
    fs.writeFileSync("../peer/concurrent.txt", "preserve this edit\\n");
    execFileSync("git", ["-C", "../peer", "add", "."]);
    execFileSync("git", ["-C", "../peer", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "concurrent edit"]);
    execFileSync("git", ["-C", "../peer", "push", "origin", "HEAD:release/pending"]);
  }
`,
	});
	const partial = f.partial();
	const result = await f.run();
	assert.equal(result.status, 0, result.stderr);
	assert.match(result.stderr, /re-reading release state/);
	assert.equal(f.git("log", "-1", "--format=%s", `${f.remoteHead()}^`), "concurrent edit");
	assert.equal(f.git("rev-parse", `${f.remoteHead()}^^`), partial);
	assert.equal(f.output(docs), "sample 0.1.1");
	assert.equal(f.output("concurrent.txt"), "preserve this edit");
});

test("native preparation stops rather than retrying over a distinct concurrent edit", async (t) => {
	const f = await fixture(t, { nativeConflict: true });
	f.partial();
	f.write("packages/sample/src/source.txt", "updated release input\n");
	f.git("add", ".");
	f.git("commit", "-m", "new input");
	const result = await f.run();
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /Concurrent release edit preserved/);
	assert.doesNotMatch(result.stderr, /re-reading release state/);
	assert.equal(f.output("concurrent.txt"), "preserve this edit");
	assert.equal(f.git("log", "-1", "--format=%s", f.remoteHead()), "concurrent edit");
});

test("the repair push lease rejects a last-moment edit and retries from its new head", async (t) => {
	const f = await fixture(t, { pushRace: true });
	const before = f.partial();
	const result = await f.run();
	assert.equal(result.status, 0, result.stderr);
	assert.match(result.stderr, /changed before the repair push/);
	assert.equal(readFileSync(path.join(f.root, "push-race"), "utf8"), `--force-with-lease=${reference}:${before}`);
	assert.equal(f.output("concurrent.txt"), "preserve this edit");
	assert.equal(f.output(docs), "sample 0.1.1");
	assert.equal(f.output(lock), "sample 0.1.1");
	assert.equal(f.git("rev-parse", `${f.remoteHead()}^^`), before);
});

for (const state of ["closed", "retargeted"]) {
	test(`recovery refuses a PR that was ${state}`, async (t) => {
		const f = await fixture(t, { [state]: true });
		const before = f.partial();
		const result = await f.run();
		assert.notEqual(result.status, 0);
		assert.match(result.stderr, /closed, merged, retargeted/);
		assert.equal(f.remoteHead(), before);
		assert.doesNotMatch(result.stderr, /re-reading release state/);
	});
}

test("persistent API/branch disagreement stops after three reads without publishing a repair", async (t) => {
	const f = await fixture(t, { staleRepair: true });
	const before = f.partial();
	const result = await f.run();
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /have not converged/);
	assert.equal(f.requests.filter((r) => r.repair).length, 6);
	assert.equal(f.remoteHead(), before);
	assert.equal(f.output(docs), "sample 0.1.0");
});

test("unrelated API errors remain failures without retries or a release push", async (t) => {
	const f = await fixture(t, { apiError: true });
	const result = await f.run();
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /unrelated API failure/);
	assert.doesNotMatch(result.stderr, /re-reading release state/);
	assert.equal(f.remoteHead(), null);
	assert.equal(f.requests.length, 1);
});

test("unrelated PR metadata failures remain visible after a fully generated push", async (t) => {
	const f = await fixture(t, { apiErrorOnUpdate: true });
	f.partial();
	f.write("packages/sample/src/source.txt", "updated release input\n");
	f.git("add", ".");
	f.git("commit", "-m", "new input");
	const result = await f.run();
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /PR metadata update failed/);
	assert.doesNotMatch(result.stderr, /re-reading release state/);
	assert.equal(f.output(docs), "sample 0.1.1");
	assert.equal(f.output(lock), "sample 0.1.1");
});

test("unexpected generated paths stop the release push", async (t) => {
	const f = await fixture(t, { unexpectedFile: true });
	const result = await f.run();
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /outside the release outputs/);
	assert.equal(f.remoteHead(), null);
});

test("no release inputs and no pending PR makes no changes", async (t) => {
	const f = await fixture(t);
	f.git("rm", ".changes/unreleased/sample.toml");
	f.git("commit", "-m", "remove input");
	const result = await f.run();
	assert.equal(result.status, 0, result.stderr);
	assert.match(result.stdout, /no_changes/);
	assert.equal(f.remoteHead(), null);
	assert.equal(f.git("status", "--porcelain"), "");
});
