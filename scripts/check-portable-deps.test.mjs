import assert from "node:assert/strict";
import test from "node:test";
import { productionGraph } from "./check-portable-deps.mjs";

test("walks transitive production dependencies but excludes development tools", () => {
	const packages = {
		portable_channels: {
			dependencies: { roost: {}, beryl_protocol: {} },
			dev_dependencies: { gleam_erlang: {} },
		},
		roost: { dependencies: { gleam_json: {}, gleam_stdlib: {} } },
		beryl_protocol: { dependencies: { gleam_stdlib: {} } },
		gleam_json: { dependencies: { gleam_stdlib: {} } },
		gleam_stdlib: {},
	};
	assert.deepEqual(
		productionGraph("portable_channels", (name) => packages[name]),
		["beryl_protocol", "gleam_json", "gleam_stdlib", "portable_channels", "roost"],
	);
});

test("rejects a BEAM dependency hidden behind an allowed package", () => {
	const packages = {
		beryl_protocol: { dependencies: { gleam_json: {} } },
		gleam_json: { dependencies: { gleam_otp: {} } },
	};
	assert.throws(
		() => productionGraph("beryl_protocol", (name) => packages[name]),
		/Unreviewed portable production dependency: gleam_otp/,
	);
});
