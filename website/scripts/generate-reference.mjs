// Generates Markdown reference pages from Gleam's package-interface.json.
//
// Discovers every workspace package under packages/*, reads each package's
// build/dev/docs/<package-name>/package-interface.json (produced by
// `gleam docs build`, e.g. via `trellis run docs`), and writes one Markdown
// page per public module into website/src/content/docs/reference/api. The
// hand-written reference index at website/src/content/docs/reference/index.md
// is intentionally left untouched.

import { mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const websiteRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(websiteRoot, "..");
const defaultOutputDir = path.join(
	websiteRoot,
	"src",
	"content",
	"docs",
	"reference",
	"api",
);
// URL base path the generated pages are served from. Must match defaultOutputDir
// relative to website/src/content/docs.
const referenceBasePath = "/reference/api";

export async function generateReference({
	docsJsonPath,
	docsJsonPaths,
	outputDir = defaultOutputDir,
} = {}) {
	const jsonPaths =
		docsJsonPaths ??
		(docsJsonPath ? [docsJsonPath] : await discoverPackageInterfaces());
	const packages = [];
	for (const jsonPath of jsonPaths) {
		packages.push(await readPackageInterface(jsonPath));
	}
	packages.sort((left, right) => left.name.localeCompare(right.name));

	const pages = new Map();
	for (const packageInterface of packages) {
		const modules = Object.entries(packageInterface.modules).sort(
			([left], [right]) => left.localeCompare(right),
		);
		for (const [moduleName, moduleInterface] of modules) {
			const slug = moduleSlug(moduleName);
			if (pages.has(slug)) {
				throw new Error(
					`Module page collision: two packages both provide \`${moduleName}\``,
				);
			}
			pages.set(slug, renderModulePage(moduleName, moduleInterface));
		}
	}

	await rm(outputDir, { force: true, recursive: true });
	await mkdir(outputDir, { recursive: true });
	await writeFile(path.join(outputDir, "index.md"), renderIndex(packages));
	for (const [slug, content] of pages) {
		await writeFile(path.join(outputDir, `${slug}.md`), content);
	}

	return { pageCount: pages.size + 1, moduleCount: pages.size };
}

// Find every workspace package's package-interface.json under packages/*.
async function discoverPackageInterfaces() {
	const packagesDir = path.join(repoRoot, "packages");
	const entries = await readdir(packagesDir, { withFileTypes: true });
	const jsonPaths = [];
	for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
		if (!entry.isDirectory()) {
			continue;
		}
		const packageDir = path.join(packagesDir, entry.name);
		const name = await readPackageName(path.join(packageDir, "gleam.toml"));
		jsonPaths.push(
			path.join(
				packageDir,
				"build",
				"dev",
				"docs",
				name,
				"package-interface.json",
			),
		);
	}
	if (jsonPaths.length === 0) {
		throw new Error(`No packages found under ${path.relative(repoRoot, packagesDir)}`);
	}
	return jsonPaths;
}

async function readPackageName(gleamTomlPath) {
	const gleamToml = await readFile(gleamTomlPath, "utf8");
	const match = gleamToml.match(/^name\s*=\s*"([^"]+)"/m);
	if (!match) {
		throw new Error(
			`Missing package name in ${path.relative(repoRoot, gleamTomlPath)}`,
		);
	}
	return match[1];
}

async function readPackageInterface(docsJsonPath) {
	let raw;
	try {
		raw = await readFile(docsJsonPath, "utf8");
	} catch (error) {
		if (error && error.code === "ENOENT") {
			throw new Error(
				`Missing ${path.relative(repoRoot, docsJsonPath)}. Run \`gleam docs build\` in each package (e.g. \`just gleam-docs\`) first.`,
			);
		}
		throw error;
	}

	const parsed = JSON.parse(raw);
	if (
		!parsed ||
		typeof parsed.name !== "string" ||
		typeof parsed.modules !== "object"
	) {
		throw new Error(
			`Invalid Gleam package interface JSON at ${path.relative(repoRoot, docsJsonPath)}`,
		);
	}

	return parsed;
}

function moduleSlug(moduleName) {
	return moduleName.replaceAll("/", "-");
}

function descriptionFromDocs(documentation, fallback) {
	const text = normalizeDoc(documentation);
	const firstLine = text.split("\n").find((line) => line.trim().length > 0);
	return firstLine ? firstLine.replaceAll('"', '\\"') : fallback;
}

function normalizeDoc(documentation) {
	if (Array.isArray(documentation)) {
		return documentation.map((line) => line.trimEnd()).join("\n").trim();
	}
	if (typeof documentation === "string") {
		return documentation.trim();
	}
	return "";
}

function code(value) {
	return `\`${String(value).replaceAll("`", "\\`")}\``;
}

function variableSymbol(id) {
	return String.fromCharCode("a".charCodeAt(0) + (Number.isInteger(id) ? id : 0));
}

function renderTypeParameters(count) {
	if (!Number.isInteger(count) || count <= 0) {
		return "";
	}
	return `(${Array.from({ length: count }, (_, i) => variableSymbol(i)).join(", ")})`;
}

function renderType(type, currentModule) {
	if (!type || typeof type !== "object") {
		return "Unknown";
	}

	switch (type.kind) {
		case "named": {
			let qualifier = "";
			if (type.module && type.module !== "gleam" && type.module !== currentModule) {
				const segments = type.module.split("/");
				qualifier = `${segments[segments.length - 1]}.`;
			}
			const parameters =
				Array.isArray(type.parameters) && type.parameters.length > 0
					? `(${type.parameters.map((t) => renderType(t, currentModule)).join(", ")})`
					: "";
			return `${qualifier}${type.name}${parameters}`;
		}
		case "fn": {
			const parameters = Array.isArray(type.parameters)
				? type.parameters.map((t) => renderType(t, currentModule)).join(", ")
				: "";
			return `fn(${parameters}) -> ${renderType(type.return, currentModule)}`;
		}
		case "tuple":
			return `#(${(type.elements || []).map((t) => renderType(t, currentModule)).join(", ")})`;
		case "variable":
			return variableSymbol(type.id ?? 0);
		default:
			return type.name || type.kind || "Unknown";
	}
}

function renderParameter(parameter, currentModule) {
	const label = parameter.label ? `${parameter.label}: ` : "";
	return `${label}${renderType(parameter.type, currentModule)}`;
}

function renderConstructor(constructor, currentModule) {
	const parameters = constructor.parameters || constructor.arguments || [];
	if (parameters.length === 0) {
		return constructor.name;
	}
	if (parameters.length === 1) {
		return `${constructor.name}(${renderParameter(parameters[0], currentModule)})`;
	}
	const rendered = parameters.map((p) => renderParameter(p, currentModule)).join(",\n  ");
	return `${constructor.name}(\n  ${rendered}\n)`;
}

function renderFunctionSignature(name, parameters, returnType, currentModule) {
	let rendered;
	if (!Array.isArray(parameters) || parameters.length === 0) {
		rendered = "()";
	} else if (parameters.length === 1) {
		rendered = `(${renderParameter(parameters[0], currentModule)})`;
	} else {
		const params = parameters.map((p) => renderParameter(p, currentModule)).join(",\n  ");
		rendered = `(\n  ${params}\n)`;
	}
	return `pub fn ${name}${rendered} -> ${returnType ? renderType(returnType, currentModule) : "Nil"}`;
}

function renderTypeDefinition(name, typeDef, currentModule) {
	const params = renderTypeParameters(typeDef.parameters || 0);
	const constructors = normalizeConstructors(typeDef.constructors);
	if (constructors.length === 0) {
		return `pub type ${name}${params}`;
	}
	const body = constructors
		.map((c) => `  ${renderConstructor(c, currentModule).replaceAll("\n", "\n  ")}`)
		.join("\n");
	return `pub type ${name}${params} {\n${body}\n}`;
}

function renderAliasDefinition(name, alias, currentModule) {
	const params = renderTypeParameters(alias.parameters || 0);
	return `pub type ${name}${params} = ${renderType(alias.alias ?? alias.type, currentModule)}`;
}

function renderConstantDefinition(name, constant, currentModule) {
	return `pub const ${name}: ${renderType(constant.type, currentModule)}`;
}

function deprecationBlock(deprecation) {
	if (!deprecation || typeof deprecation !== "object") {
		return "";
	}
	const message = (deprecation.message || "").trim();
	const body = message.length > 0 ? message : "This item has been deprecated.";
	return `\n\n:::caution[Deprecated]\n${body}\n:::`;
}

function renderIndex(packages) {
	const packageSections = packages
		.map((packageInterface) => {
			const modules = Object.entries(packageInterface.modules).sort(
				([left], [right]) => left.localeCompare(right),
			);
			const moduleRows = modules
				.map(([moduleName, moduleInterface]) => {
					const description = descriptionFromDocs(
						moduleInterface.documentation,
						`Reference for ${moduleName}.`,
					);
					return `| [${code(moduleName)}](${referenceBasePath}/${moduleSlug(moduleName)}/) | ${description} |`;
				})
				.join("\n");
			return `## ${code(packageInterface.name)} ${code(packageInterface.version)}

| Module | Description |
|---|---|
${moduleRows}`;
		})
		.join("\n\n");

	const hexDocsLinks = packages
		.map(
			(packageInterface) =>
				`[${packageInterface.name}](https://hexdocs.pm/${packageInterface.name}/)`,
		)
		.join(", ");

	return `---
title: API Reference
description: Generated API reference from Gleam docs metadata.
---

This reference is generated from Gleam's docs metadata for ${packages
		.map((packageInterface) => code(packageInterface.name))
		.join(" and ")}.

:::note[Generated content]
Pages under \`${referenceBasePath}/\` are generated from Gleam's docs metadata and reflect every public type, function, and constant. The canonical, hosted API docs live on HexDocs: ${hexDocsLinks}.
:::

${packageSections}
`;
}

function renderModulePage(moduleName, moduleInterface) {
	const description = descriptionFromDocs(
		moduleInterface.documentation,
		`Reference for ${moduleName}.`,
	);
	const sections = [
		renderTypes(moduleInterface.types, moduleName),
		renderTypeAliases(moduleInterface["type-aliases"], moduleName),
		renderConstants(moduleInterface.constants, moduleName),
		renderFunctions(moduleInterface.functions, moduleName),
	].filter(Boolean);

	return `---
title: ${moduleName}
description: ${description}
---

${normalizeDoc(moduleInterface.documentation) || description}

${sections.join("\n\n")}
`;
}

function renderConstructorsSection(typeInterface, moduleName) {
	const constructors = normalizeConstructors(typeInterface.constructors).filter(
		(c) => normalizeDoc(c.documentation).length > 0,
	);
	if (constructors.length === 0) {
		return "";
	}

	const items = constructors
		.map((c) => `##### ${code(renderConstructor(c, moduleName))}\n\n${normalizeDoc(c.documentation)}`)
		.join("\n\n");
	return `#### Constructors\n\n${items}`;
}

function renderTypes(types, moduleName) {
	const entries = Object.entries(types || {}).sort(([left], [right]) =>
		left.localeCompare(right),
	);
	if (entries.length === 0) {
		return "";
	}

	return [
		"## Types",
		...entries.map(([name, typeInterface]) => {
			const docs = normalizeDoc(typeInterface.documentation);
			const deprecation = deprecationBlock(typeInterface.deprecation);
			const definition = renderTypeDefinition(name, typeInterface, moduleName);
			const constructors = renderConstructorsSection(typeInterface, moduleName);
			const sections = [
				docs ? `${docs}${deprecation}` : deprecation.replace(/^\n\n/, ""),
				`\`\`\`gleam\n${definition}\n\`\`\``,
				constructors,
			].filter((section) => section && section.length > 0);
			return `### ${code(name)}\n\n${sections.join("\n\n")}`;
		}),
	].join("\n\n");
}

function normalizeConstructors(constructors) {
	if (Array.isArray(constructors)) {
		return constructors;
	}
	return Object.entries(constructors || {})
		.sort(([left], [right]) => left.localeCompare(right))
		.map(([name, constructor]) => ({ name, ...constructor }));
}

function renderTypeAliases(typeAliases, moduleName) {
	const entries = Object.entries(typeAliases || {}).sort(([left], [right]) =>
		left.localeCompare(right),
	);
	if (entries.length === 0) {
		return "";
	}

	return [
		"## Type aliases",
		...entries.map(([name, alias]) => `### ${code(name)}

${normalizeDoc(alias.documentation)}${deprecationBlock(alias.deprecation)}

\`\`\`gleam
${renderAliasDefinition(name, alias, moduleName)}
\`\`\``),
	].join("\n\n");
}

function renderConstants(constants, moduleName) {
	const entries = Object.entries(constants || {}).sort(([left], [right]) =>
		left.localeCompare(right),
	);
	if (entries.length === 0) {
		return "";
	}

	return [
		"## Constants",
		...entries.map(([name, constant]) => `### ${code(name)}

${normalizeDoc(constant.documentation)}${deprecationBlock(constant.deprecation)}

\`\`\`gleam
${renderConstantDefinition(name, constant, moduleName)}
\`\`\``),
	].join("\n\n");
}

function renderFunctions(functions, moduleName) {
	const entries = Object.entries(functions || {}).sort(([left], [right]) =>
		left.localeCompare(right),
	);
	if (entries.length === 0) {
		return "";
	}

	return [
		"## Functions",
		...entries.map(([name, functionInterface]) => {
			const signature = renderFunctionSignature(
				name,
				functionInterface.parameters,
				functionInterface.return,
				moduleName,
			);
			return `### ${code(name)}

${normalizeDoc(functionInterface.documentation)}${deprecationBlock(functionInterface.deprecation)}

\`\`\`gleam
${signature}
\`\`\``;
		}),
	].join("\n\n");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
	generateReference()
		.then(({ pageCount }) => {
			console.log(
				`Generated ${pageCount} reference pages in ${path.relative(repoRoot, defaultOutputDir)}`,
			);
		})
		.catch((error) => {
			console.error(error.message);
			process.exit(1);
		});
}
