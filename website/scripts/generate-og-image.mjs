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

const textRows = (rows, x, y, lineHeight, className) =>
	rows
		.map(
			(row, index) =>
				`<text x="${x}" y="${y + index * lineHeight}" class="${className}">${escapeHtml(row)}</text>`,
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
	"pub fn join(socket, topic) {",
	'  case topic.matches(topic, "room:*") {',
	"    Ok(assigns) ->",
	"      channel.accept(socket, assigns)",
	"    Error(_) ->",
	"      channel.reject(socket)",
	"  }",
	"}",
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
			.brand { font-family: "Unbounded Variable", system-ui, sans-serif; font-weight: 760; letter-spacing: -3px; }
			.headline { font-family: "Hanken Grotesk Variable", system-ui, sans-serif; font-weight: 760; letter-spacing: -1.2px; }
			.body { font-family: "Hanken Grotesk Variable", system-ui, sans-serif; font-weight: 520; }
			.mono { font-family: "JetBrains Mono Variable", ui-monospace, monospace; font-weight: 520; }
			.code { fill: #d6f7df; font-size: 26px; }
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
		<filter id="softShadow" x="-20%" y="-20%" width="140%" height="150%">
			<feDropShadow dx="0" dy="22" stdDeviation="18" flood-color="#72eba8" flood-opacity="0.18" />
		</filter>
	</defs>

	<rect width="1200" height="630" fill="#0b1914" />
	<rect width="1200" height="630" fill="url(#glow)" />
	<rect width="1200" height="630" fill="url(#morganite)" />

	<path d="M67 72 L245 26 L392 122 L322 266 L140 258 Z" fill="#34d989" opacity="0.13" />
	<path d="M842 29 L1124 83 L1051 258 L873 218 Z" fill="#ff78b8" opacity="0.15" />
	<path d="M966 374 L1170 418 L1078 594 L893 532 Z" fill="#8af0b3" opacity="0.1" />
	<path d="M42 454 L214 390 L303 566 L112 602 Z" fill="#d6f7df" opacity="0.06" />

	<g transform="translate(88 78)">
		<text x="0" y="82" class="brand" font-size="88" fill="#f2fff5">beryl<tspan fill="#ff78b8">.</tspan></text>
		<text x="4" y="142" class="headline" font-size="43" fill="#d6f7df">Type-safe realtime channels</text>
		<text x="4" y="193" class="headline" font-size="43" fill="#d6f7df">and presence for Gleam.</text>
		<text x="6" y="249" class="body" font-size="25" fill="#a6cdb8">Phoenix-compatible wire. OTP-native PubSub.</text>
		<text x="6" y="284" class="body" font-size="25" fill="#a6cdb8">CRDT-backed presence on the BEAM.</text>
	</g>

	<g transform="translate(100 458)">
		<rect x="0" y="0" width="158" height="48" rx="24" fill="#173429" stroke="#377b5a" />
		<text x="24" y="31" class="body" font-size="20" font-weight="720" fill="#90efb8">channels</text>
		<rect x="176" y="0" width="142" height="48" rx="24" fill="#251927" stroke="#7b3c5c" />
		<text x="200" y="31" class="body" font-size="20" font-weight="720" fill="#ff9bc8">presence</text>
		<rect x="336" y="0" width="116" height="48" rx="24" fill="#173429" stroke="#377b5a" />
		<text x="361" y="31" class="body" font-size="20" font-weight="720" fill="#d6f7df">pubsub</text>
	</g>

	<g transform="translate(659 107)" filter="url(#softShadow)">
		<rect x="0" y="0" width="438" height="385" rx="18" fill="url(#panel)" stroke="#32624d" />
		<rect x="0" y="0" width="438" height="58" rx="18" fill="#12251d" />
		<circle cx="33" cy="30" r="7" fill="#ff78b8" />
		<circle cx="58" cy="30" r="7" fill="#90efb8" />
		<circle cx="83" cy="30" r="7" fill="#d6f7df" opacity="0.8" />
		<text x="308" y="38" class="mono" font-size="18" fill="#80a991">channel.gleam</text>
		${textRows(code, 34, 107, 36, "mono code")}
	</g>

	<image href="${gem}" x="920" y="347" width="178" height="178" preserveAspectRatio="xMidYMid meet" />
	<path d="M913 372 L1010 326 L1085 382 L1044 486 L938 486 Z" fill="none" stroke="#90efb8" stroke-width="2" opacity="0.32" />
</svg>
`;

await mkdir(dirname(output), { recursive: true });
await sharp(Buffer.from(svg)).png({ compressionLevel: 9 }).toFile(output);

console.log(`Generated ${output}`);
