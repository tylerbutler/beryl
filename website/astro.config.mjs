import starlight from "@astrojs/starlight";
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
				"@fontsource/metropolis/400.css",
				"@fontsource/metropolis/600.css",
				"./src/styles/fonts.css",
				"./src/styles/custom.css",
			],
			components: {
				Head: "./src/components/Head.astro",
			},
			plugins: [
				starlightLlmsTxt(),
				starlightLinksValidator(),
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
