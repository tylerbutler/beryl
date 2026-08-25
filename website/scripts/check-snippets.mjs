// Type-checks the Gleam snippets in the docs against the real packages.
//
// Sources: the hand-written pages under website/src/content/docs (the
// generated reference/api pages are skipped — they hold signature fragments,
// not code) and the ```gleam blocks inside `///` doc comments in
// packages/*/src.
//
// Every snippet on one page shares that page's scope, the way a reader reads
// it: imports are merged, top-level items are hoisted, and loose statements
// are concatenated into a single function. Names the prose never defines
// (`groups`, `socket`, a handler from an earlier section) are bound to `todo`,
// which unifies with any type, so a fragment stays a fragment. What is left is
// a real defect: a module, function, constructor, or field that does not
// exist, a wrong arity, or a type error.
//
// Put `<!-- snippet-check: skip -->` on the line before a fence to exclude a
// block that is deliberately invalid or references a fictional module.
//
// Usage: node scripts/check-snippets.mjs [--keep]

import { execFile } from "node:child_process";
import { mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const websiteRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(websiteRoot, "..");
const docsRoot = path.join(websiteRoot, "src", "content", "docs");
const packagesRoot = path.join(repoRoot, "packages");
const workDir = path.join(repoRoot, "build", "snippet-check");

// Generated from package-interface.json; holds signatures, not runnable code.
const SKIPPED_DOC_DIRS = new Set(["api"]);
const SKIP_MARKER = "snippet-check: skip";
// Snippets that stop the whole module from compiling teach nothing about the
// rest of the page, so the fixpoint loop needs a ceiling on its retries.
const MAX_PLACEHOLDER_ROUNDS = 12;

const GLEAM_TOML = `name = "snippet_check"
version = "1.0.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_erlang = ">= 1.0.0 and < 2.0.0"
gleam_otp = ">= 1.0.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
gleam_crypto = ">= 1.4.0 and < 2.0.0"
gleam_http = ">= 4.0.0 and < 5.0.0"
mist = ">= 6.0.0 and < 7.0.0"
beryl = { path = "../../packages/beryl" }
beryl_mist = { path = "../../packages/beryl_mist" }
beryl_ewe = { path = "../../packages/beryl_ewe" }
`;

// ---------------------------------------------------------------- extraction

async function walk(dir, skipDirs = new Set()) {
	const found = [];
	for (const entry of await readdir(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (skipDirs.has(entry.name)) continue;
			found.push(...(await walk(full, skipDirs)));
		} else {
			found.push(full);
		}
	}
	return found;
}

// Returns [{ line, code }] for every ```gleam fence, where `line` is the
// 1-based line of the fence itself in `text`.
function fencedGleamBlocks(text) {
	const lines = text.split("\n");
	const blocks = [];
	let open = null;
	for (const [index, line] of lines.entries()) {
		if (open === null) {
			if (/^\s*```gleam\s*$/.test(line)) {
				const previous = lines[index - 1] ?? "";
				if (previous.includes(SKIP_MARKER)) {
					open = { skip: true };
					continue;
				}
				open = { line: index + 1, body: [] };
			}
			continue;
		}
		if (/^\s*```\s*$/.test(line)) {
			if (!open.skip) blocks.push({ line: open.line, code: open.body.join("\n") });
			open = null;
			continue;
		}
		if (!open.skip) open.body.push(line);
	}
	return blocks;
}

// Pulls the fenced blocks out of `///` doc comments, mapping each back to its
// line in the .gleam file.
function docCommentBlocks(text) {
	const lines = text.split("\n");
	const stripped = lines.map((line) => {
		const match = /^\s*\/\/\/ ?(.*)$/.exec(line);
		return match === null ? null : match[1];
	});
	const blocks = [];
	let open = null;
	for (const [index, line] of stripped.entries()) {
		if (line === null) {
			open = null;
			continue;
		}
		if (open === null) {
			if (/^\s*```gleam\s*$/.test(line)) open = { line: index + 1, body: [] };
			continue;
		}
		if (/^\s*```\s*$/.test(line)) {
			blocks.push({ line: open.line, code: open.body.join("\n") });
			open = null;
			continue;
		}
		open.body.push(line);
	}
	return blocks;
}

// Every public name each beryl module exports, so a doc-comment example that
// calls its own module's functions unqualified — the way those examples are
// written — resolves instead of silently becoming a placeholder.
async function publicNames() {
	const byModule = new Map();
	const packageDirs = (await readdir(packagesRoot, { withFileTypes: true }))
		.filter((entry) => entry.isDirectory())
		.map((entry) => entry.name);
	for (const name of packageDirs) {
		const file = path.join(
			packagesRoot,
			name,
			"build/dev/docs",
			name,
			"package-interface.json",
		);
		let json;
		try {
			json = JSON.parse(await readFile(file, "utf8"));
		} catch {
			throw new Error(
				`Missing ${path.relative(repoRoot, file)}. Run \`trellis run docs\` first.`,
			);
		}
		for (const [module, contents] of Object.entries(json.modules)) {
			const names = [
				...Object.keys(contents.functions ?? {}),
				...Object.keys(contents.constants ?? {}),
				...Object.keys(contents["type-aliases"] ?? {}).map((t) => `type ${t}`),
				...Object.keys(contents.types ?? {}).map((t) => `type ${t}`),
				...Object.values(contents.types ?? {}).flatMap((type) =>
					(type.constructors ?? []).map((constructor) => constructor.name),
				),
			];
			byModule.set(module, names);
		}
	}
	return byModule;
}

// packages/beryl/src/beryl/topic.gleam -> beryl/topic
function gleamModuleName(file) {
	const match = /packages\/[^/]+\/src\/(.+)\.gleam$/.exec(file);
	return match === null ? null : match[1];
}

async function collectSources() {
	const sources = [];

	const docFiles = (await walk(docsRoot, SKIPPED_DOC_DIRS))
		.filter((file) => /\.mdx?$/.test(file))
		.sort();
	for (const file of docFiles) {
		const blocks = fencedGleamBlocks(await readFile(file, "utf8"));
		if (blocks.length > 0) sources.push({ file, blocks });
	}

	const packageDirs = (await readdir(packagesRoot, { withFileTypes: true }))
		.filter((entry) => entry.isDirectory())
		.map((entry) => path.join(packagesRoot, entry.name, "src"));
	for (const dir of packageDirs) {
		const gleamFiles = (await walk(dir, new Set(["build"])))
			.filter((file) => file.endsWith(".gleam"))
			.sort();
		for (const file of gleamFiles) {
			const blocks = docCommentBlocks(await readFile(file, "utf8"));
			if (blocks.length > 0) sources.push({ file, blocks, ownModule: true });
		}
	}

	return sources;
}

// ------------------------------------------------------------------ assembly

// Blanks out string literals and trailing comments so brackets and arrows
// inside them are not read as code.
function stripNoise(line) {
	return line.replace(/"(?:\\.|[^"\\])*"/g, '""').replace(/\/\/.*$/, "");
}

// Net bracket nesting a line adds.
function bracketDelta(line) {
	const code = stripNoise(line);
	let delta = 0;
	for (const character of code) {
		if ("({[".includes(character)) delta += 1;
		else if (")}]".includes(character)) delta -= 1;
	}
	return delta;
}

// Splits a snippet into top-level chunks. A chunk starts at a column-0
// non-blank line and runs until the next one, so a multi-line function or
// pipeline stays whole. A run of column-0 comments belongs to whatever it
// documents, so it joins the next chunk instead of forming its own.
function topLevelChunks(code, startLine) {
	const lines = code.split("\n");
	const chunks = [];
	let current = null;
	let depth = 0;
	for (const [index, line] of lines.entries()) {
		// A closing brace in column 0, or a wrapped argument list, still
		// belongs to the construct that opened it.
		const isTopLevel = depth === 0 && line.length > 0 && !/^\s/.test(line);
		depth += bracketDelta(line);
		if (isTopLevel) {
			const isComment = line.startsWith("//");
			if (current !== null && !(current.commentOnly && isComment)) {
				chunks.push(current);
				current = null;
			}
			if (current === null) {
				current = { line: startLine + index + 1, body: [], commentOnly: true };
			}
			current.body.push(line);
			if (!isComment) current.commentOnly = false;
		} else if (current !== null) {
			current.body.push(line);
			// A blank line ends a comment run that documents nothing.
			if (current.commentOnly && line.trim() === "") {
				chunks.push(current);
				current = null;
			}
		}
		// Leading indented lines with no owner are a fragment of a larger
		// construct the page shows elsewhere; there is nothing to check.
	}
	if (current !== null) chunks.push(current);
	return chunks
		.map((chunk) => ({
			line: chunk.line,
			text: chunk.body.join("\n").replace(/\s+$/, ""),
			// `///` only attaches to a definition; loose in a body it is a
			// syntax error, so demote it when the chunk holds no definition.
			commentOnly: chunk.commentOnly,
		}))
		.filter((chunk) => chunk.text.length > 0)
		.map((chunk) =>
			chunk.commentOnly
				? { ...chunk, text: chunk.text.replace(/^\/\/\//gm, "//") }
				: chunk,
		);
}

const IMPORT = /^import\s+([\w/]+)(?:\.\{([^}]*)\})?(?:\s+as\s+(\S+))?/;
const MODULE_ITEM = /^(@|pub\s+(fn|type|const|opaque)\b|fn\b|type\b|const\b)/;

function mergeImports(imports) {
	const merged = new Map();
	for (const { module, items, alias } of imports) {
		const entry = merged.get(module) ?? { items: new Set(), alias: null };
		for (const item of items) entry.items.add(item);
		if (alias !== null) entry.alias = alias;
		merged.set(module, entry);
	}
	return [...merged.entries()].map(([module, { items, alias }]) => {
		const unqualified = items.size > 0 ? `.{${[...items].join(", ")}}` : "";
		return `import ${module}${unqualified}${alias === null ? "" : ` as ${alias}`}`;
	});
}

const DEFINITION = /^(?:pub\s+)?(?:opaque\s+)?(type|fn|const)\s+(\w+)/m;

// The `type`, `fn`, or `const` a top-level chunk defines, keyed so two
// definitions of the same name in different kinds do not collide.
function definitionName(text) {
	const match = DEFINITION.exec(text);
	return match === null ? null : `${match[1]} ${match[2]}`;
}

// The variant names a `type X { ... }` chunk introduces. Two types on one
// page may not share a variant name any more than they may share a type name.
function constructorNames(text) {
	if (!/^(?:pub\s+)?(?:opaque\s+)?type\b/m.test(text)) return [];
	return [...text.matchAll(/^\s\s([A-Z]\w*)\s*[({]?/gm)].map((m) => m[1]);
}

const STATEMENT_START = /^(let|case|use|assert|todo|panic|echo|\/\/)\b/;

// True when a chunk reads as a `case` clause rather than a statement: the
// first line is a pattern followed by `->` at bracket depth zero.
function isCaseClause(text) {
	const first = stripNoise(text.split("\n")[0]);
	if (STATEMENT_START.test(first.trim())) return false;
	let depth = 0;
	for (let index = 0; index < first.length - 1; index++) {
		const character = first[index];
		if ("({[".includes(character)) depth += 1;
		else if (")}]".includes(character)) depth -= 1;
		else if (depth === 0 && character === "-" && first[index + 1] === ">") {
			return true;
		}
	}
	return false;
}

// Builds one Gleam module per source file. `map` lets a compiler diagnostic on
// a generated line be reported against the original doc line.
function assembleModule(source, placeholders, exports, extraImports = new Map()) {
	const imports = [];
	for (const [module, { alias, items }] of extraImports) {
		imports.push({
			module,
			items: [...items],
			// Only alias when the fragment's short name differs from the path.
			alias: alias === module.split("/").at(-1) ? null : alias,
		});
	}
	const sections = [];
	let statements = [];

	if (source.ownModule) {
		const module = gleamModuleName(source.file);
		const available = exports.get(module) ?? [];
		const text = source.blocks.map((block) => block.code).join("\n");
		// Only what the examples mention, so an unqualified import cannot
		// collide with a name the example imports from somewhere else.
		const used = available.filter((name) =>
			new RegExp(`\\b${name.replace(/^type /, "")}\\b`).test(text),
		);
		if (used.length > 0) imports.push({ module, items: used, alias: null });
	}

	// A page that defines the same name twice is showing two examples, or one
	// example evolving. Either way the second definition opens a new section,
	// which inherits the definitions before it but not their statements.
	const defined = new Map();
	let anonymous = 0;
	const flush = () => {
		if (defined.size === 0 && statements.length === 0) return;
		sections.push({ items: [...new Set(defined.values())], statements });
		statements = [];
	};

	for (const block of source.blocks) {
		for (const chunk of topLevelChunks(block.code, block.line)) {
			const importMatch = IMPORT.exec(chunk.text);
			if (importMatch !== null) {
				const [, module, unqualified, alias] = importMatch;
				imports.push({
					module,
					items: (unqualified ?? "")
						.split(",")
						.map((item) => item.trim())
						.filter((item) => item.length > 0),
					alias: alias ?? null,
				});
				continue;
			}
			if (!MODULE_ITEM.test(chunk.text)) {
				statements.push(chunk);
				continue;
			}
			const name = definitionName(chunk.text) ?? `anonymous ${anonymous++}`;
			const names = [name, ...constructorNames(chunk.text)];
			const superseded = names
				.map((each) => defined.get(each))
				.filter((each) => each !== undefined);
			if (superseded.length > 0) {
				flush();
				// The replaced definition leaves the new section entirely,
				// including the other names it introduced.
				for (const [key, value] of defined) {
					if (superseded.includes(value)) defined.delete(key);
				}
			}
			for (const each of names) defined.set(each, chunk);
		}
	}
	flush();

	const importLines = mergeImports(imports);
	return sections.map((section, index) =>
		emitSection(section, importLines, placeholders, index),
	);
}

function emitSection(section, importLines, placeholders, index) {
	const out = [];
	const map = new Map();
	const push = (text, line = null) => {
		for (const [offset, piece] of text.split("\n").entries()) {
			out.push(piece);
			if (line !== null) map.set(out.length, line + offset);
		}
	};

	push("@target(erlang)");
	for (const line of importLines) push(line);
	push("");
	for (const item of section.items) {
		push(item.text, item.line);
		push("");
	}
	push("pub fn snippets_() {");
	for (const name of placeholders) push(`  let ${name} = todo`);
	for (const statement of section.statements) {
		// A bare `Pattern -> expression` is a clause lifted out of a `case` the
		// prose shows around it. Give it a subject so it can be checked.
		const clause = isCaseClause(statement.text);
		if (clause) push("  case todo {");
		// A snippet that opens with `|>` is one step of a pipeline the prose
		// shows around it. Give it something to pipe from.
		if (statement.text.startsWith("|>")) push("  todo");
		push(
			statement.text
				.split("\n")
				.map((line) => `  ${clause ? "  " : ""}${line}`)
				.join("\n"),
			statement.line,
		);
		if (clause) {
			// The prose shows one clause of a larger `case`; the rest of the
			// subject's shape is not this snippet's business.
			push("    _ -> todo");
			push("  }");
		}
	}
	// `use <- f(...)` makes the rest of the body a continuation whose type
	// the call dictates, so the block cannot end in a fixed value.
	push("  todo");
	push("}");

	return { text: `${out.join("\n")}\n`, map, suffix: `_s${index}` };
}

function moduleName(file) {
	return path
		.relative(repoRoot, file)
		.replace(/\.(mdx?|gleam)$/, "")
		.replace(/[^a-zA-Z0-9]+/g, "_")
		.toLowerCase();
}

// ------------------------------------------------------------------ checking

// Parses `gleam build` output into { title, file, line, detail }.
function parseDiagnostics(output) {
	const diagnostics = [];
	const lines = output.split("\n");
	for (const [index, line] of lines.entries()) {
		const header = /^error: (.+)$/.exec(line);
		if (header === null) continue;
		const location = /┌─ (.+?):(\d+):(\d+)/.exec(lines[index + 1] ?? "");
		const detail = lines
			.slice(index + 2, index + 12)
			.filter((text) => /^[A-Z]/.test(text.trim()) && text.trim().length > 0)
			.slice(0, 1)
			.join(" ")
			.trim();
		diagnostics.push({
			title: header[1],
			file: location === null ? null : location[1],
			line: location === null ? null : Number(location[2]),
			detail,
		});
	}
	return diagnostics;
}

const UNKNOWN_VARIABLE = /The name `([^`]+)` is not in scope here/;
const UNKNOWN_MODULE = /No module has been found with the name `([^`]+)`/;
const UNKNOWN_TYPE = /The type `([^`]+)` is not defined or imported/;
const UNKNOWN_CONSTRUCTOR =
	/The custom type variant constructor `([^`]+)` is not in scope/;

// Modules a fragment names without showing its import. Anything here is real,
// so the call through it is still checked; the two transport aliases are the
// names the docs consistently give beryl_mist and beryl_ewe.
const EXTRA_MODULES = new Map([
	["io", "gleam/io"],
	["int", "gleam/int"],
	["float", "gleam/float"],
	["set", "gleam/set"],
	["dict", "gleam/dict"],
	["bool", "gleam/bool"],
	["actor", "gleam/otp/actor"],
	["supervision", "gleam/otp/supervision"],
	["dynamic", "gleam/dynamic"],
	["presence_wire", "beryl/presence/wire"],
	["mist_transport", "beryl_mist"],
	["ewe_transport", "beryl_ewe"],
]);

// Types and constructors the snippets use bare without ever showing the
// import. Only what the corpus actually needs — the compiler names anything
// missing from this list, it does not fail silently.
const STDLIB = new Map([
	["Pid", "gleam/erlang/process"],
	["Subject", "gleam/erlang/process"],
	["Selector", "gleam/erlang/process"],
	["Name", "gleam/erlang/process"],
	["Dynamic", "gleam/dynamic"],
	["Decoder", "gleam/dynamic/decode"],
	["Option", "gleam/option"],
	["Some", "gleam/option"],
	["None", "gleam/option"],
	["Dict", "gleam/dict"],
	["Set", "gleam/set"],
	["Json", "gleam/json"],
]);

// What a qualified name or bare type in a fragment most likely refers to.
// Built from the imports the corpus itself writes — a page that shows
// `import gleam/json` teaches every fragment on every page what `json` is —
// plus every type the beryl packages export.
function knownImports(sources, exports) {
	const modules = new Map(EXTRA_MODULES);
	const types = new Map(STDLIB);
	const constructors = new Map(STDLIB);

	const remember = (module, alias, items) => {
		const short = alias ?? module.split("/").at(-1);
		const previous = modules.get(short);
		// Shorter paths win, so `wire` means beryl/wire, not beryl/presence/wire.
		if (previous === undefined || module.length < previous.length) {
			modules.set(short, module);
		}
		for (const item of items) {
			const type = /^type\s+(\w+)$/.exec(item);
			if (type !== null) {
				if (!types.has(type[1])) types.set(type[1], module);
			} else if (/^[A-Z]/.test(item) && !constructors.has(item)) {
				constructors.set(item, module);
			}
		}
	};

	for (const source of sources) {
		for (const block of source.blocks) {
			for (const line of block.code.split("\n")) {
				const match = IMPORT.exec(line);
				if (match === null) continue;
				const [, module, unqualified, alias] = match;
				remember(
					module,
					alias ?? null,
					(unqualified ?? "").split(",").map((item) => item.trim()),
				);
			}
		}
	}

	// Module paths only: a page's `Closed` belongs to the app it describes,
	// not to whichever beryl module happens to export that name.
	for (const module of exports.keys()) {
		remember(module, null, []);
	}

	return { modules, types, constructors };
}

async function build() {
	try {
		const { stdout, stderr } = await execFileAsync("gleam", ["build"], {
			cwd: workDir,
			maxBuffer: 32 * 1024 * 1024,
		});
		return `${stdout}${stderr}`;
	} catch (error) {
		return `${error.stdout ?? ""}${error.stderr ?? ""}`;
	}
}

// Consequences of a fragment being a fragment, not defects in it: a `case`
// that shows one branch, a field read on a value the prose only describes.
const SUPPRESSED = new Set([
	"Inexhaustive patterns",
	"Unknown type for record access",
	// Snippets mix `pub` and private freely because they were never one
	// module; the reader's module decides what it exports.
	"Private type used in public interface",
]);

// A module, type, or constructor from the example application the docs
// describe rather than from beryl or the standard library. Nothing to check —
// but worth listing, since a typo looks exactly the same.
function externalName(diagnostic) {
	// An unknown variable that survived the fixpoint is used from a top-level
	// function, where Gleam has nowhere to bind a placeholder.
	for (const pattern of [
		UNKNOWN_MODULE,
		UNKNOWN_TYPE,
		UNKNOWN_CONSTRUCTOR,
		UNKNOWN_VARIABLE,
	]) {
		const match = pattern.exec(diagnostic.detail);
		if (match !== null) return match[1];
	}
	return null;
}

async function main() {
	const keep = process.argv.includes("--keep");
	const exports = await publicNames();
	const sources = await collectSources();
	const blockCount = sources.reduce((total, s) => total + s.blocks.length, 0);
	console.log(
		`Checking ${blockCount} Gleam snippets from ${sources.length} files.`,
	);

	await rm(path.join(workDir, "src"), { recursive: true, force: true });
	await mkdir(path.join(workDir, "src"), { recursive: true });
	await writeFile(path.join(workDir, "gleam.toml"), GLEAM_TOML);

	const known = knownImports(sources, exports);
	const modules = sources.map((source) => ({
		source,
		name: moduleName(source.file),
		placeholders: new Set(),
		extraImports: new Map(),
	}));

	let diagnostics = [];
	for (let round = 0; round < MAX_PLACEHOLDER_ROUNDS; round++) {
		const byPath = new Map();
		for (const module of modules) {
			const sections = assembleModule(
				module.source,
				module.placeholders,
				exports,
				module.extraImports,
			);
			for (const { text, map, suffix } of sections) {
				const file = path.join(
					workDir,
					"src",
					`${module.name}${suffix}.gleam`,
				);
				await writeFile(file, text);
				byPath.set(file, { module, map });
			}
		}

		diagnostics = parseDiagnostics(await build());

		// A fragment leaves out what the surrounding prose already
		// established: the imports, and the values the reader binds. Supply
		// them and re-check, so only real API defects remain.
		let added = false;
		for (const diagnostic of diagnostics) {
			const entry = byPath.get(diagnostic.file);
			if (entry === undefined) continue;
			const { placeholders, extraImports } = entry.module;

			const variable = UNKNOWN_VARIABLE.exec(diagnostic.detail);
			if (variable !== null && !placeholders.has(variable[1])) {
				placeholders.add(variable[1]);
				added = true;
				continue;
			}

			const module = UNKNOWN_MODULE.exec(diagnostic.detail);
			if (module !== null && known.modules.has(module[1])) {
				const target = known.modules.get(module[1]);
				if (!extraImports.has(target)) {
					extraImports.set(target, { alias: module[1], items: new Set() });
					added = true;
				}
				continue;
			}

			const addUnqualified = (module, item) => {
				const existing = extraImports.get(module) ?? {
					alias: null,
					items: new Set(),
				};
				if (existing.items.has(item)) return;
				existing.items.add(item);
				extraImports.set(module, existing);
				added = true;
			};

			const type = UNKNOWN_TYPE.exec(diagnostic.detail);
			if (type !== null && known.types.has(type[1])) {
				addUnqualified(known.types.get(type[1]), `type ${type[1]}`);
				continue;
			}

			const constructor = UNKNOWN_CONSTRUCTOR.exec(diagnostic.detail);
			if (constructor !== null && known.constructors.has(constructor[1])) {
				addUnqualified(known.constructors.get(constructor[1]), constructor[1]);
			}
		}
		if (!added) {
			// Report against the original doc file and line.
			diagnostics = diagnostics.map((diagnostic) => {
				const entry = byPath.get(diagnostic.file);
				if (entry === undefined) return diagnostic;
				return {
					...diagnostic,
					file: path.relative(repoRoot, entry.module.source.file),
					line: entry.map.get(diagnostic.line) ?? null,
					generated: `:`,
				};
			});
			break;
		}
	}

	if (!keep) await rm(path.join(workDir, "src"), { recursive: true, force: true });

	const findings = [];
	const external = new Map();
	// Sections inherit the definitions before them, so one broken definition
	// is reported once per section that carries it.
	const seen = new Set();
	for (const diagnostic of diagnostics) {
		const key = `${diagnostic.file}:${diagnostic.line}:${diagnostic.title}:${diagnostic.detail}`;
		if (seen.has(key)) continue;
		seen.add(key);
		const name = externalName(diagnostic);
		if (name !== null) {
			const at = `${diagnostic.file}:${diagnostic.line ?? "?"}`;
			external.set(name, (external.get(name) ?? new Set()).add(at));
		} else if (!SUPPRESSED.has(diagnostic.title)) {
			findings.push(diagnostic);
		}
	}

	if (external.size > 0) {
		console.log(
			`\n${external.size} names the snippets leave to the reader's own app:`,
		);
		for (const [name, sites] of [...external].sort()) {
			console.log(`  ${name}  (${[...sites][0]}${sites.size > 1 ? ` +${sites.size - 1}` : ""})`);
		}
		console.log("  Check these are meant to be undefined, not typos.");
	}

	if (findings.length === 0) {
		console.log("\nEvery snippet type-checks against the real packages.");
		return;
	}

	console.log("");
	for (const diagnostic of findings) {
		const where =
			diagnostic.file === null
				? "?"
				: `${diagnostic.file}:${diagnostic.line ?? "?"}`;
		console.log(
			`${where}  ${diagnostic.title}${diagnostic.detail ? ` — ${diagnostic.detail}` : ""}`,
		);
	}
	console.log(`\n${findings.length} problems.`);
	process.exitCode = 1;
}

await main();
