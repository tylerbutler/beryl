import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
	assembleModule,
	buildDiagnostics,
	checkSources,
	docCommentBlocks,
	quickStartSource,
} from "./check-snippets.mjs";

const root = new URL("../../", import.meta.url);

async function publishedSources() {
	return Promise.all([
		["README.md", false],
		["packages/beryl/src/beryl.gleam", true],
	].map(async ([name, moduleComment]) => {
		const file = fileURLToPath(new URL(name, root));
		return quickStartSource(file, await readFile(file, "utf8"), moduleComment);
	}));
}

test("quick starts retain their published code and original line mapping", async () => {
	for (const source of await publishedSources()) {
		const [module] = assembleModule(source, new Set(["invented"]), new Map());
		assert.equal(module.text, `${source.blocks[0].code}\n`);
		assert.equal(module.map.get(1), source.blocks[0].line + 1);
		assert.equal(source.strict, true);
		assert.doesNotMatch(module.text, /let invented = todo/);
		assert.match(module.text, /pub fn main/);
	}
});

test("section selection excludes other examples", () => {
	const source = quickStartSource("README.md", [
		"# Example", "```gleam", "not_the_quick_start()", "```",
		"## Quick start", "```gleam", "pub fn main() { Nil }", "```",
		"## Other", "```gleam", "also_not_the_quick_start()", "```",
	].join("\n"));
	assert.equal(source.blocks[0].code, "pub fn main() { Nil }");
	assert.equal(source.blocks[0].line, 6);
});

test("missing, skipped, duplicate, or unclosed quick starts fail", () => {
	for (const text of [
		"# No quick start",
		"## Quick start",
		"## Quick start\n<!-- snippet-check: skip -->\n```gleam\nNil\n```",
		"## Quick start\n```gleam\nNil",
		"## Quick start\n```gleam\nNil\n```\n```gleam\nNil\n```",
		"## Quick start\n```gleam\nNil\n```\n## Quick start",
	]) {
		assert.throws(() => quickStartSource("README.md", text), /expected exactly one/);
	}
});

test("function doc extraction excludes module comments and retains line numbers", () => {
	assert.deepEqual(docCommentBlocks([
		"//// ```gleam", "//// module_example()", "//// ```",
		"/// ```gleam", "/// function_example()", "/// ```",
	].join("\n")), [{ line: 4, code: "function_example()" }]);
});

test("compiler failure without a recognized diagnostic never passes", () => {
	assert.throws(
		() => buildDiagnostics({ success: false, output: "compiler unavailable" }),
		/compiler unavailable/,
	);
	assert.deepEqual(buildDiagnostics({ success: true, output: "" }), []);
});

test("published quick starts compile, and regressions fail strictly", async (t) => {
	const sources = await publishedSources();
	assert.equal(await checkSources(sources), 0);

	const failures = [
		["README conversion Result passed as Json", 0, (code) =>
			code.replace(
				"channel.broadcast(message.event, payload)",
				"channel.broadcast(message.event, wire.dynamic_to_json(message.payload))",
			)],
		["core Dynamic passed as Json", 1, (code) =>
			code.replace("Ok(payload) -> {", "Ok(_converted) -> {")],
		["core main must return Nil after handling broadcast admission", 1, (code) =>
			code.replace("\n  Nil\n}", "\n}")],
		["unknown name cannot become a placeholder", 0, (code) =>
			code.replace("context.topic", "missing_room")],
		["missing import cannot be inferred", 0, (code) =>
			code.replace("import gleam/json\n", "")],
		["inexhaustive complete example cannot be suppressed", 0, (code) =>
			code.replace(
				/channel\.reply_error\(message\.reply, json\.string\("Invalid JSON payload"\)\)/,
				'case message.reply { option.None -> channel.discard_reply(message.reply) }',
			).replace("import gleam/json", "import gleam/option")],
	];
	for (const [name, sourceIndex, mutate] of failures) {
		await t.test(name, async () => {
			const source = sources[sourceIndex];
			const original = source.blocks[0];
			const code = mutate(original.code);
			assert.notEqual(code, original.code, "mutation must change the published snippet");
			const changed = { ...source, blocks: [{ ...original, code }] };
			assert.equal(await checkSources([changed]), 1);
		});
	}
	assert.equal(await checkSources(sources), 0);
});
