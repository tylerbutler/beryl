import starlight from "@astrojs/starlight";
import mermaid from "astro-mermaid";
import a11yEmoji from "@fec/remark-a11y-emoji";
import { defineConfig } from "astro/config";
import starlightLinksValidator from "starlight-links-validator";
import starlightLlmsTxt from "starlight-llms-txt";

// https://astro.build/config
export default defineConfig({
	site: "https://beryl.tylerbutler.com",
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
					// Report broken links but don't fail the build on them.
					failOnError: false,
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
					label: "Start Here",
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
							label: "Quick Start",
							slug: "quick-start",
						},
						{
							label: "Examples",
							slug: "examples",
						},
					],
				},
				{
					label: "Guides",
					items: [
						{
							label: "Channels",
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
						{
							label: "Supervision",
							slug: "guides/supervision",
						},
						{
							label: "Error Handling",
							slug: "guides/error-handling",
						},
						{
							label: "WebSocket Transport",
							slug: "guides/websocket",
						},
					],
				},
				{
					label: "Reference",
					items: [
						{
							label: "API Overview",
							slug: "reference",
						},
						{
							label: "Generated API",
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
					items: [
						{
							label: "Overview",
							slug: "architecture/overview",
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
						{
							label: "Migration & Releases",
							slug: "migration",
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
