import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const directory = fileURLToPath(new URL(".", import.meta.url));
const packageDirectory = fileURLToPath(new URL("../../packages/beryl_protocol/", import.meta.url));
const build = path.join(directory, "build");
mkdirSync(build, { recursive: true });

function execute(command, args, cwd = directory) {
	const result = spawnSync(command, args, {
		cwd,
		encoding: "utf8",
		timeout: 120_000,
		maxBuffer: 64 * 1024 * 1024,
	});
	assert.ifError(result.error);
	assert.equal(result.signal, null, `${command} terminated: ${result.signal}`);
	return result;
}

function passed(command, args, cwd) {
	const result = execute(command, args, cwd);
	assert.equal(result.status, 0, result.stdout + result.stderr);
	return result.stdout;
}

test("BendTT checks the laws and rejects broken consumption and drain behavior", () => {
	assert.match(passed("bend", ["PROOF.bend", "--verdict"]), /ALL PROOFS CHECK/);
	const mutations = [
		{
			from: "Output{State{nc, no, phase, NoReply{}}, choose(List<&2, Action>, emit",
			to: "Output{state, choose(List<&2, Action>, emit",
			law: /successful_consume|reply_capabilities_are_single_use/,
		},
		{
			from: "Closing{channel, _, Drain{}, _}",
			to: "Closing{channel, _, Immediate{}, _}",
			law: /invalidated_closing_channels_cannot_push/,
		},
	];
	for (const mutation of mutations) {
		const fixture = mkdtempSync(path.join(build, "broken-model-"));
		try {
			for (const file of ["model.bend", "LAWS.bend", "PROOF.bend"]) {
				copyFileSync(path.join(directory, file), path.join(fixture, file));
			}
			const model = readFileSync(path.join(fixture, "model.bend"), "utf8");
			const broken = model.replace(mutation.from, mutation.to);
			assert.notEqual(broken, model, "mutation must change the model");
			writeFileSync(path.join(fixture, "model.bend"), broken);
			const result = execute("bend", ["PROOF.bend", "--verdict"], fixture);
			assert.notEqual(result.status, 0, "broken behavior must fail the proof gate");
			assert.match(result.stdout + result.stderr, /SOME PROOFS FAIL/);
			assert.match(result.stdout + result.stderr, mutation.law);
		} finally {
			rmSync(fixture, { recursive: true, force: true });
		}
	}
});

function local(number) {
	return { $: "Local", number };
}

function host() {
	return { channels: [], joins: [], admissions: [], replies: [], cleanups: [] };
}

const foreign = {
	channels: [{ $: "Foreign", number: 1 }],
	joins: [{ $: "Foreign", number: 1 }],
	admissions: [{ $: "Foreign", number: 1 }],
	replies: [{ $: "Foreign", number: 2 }],
	cleanups: [{ $: "Foreign", number: 3 }],
};

function pick(handles, slot, command) {
	if (command >= 20) return foreign[slot][0];
	return command >= 12 ? handles[slot].at(-1) : handles[slot][0];
}

function transition(model, state, handles, command) {
	const withHandle = (slot, run) => {
		const handle = pick(handles, slot, command);
		return handle ? run(handle) : model.unchanged(state);
	};
	switch (command) {
		case 0: return model.join(state);
		case 1: case 12: case 20:
			return withHandle("joins", (handle) => model.accept(handle, state, { $: "Immediate" }));
		case 2:
			return withHandle("joins", (handle) => model.accept(handle, state, { $: "Drain" }));
		case 3:
			return withHandle("joins", (handle) => model.reject(handle, state));
		case 4: case 13: case 21:
			return withHandle("admissions", (handle) => model.admit(handle, state));
		case 5: return model.request(state);
		case 6: case 14: case 22:
			return withHandle("replies", (handle) => model.consume(handle, state, true));
		case 7: case 15: case 23:
			return withHandle("replies", (handle) => model.consume(handle, state, false));
		case 8: case 16: case 24:
			return withHandle("channels", (handle) => model.close(handle, state));
		case 9: case 17: case 25:
			return withHandle("channels", (handle) => model.push(handle, state));
		case 10: case 18: case 26:
			return withHandle("cleanups", (handle) => model.drain(handle, state));
		case 11: case 19: case 27:
			return withHandle("cleanups", (handle) => model.cleanup(handle, state));
		default: throw new Error(`unknown pilot command: ${command}`);
	}
}

function actionNames(actions, handles) {
	const names = [];
	let remaining = actions;
	while (remaining.$ === "Con") {
		const action = remaining.head;
		switch (action.$) {
			case "DeliverJoin":
				handles.channels.unshift(local(action.channel));
				handles.joins.unshift(local(action.operation));
				names.push("deliver_join");
				break;
			case "AdmitJoin":
				handles.admissions.unshift(local(action.operation));
				names.push("admit_join");
				break;
			case "DeliverMessage":
				handles.replies.unshift(local(action.operation));
				names.push("deliver_message");
				break;
			case "CloseChannel":
				handles.cleanups.unshift(local(action.operation));
				names.push("close_channel");
				break;
			case "Joined": names.push("joined"); break;
			case "JoinOk": names.push("join_ok"); break;
			case "JoinError": names.push("join_error"); break;
			case "ReplyOk": names.push("reply_ok"); break;
			case "Terminal": names.push("terminal"); break;
			case "Pushed": names.push("pushed"); break;
			case "DuplicateRef": names.push('error:{"reason":"duplicate_ref"}'); break;
			case "UnmatchedTopic": names.push('error:{"reason":"unmatched topic"}'); break;
			default: throw new Error(`unknown model action: ${action.$}`);
		}
		remaining = remaining.tail;
	}
	assert.equal(remaining.$, "Nil");
	return names;
}

function replay(model, trace) {
	let state = model.initial();
	const handles = host();
	return trace.map((command) => {
		const output = transition(model, state, handles, command);
		state = output.state;
		return {
			pending: model.pending_count(state),
			joined: model.joined(state),
			pushable: model.pushable(state),
			actions: actionNames(output.actions, handles),
		};
	});
}

test("Bend agrees with beryl_protocol on Erlang and JavaScript", async (context) => {
	passed("bend", ["model.bend", "-o", "build/model.mjs"]);
	const { default: model } = await import(pathToFileURL(path.join(build, "model.mjs")));
	let firstCorpus;
	for (const target of ["erlang", "javascript"]) {
		await context.test(target, () => {
			const output = passed("gleam", [
				"run", "--target", target, "-m", "beryl_protocol/pilot",
			], packageDirectory);
			const corpus = output.trim().split("\n").map((line) => JSON.parse(line));
			assert.ok(corpus.length > 0, "the host must emit its trace corpus");
			if (firstCorpus) assert.deepEqual(corpus, firstCorpus, "both targets must run the same corpus");
			else firstCorpus = corpus;
			let transitions = 0;
			for (const { trace, observations } of corpus) {
				assert.deepEqual(observations, replay(model, trace), `${target}: trace ${JSON.stringify(trace)}`);
				transitions += trace.length;
			}
			context.diagnostic(`${target}: ${corpus.length} traces, ${transitions} transitions matched`);
		});
	}
});
