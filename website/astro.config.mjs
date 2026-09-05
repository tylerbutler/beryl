import starlight from "@astrojs/starlight";
import mermaid from "astro-mermaid";
import a11yEmoji from "@fec/remark-a11y-emoji";
import { defineConfig } from "astro/config";
import starlightLinksValidator from "starlight-links-validator";
import starlightLlmsTxt from "starlight-llms-txt";

// https://astro.build/config
export default defineConfig({
	site: "https://beryl.tylerbutler.com",
	redirects: {
		"/reference/api/beryl-stats/": "/reference/api/beryl-snapshot/",
	},
	prefetch: {
		defaultStrategy: "hover",
		prefetchAll: true,
	},
	integrations: [
		mermaid({ theme: "default" }),
		starlight({
			title: "beryl",
			editLink: {
				baseUrl:
					"https://github.com/tylerbutler/beryl/edit/main/website/",
			},
			description:
				"Type-safe real-time channels and presence for Gleam.",
			// Green-based syntax themes so code tokens stay in the beryl
			// palette instead of the default themes' neon purples.
			expressiveCode: {
				themes: ["everforest-dark", "everforest-light"],
				// Token colors come from Everforest; frame chrome and
				// backgrounds stay on the site palette.
				useStarlightUiThemeColors: true,
				// Wrap rather than clip. The gleam.toml git-dependency lines
				// are the most important snippet on the site and were being
				// cut mid-string (718px visible of 947px) at desktop widths,
				// with no fade, scrollbar or wrap to signal it. Since beryl
				// isn't on Hex, those lines have to be read and adapted, not
				// blind-copied. preserveIndent keeps continuations aligned.
				defaultProps: {
					wrap: true,
					preserveIndent: true,
				},
			},
			lastUpdated: true,
			logo: {
				src: "./src/assets/beryl.webp",
				alt: "beryl logo",
			},
			favicon: "/favicon.png",
			customCss: [
				"@fontsource-variable/unbounded",
				"@fontsource-variable/hanken-grotesk",
				"@fontsource-variable/jetbrains-mono",
				"./src/styles/fonts.css",
				"./src/styles/custom.css",
			],
			components: {
				Head: "./src/components/Head.astro",
				Hero: "./src/components/Hero.astro",
			},
			plugins: [
				starlightLlmsTxt(),
				starlightLinksValidator({
					// Fail the build in CI so broken links can't ship; stay
					// permissive locally so a work-in-progress page doesn't
					// block `astro dev`.
					failOnError: Boolean(process.env.CI),
				}),
			],
			social: [
				{
					icon: "github",
					label: "GitHub",
					href: "https://github.com/tylerbutler/beryl",
				},
			],
			sidebar: [
				{
					label: "Start here",
					items: [
						{
							label: "What is beryl?",
							slug: "introduction",
						},
						{
							label: "Installation",
							slug: "installation",
						},
						{
							label: "Choose an API",
							slug: "choosing-an-api",
						},
						{
							label: "Quick start",
							slug: "quick-start",
						},
						{
							label: "Examples",
							slug: "examples",
						},
					],
				},
				{
					label: "Tutorial",
					items: [
						{
							label: "Build a live poll",
							slug: "tutorial",
						},
						{
							label: "1. Elm architecture without a DOM",
							slug: "tutorial/the-elm-architecture-without-a-dom",
						},
						{
							label: "2. One update function",
							slug: "tutorial/one-update-function-many-socket-events",
						},
						{
							label: "3. Typed system messages",
							slug: "tutorial/typed-messages-from-your-gleam-system",
						},
						{
							label: "4. Raw dispatch and channels",
							slug: "tutorial/composition-raw-dispatch-and-channels",
						},
						{
							label: "5. Runtime boundaries",
							slug: "tutorial/where-the-analogy-ends",
						},
						{
							label: "6. Supervision",
							slug: "tutorial/supervising-beryl",
						},
					],
				},
				{
					label: "Guides",
					items: [
						{
							label: "Core concepts",
							items: [
								{
									label: "Raw dispatch",
									slug: "guides/dispatch",
								},
								{
									label: "Channel handlers",
									slug: "guides/channels",
								},
								{
									label: "Presence",
									slug: "guides/presence",
								},
								{
									label: "PubSub",
									slug: "guides/pubsub",
								},
								{
									label: "Groups",
									slug: "guides/groups",
								},
							],
						},
						{
							label: "Integration",
							collapsed: true,
							items: [
								{
									label: "WebSocket transport",
									slug: "guides/websocket",
								},
								{
									label: "Authentication",
									slug: "guides/authentication",
								},
								{
									label: "Backend integration",
									slug: "guides/backend-integration",
								},
								{
									label: "Coming from Phoenix",
									slug: "guides/coming-from-phoenix",
								},
							],
						},
						{
							label: "Running in production",
							collapsed: true,
							items: [
								{
									label: "Supervision",
									slug: "guides/supervision",
								},
								{
									label: "Error handling",
									slug: "guides/error-handling",
								},
								{
									label: "Observability",
									slug: "guides/observability",
								},
								{
									label: "Production hardening",
									slug: "guides/production-hardening",
								},
							],
						},
					],
				},
				{
					label: "Reference",
					items: [
						{
							label: "API overview",
							slug: "reference",
						},
						{
							label: "Generated API",
							collapsed: true,
							items: [
								{
									autogenerate: {
										directory: "reference/api",
									},
								},
							],
						},
					],
				},
				{
					label: "Architecture",
					// Collapsed by default like Integration and Running in
					// Production. Expanded it put 6 links on every page —
					// the group least relevant to someone on Quick Start took
					// the most open real estate, and the open/closed policy
					// tracked nothing a reader could predict. Starlight still
					// auto-expands whichever group holds the current page.
					collapsed: true,
					items: [
						{
							label: "Overview",
							slug: "architecture/overview",
						},
						{
							label: "How beryl handles a message",
							slug: "architecture/message-lifecycle",
						},
						{
							label: "Socket processes & restarts",
							slug: "architecture/runtime",
						},
						{
							label: "Broadcasts across nodes",
							slug: "architecture/pubsub-and-distribution",
						},
						{
							label: "Presence",
							slug: "architecture/presence",
						},
						{
							label: "WebSocket frames & transports",
							slug: "architecture/wire-and-transport",
						},
					],
				},
				{
					label: "Help",
					items: [
						{
							label: "Troubleshooting",
							slug: "troubleshooting",
						},
					],
				},
			],
		}),
	],
	markdown: {
		smartypants: false,
		remarkPlugins: [
			a11yEmoji,
		],
	},
});
