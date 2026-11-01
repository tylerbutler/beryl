import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Keep this list explicit: a new production dependency needs a portability review.
const portablePackages = new Set([
	"beryl_protocol",
	"portable_channels",
	"gleam_stdlib",
	"gleam_json",
	"roost",
]);

export function productionGraph(root, loadPackage) {
	const visited = new Set();
	function visit(name) {
		if (visited.has(name)) return;
		if (!portablePackages.has(name)) {
			throw new Error(`Unreviewed portable production dependency: ${name}`);
		}
		visited.add(name);
		const information = loadPackage(name);
		for (const dependency of Object.keys(information.dependencies ?? {})) {
			visit(dependency);
		}
	}
	visit(root);
	return [...visited].sort();
}

function check(directory) {
	const temporary = mkdtempSync(path.join(tmpdir(), "beryl-portable-deps-"));
	try {
		function information(cwd) {
			const output = path.join(temporary, "package.json");
			execFileSync("gleam", ["export", "package-information", "--out", output], {
				cwd,
				stdio: "pipe",
			});
			return JSON.parse(readFileSync(output, "utf8"))["gleam.toml"];
		}
		const root = information(directory);
		const directories = new Map([[root.name, directory]]);
		const graph = productionGraph(root.name, (name) => {
			const currentDirectory = directories.get(name);
			const current = name === root.name ? root : information(currentDirectory);
			for (const [dependency, requirement] of Object.entries(current.dependencies ?? {})) {
				directories.set(
					dependency,
					requirement.path
						? path.resolve(currentDirectory, requirement.path)
						: path.join(directory, "build", "packages", dependency),
				);
			}
			return current;
		});
		console.log(`${root.name}: ${graph.join(", ")}`);
	} finally {
		rmSync(temporary, { recursive: true, force: true });
	}
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	const root = fileURLToPath(new URL("../", import.meta.url));
	check(path.join(root, "packages/beryl_protocol"));
	check(path.join(root, "examples/portable_channels"));
}
