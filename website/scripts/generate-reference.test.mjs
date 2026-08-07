import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { generateReference } from "./generate-reference.mjs";

const websiteRoot = path.resolve(
	path.dirname(fileURLToPath(import.meta.url)),
	"..",
);

function scratchPrefix(name = "beryl-ref-") {
	return path.join(websiteRoot, `.${name}`);
}

const fixture = {
	name: "beryl",
	version: "9.9.9",
	modules: {
		"beryl/channel": {
			documentation: [
				"Channel behaviour and callbacks.",
				"",
				"See [`HandleResult`](#HandleResult) and [`beryl`](./beryl.html#Config).",
			],
			types: {
				HandleResult: {
					documentation: "Result of handling an inbound message.",
					parameters: 1,
					constructors: [
						{
							name: "Reply",
							documentation: "Reply to the sender.",
							parameters: [{ label: "payload", type: { kind: "variable", id: 0 } }],
						},
						{ name: "NoReply", parameters: [] },
					],
				},
				LegacyThing: {
					documentation: "An old type.",
					parameters: 0,
					constructors: [],
					deprecation: { message: "Use HandleResult instead." },
				},
			},
			"type-aliases": {
				Assigns: {
					documentation: "Convenience alias for socket assigns.",
					parameters: 0,
					alias: {
						kind: "named",
						name: "Dict",
						module: "gleam/dict",
						parameters: [
							{ kind: "named", name: "String", module: "gleam" },
							{ kind: "variable", id: 0 },
						],
					},
				},
			},
			constants: {
				default_timeout: {
					documentation: "Default reply timeout.",
					type: { kind: "named", name: "Int", module: "gleam" },
				},
			},
			functions: {
				handle: {
					documentation: "Handle an inbound message.",
					parameters: [
						{ label: "message", type: { kind: "named", name: "String", module: "gleam" } },
						{
							label: "coords",
							type: {
								kind: "tuple",
								elements: [
									{ kind: "named", name: "Int", module: "gleam" },
									{ kind: "named", name: "Int", module: "gleam" },
								],
							},
						},
						{
							label: "callback",
							type: {
								kind: "fn",
								parameters: [{ kind: "named", name: "String", module: "gleam" }],
								return: { kind: "named", name: "Nil", module: "gleam" },
							},
						},
					],
					return: {
						kind: "named",
						name: "HandleResult",
						module: "beryl/channel",
						parameters: [{ kind: "variable", id: 0 }],
					},
				},
			},
		},
		beryl: {
			documentation: "Top-level API.",
			types: {},
			"type-aliases": {},
			constants: {},
			functions: {},
		},
	},
};

async function withFixture(run) {
	const dir = await mkdtemp(scratchPrefix());
	try {
		const jsonPath = path.join(dir, "package-interface.json");
		const outputDir = path.join(dir, "out");
		await writeFile(jsonPath, JSON.stringify(fixture));
		await run({ jsonPath, outputDir });
	} finally {
		await rm(dir, { force: true, recursive: true });
	}
}

test("generates an index and one page per module", async () => {
	await withFixture(async ({ jsonPath, outputDir }) => {
		const result = await generateReference({ docsJsonPath: jsonPath, outputDir });
		assert.equal(result.moduleCount, 2);
		assert.equal(result.pageCount, 3);

		const index = await readFile(path.join(outputDir, "index.md"), "utf8");
		assert.match(index, /title: API Reference/);
		assert.match(index, /`beryl` `9\.9\.9`/);
		// Modules are sorted alphabetically: beryl before beryl/channel.
		assert.ok(index.indexOf("/reference/api/beryl/") < index.indexOf("/reference/api/beryl-channel/"));
	});
});

test("renders types, aliases, constants, and functions", async () => {
	await withFixture(async ({ jsonPath, outputDir }) => {
		await generateReference({ docsJsonPath: jsonPath, outputDir });
		const page = await readFile(path.join(outputDir, "beryl-channel.md"), "utf8");

		// Module doc array is normalized to multi-line text.
		assert.match(page, /Channel behaviour and callbacks\./);
		assert.match(page, /\[`HandleResult`\]\(#handleresult\)/);
		assert.match(page, /\[`beryl`\]\(\/reference\/api\/beryl\/#config\)/);

		// Type with parameters and documented constructors.
		assert.match(page, /pub type HandleResult\(a\)/);
		assert.match(page, /Reply\(payload: a\)/);
		assert.match(page, /NoReply/);

		// Type alias with a foreign type uses last module segment, drops prelude qualifier.
		assert.match(page, /pub type Assigns = dict\.Dict\(String, a\)/);

		// Constant.
		assert.match(page, /pub const default_timeout: Int/);

		// Function signature: tuple, fn type, current-module return without qualifier.
		assert.match(page, /pub fn handle\(/);
		assert.match(page, /coords: #\(Int, Int\)/);
		assert.match(page, /callback: fn\(String\) -> Nil/);
		assert.match(page, /-> HandleResult\(a\)/);
	});
});

test("marks every generated page as generated", async () => {
	await withFixture(async ({ jsonPath, outputDir }) => {
		await generateReference({ docsJsonPath: jsonPath, outputDir });
		// The marker must survive in the served page, so it goes in an HTML
		// comment below the frontmatter rather than in the frontmatter itself.
		for (const name of ["index.md", "beryl.md", "beryl-channel.md"]) {
			const page = await readFile(path.join(outputDir, name), "utf8");
			assert.match(
				page,
				/<!--\s*Generated by website\/scripts\/generate-reference\.mjs\. Do not edit\./,
				`${name} is missing the generated-file marker`,
			);
			// Marker sits after the frontmatter block, not inside it.
			assert.ok(
				page.indexOf("<!--") > page.lastIndexOf("---\n"),
				`${name} marker must follow the frontmatter`,
			);
		}
	});
});

test("surfaces deprecations as a caution block", async () => {
	await withFixture(async ({ jsonPath, outputDir }) => {
		await generateReference({ docsJsonPath: jsonPath, outputDir });
		const page = await readFile(path.join(outputDir, "beryl-channel.md"), "utf8");
		assert.match(page, /:::caution\[Deprecated\]\nUse HandleResult instead\.\n:::/);
	});
});

test("quotes frontmatter so prose punctuation cannot break the YAML", async () => {
	const dir = await mkdtemp(scratchPrefix());
	try {
		const jsonPath = path.join(dir, "package-interface.json");
		const outputDir = path.join(dir, "out");
		await writeFile(
			jsonPath,
			JSON.stringify({
				name: "beryl_channels",
				version: "0.0.1",
				modules: {
					"beryl_channels/channel": {
						// A colon in the first line is bare-YAML poison, and a pipe
						// would split the module table row on the index page.
						documentation: [
							'The channel surface: a "pattern" | a callback.',
							"",
							"More prose.",
						],
						types: {},
						"type-aliases": {},
						constants: {},
						functions: {},
					},
				},
			}),
		);
		await generateReference({ docsJsonPath: jsonPath, outputDir });

		const page = await readFile(
			path.join(outputDir, "beryl_channels-channel.md"),
			"utf8",
		);
		const frontmatter = page.split("---")[1];
		assert.match(frontmatter, /title: "beryl_channels\/channel"/);
		assert.match(
			frontmatter,
			/description: "The channel surface: a \\"pattern\\" \| a callback\."/,
		);
		// Every frontmatter value is a quoted scalar, so no bare `:` or `#`
		// can be reinterpreted as YAML structure.
		for (const line of frontmatter.trim().split("\n")) {
			assert.match(line, /^[a-z]+: ".*"$/);
		}

		const index = await readFile(path.join(outputDir, "index.md"), "utf8");
		const row = index
			.split("\n")
			.find((line) => line.includes("/reference/api/beryl_channels-channel/"));
		// Escaped pipe keeps the row at exactly two cells.
		assert.equal(row.split(/(?<!\\)\|/).length - 2, 2);
	} finally {
		await rm(dir, { force: true, recursive: true });
	}
});

test("merges multiple packages into one grouped reference", async () => {
	const dir = await mkdtemp(scratchPrefix("beryl-ref-multi-"));
	try {
		const corePath = path.join(dir, "beryl.json");
		const transportPath = path.join(dir, "beryl_mist.json");
		const outputDir = path.join(dir, "out");
		await writeFile(corePath, JSON.stringify(fixture));
		await writeFile(
			transportPath,
			JSON.stringify({
				name: "beryl_mist",
				version: "1.2.3",
				modules: {
					beryl_mist: {
						documentation: "Mist WebSocket transport.",
						types: {},
						"type-aliases": {},
						constants: {},
						functions: {},
					},
				},
			}),
		);
		const result = await generateReference({
			docsJsonPaths: [transportPath, corePath],
			outputDir,
		});
		assert.equal(result.moduleCount, 3);

		const index = await readFile(path.join(outputDir, "index.md"), "utf8");
		// Packages are grouped and sorted by name regardless of input order.
		assert.match(index, /## `beryl` `9\.9\.9`/);
		assert.match(index, /## `beryl_mist` `1\.2\.3`/);
		assert.ok(index.indexOf("## `beryl`") < index.indexOf("## `beryl_mist`"));
		// beryl is not on Hex, so the index must not link out to hexdocs
		// (it may still mention hexdocs.pm to explain the absence).
		assert.doesNotMatch(index, /https:\/\/hexdocs\.pm/);
		assert.match(index, /canonical API reference/);
		// Package names read as prose: "`beryl` and `beryl_mist`".
		assert.match(index, /for `beryl` and `beryl_mist`\./);

		const page = await readFile(path.join(outputDir, "beryl_mist.md"), "utf8");
		assert.match(page, /Mist WebSocket transport\./);
	} finally {
		await rm(dir, { force: true, recursive: true });
	}
});

test("rejects module slug collisions across packages", async () => {
	await withFixture(async ({ jsonPath, outputDir }) => {
		await assert.rejects(
			generateReference({ docsJsonPaths: [jsonPath, jsonPath], outputDir }),
			/collision/,
		);
	});
});

test("reports a helpful error when the docs JSON is missing", async () => {
	await withFixture(async ({ outputDir }) => {
		await assert.rejects(
			generateReference({
				docsJsonPath: path.join(outputDir, "does-not-exist.json"),
				outputDir,
			}),
			/gleam docs build/,
		);
	});
});
