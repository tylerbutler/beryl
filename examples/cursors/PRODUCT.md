# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Gleam developers evaluating or learning beryl's realtime collaboration
capabilities. They use the demo to see the library in action and inspect a
small, runnable implementation.

## Product Purpose

Demonstrate how beryl combines typed channel events, presence, PubSub, and a
WebSocket transport to build a realtime collaborative experience. Success
means developers can run the example quickly, understand the data flow, and
adapt the patterns in their own applications.

## Positioning

The demo is an executable reference for beryl's type-safe Gleam APIs rather
than a standalone collaboration product.

## Operating Context

Developers run the Gleam server locally or deploy its container, then open the
page in multiple browser tabs to exercise presence, cursor movement, and other
ephemeral room events.

## Capabilities and Constraints

- The browser uses vanilla JavaScript, CSS, and the Phoenix JavaScript client.
- The server uses beryl's app-side dispatch with the Mist transport.
- The example has no frontend build step and should remain dependency-light.
- Realtime events are ephemeral; the demo does not persist room history.

## Evidence on Hand

The repository contains the runnable application, Playwright coverage, a
Dockerfile, Railway deployment configuration, and developer documentation.
Future work must not invent production adoption claims or performance
benchmarks.

## Product Principles

- Teach through a working, inspectable example.
- Keep the realtime data flow explicit and type-safe.
- Prefer immediate interactions that make collaboration visible.
- Preserve a small dependency and operational footprint.

## Accessibility & Inclusion

Interactive controls must be keyboard accessible and expose meaningful
accessible names and state. Motion effects must retain a reduced-motion
alternative.
