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

const textRows = (rows, x, y, lineHeight, className, options = {}) =>
	rows
		.map(
			(row, index) =>
				`<text x="${x}" y="${y + index * lineHeight}" class="${className}"${options.anchor ? ` text-anchor="${options.anchor}"` : ""}>${escapeHtml(row)}</text>`,
		)
		.join("\n");

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

const [displayFont, bodyFont, monoFont, gem] = await Promise.all([
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
	asDataUrl("src/assets/beryl.webp", "image/webp"),
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
	[
		{ text: "    Error", className: "type" },
		{ text: "(_) -> ", className: "plain" },
		{ text: "reject", className: "fn" },
		{ text: "(socket)", className: "plain" },
	],
	[{ text: "  }", className: "plain" }],
	[{ text: "}", className: "plain" }],
];

const facets = [
	{ label: "typed channels", x: 800, y: 172, width: 202, fill: "#173429", stroke: "#5dcc8f", text: "#b7ffd2" },
	{ label: "CRDT presence", x: 879, y: 248, width: 202, fill: "#2b1627", stroke: "#ff78b8", text: "#ffc1dc" },
	{ label: "OTP PubSub", x: 725, y: 333, width: 166, fill: "#122d24", stroke: "#6ff0a4", text: "#d6f7df" },
	{ label: "BEAM native", x: 894, y: 410, width: 178, fill: "#142820", stroke: "#90efb8", text: "#b9f8d0" },
	{ label: "Phoenix wire", x: 623, y: 238, width: 188, fill: "#251927", stroke: "#f06fae", text: "#ffabd0" },
];

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
			.brand { font-family: "Unbounded Variable", system-ui, sans-serif; font-weight: 780; letter-spacing: -2.4px; }
			.headline { font-family: "Hanken Grotesk Variable", system-ui, sans-serif; font-weight: 760; letter-spacing: -0.8px; }
			.body { font-family: "Hanken Grotesk Variable", system-ui, sans-serif; font-weight: 540; }
			.pill { font-family: "Hanken Grotesk Variable", system-ui, sans-serif; font-weight: 760; letter-spacing: 0.2px; }
			.mono { font-family: "JetBrains Mono Variable", ui-monospace, monospace; font-weight: 540; }
			.code-line { fill: #d6f7df; font-size: 20px; }
			.kw { fill: #ff9bc8; }
			.fn { fill: #90efb8; }
			.type { fill: #f2fff5; }
			.str { fill: #ffd1e4; }
			.plain { fill: #c3e6d1; }
		</style>
		<radialGradient id="glow" cx="30%" cy="24%" r="72%">
			<stop offset="0%" stop-color="#69e89f" stop-opacity="0.54" />
			<stop offset="44%" stop-color="#245e43" stop-opacity="0.26" />
			<stop offset="100%" stop-color="#0b1914" stop-opacity="0" />
		</radialGradient>
		<radialGradient id="morganite" cx="80%" cy="22%" r="58%">
			<stop offset="0%" stop-color="#ff78b8" stop-opacity="0.46" />
			<stop offset="54%" stop-color="#6f314e" stop-opacity="0.16" />
			<stop offset="100%" stop-color="#0b1914" stop-opacity="0" />
		</radialGradient>
		<linearGradient id="panel" x1="0" y1="0" x2="1" y2="1">
			<stop offset="0%" stop-color="#152a22" />
			<stop offset="100%" stop-color="#0d1d17" />
		</linearGradient>
		<linearGradient id="gemFace" x1="0" y1="0" x2="1" y2="1">
			<stop offset="0%" stop-color="#d6f7df" />
			<stop offset="48%" stop-color="#69e89f" />
			<stop offset="100%" stop-color="#15885b" />
		</linearGradient>
		<linearGradient id="gemCore" x1="0" y1="0" x2="1" y2="1">
			<stop offset="0%" stop-color="#ffb2d4" />
			<stop offset="100%" stop-color="#ff5ba7" />
		</linearGradient>
		<filter id="softShadow" x="-20%" y="-20%" width="140%" height="150%">
			<feDropShadow dx="0" dy="18" stdDeviation="16" flood-color="#72eba8" flood-opacity="0.2" />
		</filter>
		<filter id="gemShadow" x="-30%" y="-30%" width="160%" height="170%">
			<feDropShadow dx="0" dy="24" stdDeviation="24" flood-color="#69e89f" flood-opacity="0.34" />
		</filter>
	</defs>

	<rect width="1200" height="630" fill="#0b1914" />
	<rect width="1200" height="630" fill="url(#glow)" />
	<rect width="1200" height="630" fill="url(#morganite)" />

	<path d="M58 64 L251 28 L371 132 L304 264 L131 250 Z" fill="#34d989" opacity="0.14" />
	<path d="M864 28 L1135 78 L1062 252 L880 214 Z" fill="#ff78b8" opacity="0.13" />
	<path d="M939 377 L1166 421 L1075 594 L876 535 Z" fill="#8af0b3" opacity="0.1" />
	<path d="M36 466 L215 392 L319 566 L108 605 Z" fill="#d6f7df" opacity="0.06" />
	<path d="M564 58 L715 101 L659 204 L516 171 Z" fill="#90efb8" opacity="0.08" />

	<g transform="translate(82 70)">
		<text x="0" y="82" class="brand" font-size="86" fill="#f2fff5">beryl<tspan fill="#ff78b8">.</tspan></text>
		<text x="4" y="150" class="headline" font-size="45" fill="#d6f7df">Realtime channels</text>
		<text x="4" y="202" class="headline" font-size="45" fill="#d6f7df">cut for Gleam.</text>
		<text x="7" y="260" class="body" font-size="25" fill="#a6cdb8">Typed sockets, Phoenix-compatible wire,</text>
		<text x="7" y="295" class="body" font-size="25" fill="#a6cdb8">and presence that belongs on the BEAM.</text>
	</g>

	<g transform="translate(92 420)" filter="url(#softShadow)">
		<rect x="0" y="0" width="482" height="154" rx="16" fill="url(#panel)" stroke="#32624d" />
		<rect x="0" y="0" width="482" height="44" rx="16" fill="#12251d" />
		<circle cx="27" cy="23" r="6" fill="#ff78b8" />
		<circle cx="49" cy="23" r="6" fill="#90efb8" />
		<circle cx="71" cy="23" r="6" fill="#d6f7df" opacity="0.8" />
		<text x="329" y="29" class="mono" font-size="16" fill="#80a991">channel.gleam</text>
		${highlightedRows(code.slice(0, 3), 28, 77, 31)}
	</g>

	<g filter="url(#gemShadow)">
		<path d="M714 304 L818 132 L997 116 L1102 280 L1021 484 L804 507 Z" fill="url(#gemFace)" opacity="0.96" />
		<path d="M818 132 L873 304 L714 304 Z" fill="#d6f7df" opacity="0.45" />
		<path d="M818 132 L997 116 L873 304 Z" fill="#90efb8" opacity="0.62" />
		<path d="M997 116 L1102 280 L873 304 Z" fill="#58d88f" opacity="0.66" />
		<path d="M873 304 L1102 280 L1021 484 Z" fill="#187d58" opacity="0.52" />
		<path d="M714 304 L873 304 L804 507 Z" fill="#245e43" opacity="0.48" />
		<path d="M873 304 L1021 484 L804 507 Z" fill="#69e89f" opacity="0.43" />
		<path d="M841 253 L925 206 L997 270 L959 369 L852 367 Z" fill="url(#gemCore)" opacity="0.9" />
		<path d="M714 304 L818 132 L997 116 L1102 280 L1021 484 L804 507 Z" fill="none" stroke="#d6f7df" stroke-width="3" opacity="0.45" />
	</g>

	<image href="${gem}" x="858" y="258" width="114" height="114" preserveAspectRatio="xMidYMid meet" opacity="0.92" />
	<path d="M710 305 C667 276 636 256 595 251" fill="none" stroke="#90efb8" stroke-width="2" opacity="0.32" />
	<path d="M1000 318 C1071 329 1114 364 1146 414" fill="none" stroke="#ff78b8" stroke-width="2" opacity="0.24" />
	${facets
		.map(
			({ label, x, y, width, fill, stroke, text }) => `
	<g transform="translate(${x} ${y})">
		<rect x="0" y="0" width="${width}" height="48" rx="24" fill="${fill}" stroke="${stroke}" opacity="0.96" />
		<text x="${width / 2}" y="31" class="pill" font-size="20" fill="${text}" text-anchor="middle">${label}</text>
	</g>`,
		)
		.join("")}
	<text x="930" y="571" class="body" font-size="20" fill="#a6cdb8" text-anchor="middle">beryl.tylerbutler.com</text>
</svg>
`;

await mkdir(dirname(output), { recursive: true });
await sharp(Buffer.from(svg)).png({ compressionLevel: 9 }).toFile(output);

console.log(`Generated ${output}`);
