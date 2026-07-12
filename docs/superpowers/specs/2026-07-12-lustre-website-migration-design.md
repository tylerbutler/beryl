# Lustre Website Migration Design

## Summary

Beryl will add Lustre through a hybrid architecture before considering a full
website rewrite. Starlight will continue to render and deploy the documentation
site. Lustre will own interactive examples, visualizers, guided playgrounds,
and the API explorer. A separate Mist and beryl service will run live,
short-lived scenarios.

This approach improves the website where interactivity matters without first
rebuilding Starlight's documentation infrastructure. It also creates a tested
migration path toward a static Lustre site.

## Context

The current website contains 40 Markdown and MDX pages. Starlight supplies:

- Markdown and MDX rendering
- navigation, tables of contents, and responsive documentation layouts
- syntax highlighting and Mermaid diagrams
- Pagefind search
- metadata, canonical URLs, sitemaps, and social cards
- `llms.txt` output
- generated API reference navigation
- static Netlify output and deploy previews

The repository also generates Markdown API pages from Gleam's
`package-interface.json`. Three MDX pages use Starlight components or custom
markup.

Lustre can render static HTML, browser applications, Web Components, and
server-side components. Its official `lustre_ssg` package can generate static
routes, but it intentionally omits a CLI, development server, data layer, and
hydration. A complete Lustre documentation site would therefore need to replace
most of the facilities listed above.

## Goals

1. Add live, typed, realtime experiences to the documentation.
2. Keep Markdown as the canonical source for prose and generated API pages.
3. Reuse interactive Lustre modules if the site shell later moves away from
   Starlight.
4. Keep the production documentation site static and resilient.
5. Isolate public demo traffic from documentation content and repository
   infrastructure.
6. Prove the architecture with one narrow vertical slice before expanding it.

## Non-goals

- Replace Starlight in the first release.
- Compile arbitrary Gleam programs in the browser.
- Create a new browser beryl client.
- Move documentation prose into Gleam view functions.
- Serve the production documentation site from a BEAM application.
- Rebuild search, syntax highlighting, Mermaid, or metadata generation before a
  full shell migration is approved.

## Chosen Architecture

The website gains a JavaScript-targeted Lustre project and an Erlang-targeted
demo server:

```text
website/
├── src/content/docs/        # Canonical Markdown and MDX
├── src/components/          # Thin Astro hosts for Lustre elements
├── interactive/             # Gleam -> JavaScript
│   └── src/beryl_site/
│       ├── component/
│       ├── protocol/
│       └── main.gleam
└── demo_server/             # Gleam -> Erlang
    └── src/beryl_demo/
        ├── channels/
        ├── scenarios/
        └── main.gleam
```

Astro hosts load the Lustre bundle only on pages that need it and pass JSON
that each component decodes into a typed configuration value. Lustre owns
component state, rendering, reconnect behavior, and WebSocket interaction. The
demo server owns sandbox channels and short-lived scenario state. It never
serves documentation content.

The browser components will use the Phoenix JavaScript client through a small
Gleam FFI module. This keeps the first release focused on the website and uses
beryl's existing wire compatibility.

## Migration Boundary

Interactive modules must not depend on Astro APIs. Each component receives a
small configuration value and renders as a custom element. Shared styles use
ordinary CSS custom properties rather than Starlight-specific selectors.

Markdown remains canonical. The API reference generator will emit both:

- the existing Markdown pages
- a versioned JSON index for the Lustre API explorer

These boundaries let a future `lustre_ssg` renderer reuse the components,
styles, scenario data, and API index. A shell migration would replace only the
page renderer, navigation, content loader, and documentation build services.

## Interactive Experiences

### Examples Lab

The `/examples/` page will grow into a set of runnable labs for presence, chat,
cursors, and collaborative state. Each lab will show:

- the rendered application
- connection and compatibility status
- Phoenix frames and relevant beryl events
- the Gleam code that implements the scenario
- reset and second-client controls

The first release will implement only the presence lab.

### Architecture Visualizers

Architecture guides will embed focused visualizers:

- message lifecycle: transport to codec to coordinator to channel to PubSub
- presence: joins, leaves, diffs, replicas, and convergence
- distribution: topics, nodes, process groups, and broadcasts

Visualizers will use deterministic local state unless a live server adds clear
value.

### Guided Playgrounds

Guided playgrounds will let readers change bounded inputs such as topic names,
payloads, rate limits, origin policy, and callback outcomes. The component will
generate valid Gleam snippets and run supported scenarios against the demo
service.

The first release will not compile arbitrary Gleam. A compiler-backed
playground would require a separate design covering compilation, resource
limits, dependency resolution, and code execution isolation.

### API Explorer

The API explorer will consume the generated JSON index. It will filter by
module and item kind, display signatures beside documentation, and link to each
canonical reference page. It requires no live backend.

## Component Contract

Each interactive custom element decodes:

- a component and scenario identifier
- the static scenario configuration
- the demo service base URL, when required
- the expected compatibility version
- optional initial, shareable state

The component may place safe scenario settings in the URL. It must not place
socket identifiers, session identifiers, user-entered payloads, or credentials
in the URL.

The demo service exposes:

- service status
- beryl version
- protocol compatibility version
- supported scenario identifiers

If the static site and service disagree, the component enters the
`Incompatible` state and disables live controls.

## Build and Deployment

The production build remains static:

```text
gleam docs build
  -> generate reference Markdown and API JSON
  -> build the Lustre component bundle
  -> build Astro and Starlight
  -> generate search, sitemap, llms.txt, and static assets
  -> deploy to Netlify
```

The demo service deploys separately at `demos.beryl.tylerbutler.com`. Local
development uses an Astro proxy or an explicit localhost origin.

The documentation remains readable when the component bundle or demo service
is unavailable. Each Astro host renders a static summary inside the custom
element before JavaScript upgrades it. Live controls display an offline state
instead of hiding content or failing silently.

## State and Failure Handling

Interactive components use explicit states:

- `Static`
- `Connecting`
- `Connected`
- `Reconnecting`
- `Offline`
- `Incompatible`
- `Failed`

Reconnect attempts are bounded. Resetting a failed scenario creates a fresh,
isolated session. Components show actionable errors and keep the explanatory
content visible.

The service returns explicit errors for unsupported scenarios, invalid payloads,
expired sessions, and capacity limits. It does not return success-shaped
fallbacks.

## Security and Abuse Controls

The public demo service treats every client as hostile. It will enforce:

- random, isolated scenario namespaces
- beryl's reserved-topic protection
- an allow-list containing only the documentation origin and approved local
  development origins
- frame and payload size limits
- node-wide, per-IP, and per-socket connection limits
- join and message rate limits
- short idle and absolute session expiry
- cleanup on disconnect and expiry

Logs may include scenario identifiers, connection state, limit decisions, and
error categories. Logs must not include message payloads or user-entered
content.

## Accessibility and Progressive Enhancement

Every component must:

- support keyboard operation
- expose connection and error changes to assistive technology
- respect reduced-motion preferences
- preserve readable static documentation without JavaScript
- avoid relying on color alone
- keep controls usable at narrow viewport widths

Interactive diagrams will provide equivalent textual explanations in the
surrounding Markdown.

## Testing

### Lustre client

Pure Gleam tests will cover model transitions, scenario state machines,
compatibility checks, bounded reconnects, and URL-state encoding.

Browser tests will cover:

- Astro host and custom-element mounting
- keyboard operation
- static fallback
- connection loss and recovery
- incompatible client and service versions
- representative mobile layouts

### Demo server

Integration tests will exercise joins, messages, limits, expiry, and cleanup
through beryl's coordinator path. Tests will use exact mailbox message shapes
and unique topics.

### Build contracts

Tests will verify:

- generated API JSON schema and version
- links from API explorer entries to canonical pages
- component and service compatibility metadata
- absence of interactive bundles on pages that do not use them

### Future shell migration

A parity crawl will compare the Starlight and Lustre builds for URLs, redirects,
titles, descriptions, canonical links, headings, code blocks, diagrams, search
coverage, sitemap entries, LLM files, analytics, and accessibility checks.

## Delivery Sequence

### Stage 1: Presence vertical slice

Build:

- the nested Lustre client project
- the Astro custom-element host
- the shared event transcript
- one presence lab on `/examples/`
- the minimal hardened demo server
- client, server, browser, and contract tests

This stage proves the complete path from Markdown to Lustre to Phoenix wire to
beryl and Mist.

### Stage 2: Interactive documentation platform

Add the remaining labs, architecture visualizers, guided playgrounds, and API
explorer. Extract shared component primitives only after two components need
them.

### Stage 3: Parallel Lustre shell

Build a non-production `lustre_ssg` renderer that consumes normalized content
and route manifests. The normalized content model must represent frontmatter,
callouts, code blocks, Mermaid diagrams, and the three existing MDX pages.
Keep Starlight in production while closing the parity checklist.

### Stage 4: Optional cutover

Replace Starlight only when the parallel build reaches parity and the custom
shell provides enough product value to justify its maintenance. Continue
serving static output unless same-origin server features require a separate
full-stack design.

## Cutover Criteria

A full Lustre shell may replace Starlight only when it preserves:

- every canonical URL and redirect
- Markdown and generated API content
- navigation and tables of contents
- syntax highlighting and Mermaid diagrams
- search quality
- metadata, social cards, sitemap, and LLM files
- privacy-preserving analytics
- edit links and last-updated information
- static hosting and deploy previews
- accessibility and responsive behavior
- build reliability and acceptable build time

The migration must also remove enough Starlight-specific code or unlock enough
new capability to offset the maintenance cost of the replacement.

## Risks

### Rebuilding documentation infrastructure

A full rewrite can spend substantial effort reproducing mature Starlight
features. The hybrid stage avoids that cost, and the parity gate prevents a
premature cutover.

### Demo service abuse

A public realtime service can attract abusive traffic. Strict limits, isolated
sessions, expiry, origin checks, and payload-free logs reduce the risk.

### Client and service drift

Independent deployments can produce incompatible versions. The explicit
compatibility contract disables live execution before a protocol mismatch
causes confusing behavior.

### Scope growth

An arbitrary-code playground or broad site rewrite could consume the project.
The presence-only first slice and separate compiler-playground design keep the
initial work bounded.

## Decision

Proceed with the hybrid migration path. Implement one presence lab before
building additional experiences. Keep Starlight in production until a parallel
Lustre static build passes the documented parity gate.

## References

- [Lustre documentation](https://lustre.hexdocs.pm/)
- [Lustre server-side rendering guide](https://lustre.hexdocs.pm/guide/05-server-side-rendering.html)
- [Lustre full-stack applications guide](https://lustre.hexdocs.pm/guide/06-full-stack-applications.html)
- [`lustre_ssg` documentation](https://lustre-ssg.hexdocs.pm/)
