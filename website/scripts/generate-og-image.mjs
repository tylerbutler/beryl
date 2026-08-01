// Renders the Open Graph card to website/public/og.png.
//
// Run this by hand (`pnpm generate:og`) when the card's design, wording, or
// source assets change, then commit the regenerated public/og.png.
//
// Deliberately NOT part of `build:site`. public/og.png is a committed asset
// that Astro copies verbatim into dist/, and sharp's PNG output is not
// byte-stable across runs — rebuilding it on every build left an unrelated
// ~300KB binary diff in the working tree after any local site build.

import { mkdir, readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(scriptDir, "..");
const output = resolve(root, "public/og.png");

const size = {
	width: 1200,
	height: 630,
};

const asset = (path) => resolve(root, path);
const asDataUrl = async (path, mime) => {
	const bytes = await readFile(asset(path));
	return `data:${mime};base64,${bytes.toString("base64")}`;
};

const escapeHtml = (value) =>
	value
		.replaceAll("&", "&amp;")
		.replaceAll("<", "&lt;")
		.replaceAll(">", "&gt;")
		.replaceAll('"', "&quot;");

const highlightedRows = (rows, x, y, lineHeight) =>
	rows
		.map(
			(row, index) => `<text x="${x}" y="${y + index * lineHeight}" class="mono code-line" xml:space="preserve">${row
				.map(
					({ text, className }) =>
						`<tspan class="${className}">${escapeHtml(text)}</tspan>`,
				)
				.join("")}</text>`,
		)
		.join("\n");

const [displayFont, bodyFont, monoFont] = await Promise.all([
	asDataUrl(
		"node_modules/@fontsource-variable/unbounded/files/unbounded-latin-wght-normal.woff2",
		"font/woff2",
	),
	asDataUrl(
		"node_modules/@fontsource-variable/hanken-grotesk/files/hanken-grotesk-latin-wght-normal.woff2",
		"font/woff2",
	),
	asDataUrl(
		"node_modules/@fontsource-variable/jetbrains-mono/files/jetbrains-mono-latin-wght-normal.woff2",
		"font/woff2",
	),
]);

const code = [
	[
		{ text: "pub fn ", className: "kw" },
		{ text: "join", className: "fn" },
		{ text: "(socket, topic) {", className: "plain" },
	],
	[
		{ text: "  case ", className: "kw" },
		{ text: "matches", className: "fn" },
		{ text: "(topic, ", className: "plain" },
		{ text: '"room:*"', className: "str" },
		{ text: ") {", className: "plain" },
	],
	[
		{ text: "    Ok", className: "type" },
		{ text: "(_) -> ", className: "plain" },
		{ text: "accept", className: "fn" },
		{ text: "(socket)", className: "plain" },
	],
];

// Capability pills zigzag down the gem's silhouette. Right-side pills share
// one right margin; left-side pills share one left edge.
const PILL_RIGHT_EDGE = 1118;
const PILL_LEFT_EDGE = 680;
const pills = [
	{ label: "typed channels", side: "right", y: 96, width: 238, fill: "#173429", stroke: "#5dcc8f", text: "#c8ffdd" },
	{ label: "Phoenix wire", side: "left", y: 180, width: 208, fill: "#251927", stroke: "#f06fae", text: "#ffb8d6" },
	{ label: "OTP PubSub", side: "right", y: 264, width: 198, fill: "#122d24", stroke: "#6ff0a4", text: "#d6f7df" },
	{ label: "CRDT presence", side: "left", y: 348, width: 240, fill: "#2b1627", stroke: "#ff78b8", text: "#ffc9e0" },
	{ label: "BEAM native", side: "right", y: 432, width: 208, fill: "#142820", stroke: "#90efb8", text: "#c9f8d8" },
];
const pillX = ({ side, width }) =>
	side === "right" ? PILL_RIGHT_EDGE - width : PILL_LEFT_EDGE;

// Emerald-cut gem: outer hexagon, inner table, one facet quad per edge.
// Solid fills (no opacity stacking) keep the color steps crisp on the dark
// base. Light reads from the top-left.
const gemOuter = [
	[720, 295],
	[815, 115],
	[1000, 100],
	[1095, 268],
	[1013, 472],
	[795, 495],
];
const gemCenter = [900, 288];
const gemTable = gemOuter.map(([x, y]) => [
	Math.round(gemCenter[0] + 0.45 * (x - gemCenter[0])),
	Math.round(gemCenter[1] + 0.45 * (y - gemCenter[1])),
]);
const facetFills = ["#8beeb4", "#c9f7d6", "#4ed489", "#1e9a63", "#115c3c", "#2fb377"];
const gemFacets = gemOuter
	.map((v, i) => {
		const w = gemOuter[(i + 1) % gemOuter.length];
		const t2 = gemTable[(i + 1) % gemTable.length];
		const t1 = gemTable[i];
		return `<path d="M${v[0]} ${v[1]} L${w[0]} ${w[1]} L${t2[0]} ${t2[1]} L${t1[0]} ${t1[1]} Z" fill="${facetFills[i]}" />`;
	})
	.join("\n\t\t");
const polygonPath = (points) =>
	`M${points.map(([x, y]) => `${x} ${y}`).join(" L")} Z`;

const glint = (x, y, s) =>
	`d="M${x} ${y - s} L${x + s * 0.26} ${y - s * 0.26} L${x + s} ${y} L${x + s * 0.26} ${y + s * 0.26} L${x} ${y + s} L${x - s * 0.26} ${y + s * 0.26} L${x - s} ${y} L${x - s * 0.26} ${y - s * 0.26} Z"`;

const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg width="${size.width}" height="${size.height}" viewBox="0 0 ${size.width} ${size.height}" xmlns="http://www.w3.org/2000/svg">
	<defs>
		<style>
			@font-face {
				font-family: "Unbounded Variable";
				src: url("${displayFont}") format("woff2");
				font-weight: 400 900;
			}
			@font-face {
				font-family: "Hanken Grotesk Variable";
				src: url("${bodyFont}") format("woff2");
				font-weight: 300 900;
			}
			@font-face {
				font-family: "JetBrains Mono Variable";
				src: url("${monoFont}") format("woff2");
				font-weight: 100 800;
			}
			.brand { font-family: "Unbounded Variable", system-ui, sans-serif; font-weight: 780; letter-spacing: -2.8px; }
			.headline { font-family: "Hanken Grotesk Variable", system-ui, sans-serif; font-weight: 760; letter-spacing: -1px; }
			.body { font-family: "Hanken Grotesk Variable", system-ui, sans-serif; font-weight: 540; }
			.pill { font-family: "Hanken Grotesk Variable", system-ui, sans-serif; font-weight: 760; letter-spacing: 0.2px; }
			.mono { font-family: "JetBrains Mono Variable", ui-monospace, monospace; font-weight: 540; }
			.code-line { fill: #d6f7df; font-size: 23px; }
			.kw { fill: #ff9bc8; }
			.fn { fill: #90efb8; }
			.type { fill: #f2fff5; }
			.str { fill: #ffd1e4; }
			.plain { fill: #c3e6d1; }
		</style>
		<radialGradient id="glow" cx="30%" cy="24%" r="72%">
			<stop offset="0%" stop-color="#69e89f" stop-opacity="0.5" />
			<stop offset="44%" stop-color="#245e43" stop-opacity="0.24" />
			<stop offset="100%" stop-color="#0b1914" stop-opacity="0" />
		</radialGradient>
		<radialGradient id="morganite" cx="82%" cy="20%" r="55%">
			<stop offset="0%" stop-color="#ff78b8" stop-opacity="0.4" />
			<stop offset="54%" stop-color="#6f314e" stop-opacity="0.14" />
			<stop offset="100%" stop-color="#0b1914" stop-opacity="0" />
		</radialGradient>
		<linearGradient id="panel" x1="0" y1="0" x2="1" y2="1">
			<stop offset="0%" stop-color="#152a22" />
			<stop offset="100%" stop-color="#0d1d17" />
		</linearGradient>
		<linearGradient id="tableFace" x1="0" y1="0" x2="1" y2="1">
			<stop offset="0%" stop-color="#f2fff5" />
			<stop offset="100%" stop-color="#9df3bf" />
		</linearGradient>
		<filter id="panelShadow" x="-20%" y="-20%" width="140%" height="150%">
			<feDropShadow dx="0" dy="16" stdDeviation="18" flood-color="#03110a" flood-opacity="0.55" />
		</filter>
		<filter id="gemShadow" x="-30%" y="-30%" width="160%" height="170%">
			<feDropShadow dx="0" dy="22" stdDeviation="26" flood-color="#69e89f" flood-opacity="0.28" />
		</filter>
		<filter id="pillShadow" x="-30%" y="-30%" width="160%" height="200%">
			<feDropShadow dx="0" dy="6" stdDeviation="9" flood-color="#03110a" flood-opacity="0.4" />
		</filter>
	</defs>

	<rect width="1200" height="630" fill="#0b1914" />
	<rect width="1200" height="630" fill="url(#glow)" />
	<rect width="1200" height="630" fill="url(#morganite)" />

	<path d="M40 60 L230 24 L330 130 L150 210 Z" fill="#34d989" opacity="0.08" />
	<path d="M980 30 L1170 70 L1120 200 L990 150 Z" fill="#ff78b8" opacity="0.1" />
	<path d="M40 470 L200 400 L290 560 L100 600 Z" fill="#d6f7df" opacity="0.05" />
	<path d="M1050 500 L1180 470 L1160 610 L1040 600 Z" fill="#8af0b3" opacity="0.07" />

	<g transform="translate(82 0)">
		<text x="0" y="112" class="brand" font-size="96" fill="#f2fff5">beryl<tspan fill="#ff78b8">.</tspan></text>
		<text x="4" y="186" class="headline" font-size="57" fill="#d6f7df">Realtime channels</text>
		<text x="4" y="248" class="headline" font-size="57" fill="#d6f7df">cut for Gleam.</text>
		<text x="7" y="305" class="body" font-size="28" fill="#a6cdb8">Typed sockets, Phoenix-compatible wire,</text>
		<text x="7" y="343" class="body" font-size="28" fill="#a6cdb8">and presence that belongs on the BEAM.</text>
	</g>

	<g transform="translate(82 396)" filter="url(#panelShadow)">
		<rect x="0" y="0" width="512" height="178" rx="18" fill="url(#panel)" stroke="#32624d" stroke-width="1.5" />
		<path d="M0 18 A18 18 0 0 1 18 0 H494 A18 18 0 0 1 512 18 V46 H0 Z" fill="#12251d" />
		<circle cx="27" cy="23" r="6.5" fill="#ff78b8" />
		<circle cx="50" cy="23" r="6.5" fill="#90efb8" />
		<circle cx="73" cy="23" r="6.5" fill="#d6f7df" opacity="0.85" />
		<text x="488" y="29" class="mono" font-size="17" fill="#80a991" text-anchor="end">channel.gleam</text>
		${highlightedRows(code, 28, 88, 34)}
	</g>

	<g filter="url(#gemShadow)">
		<g stroke="#f2fff5" stroke-opacity="0.16" stroke-width="1">
			${gemFacets}
			<path d="${polygonPath(gemTable)}" fill="url(#tableFace)" />
		</g>
		<path d="${polygonPath(gemOuter)}" fill="none" stroke="#d6f7df" stroke-width="2.5" opacity="0.5" />
	</g>
	<path ${glint(838, 168, 15)} fill="#ffffff" opacity="0.85" />
	<path ${glint(958, 340, 9)} fill="#ffffff" opacity="0.55" />

	<g filter="url(#pillShadow)">${pills
		.map(
			(pill) => `
		<g transform="translate(${pillX(pill)} ${pill.y})">
			<rect x="0" y="0" width="${pill.width}" height="54" rx="27" fill="${pill.fill}" stroke="${pill.stroke}" stroke-width="2" />
			<text x="${pill.width / 2}" y="35" class="pill" font-size="24" fill="${pill.text}" text-anchor="middle">${escapeHtml(pill.label)}</text>
		</g>`,
		)
		.join("")}
	</g>
	<text x="1118" y="588" class="body" font-size="22" fill="#a6cdb8" text-anchor="end">beryl.tylerbutler.com</text>
</svg>
`;

await mkdir(dirname(output), { recursive: true });
await sharp(Buffer.from(svg)).png({ compressionLevel: 9 }).toFile(output);

console.log(`Generated ${output}`);
