# Showcase channels

## Overview

This directory adapts the cursor demo to the channel API. `showcase.handlers`
mounts it alongside the chat and document handlers from the standalone packages.

## Interface

- `cursor.gleam:Context` and `channel` expose the cursor handler.

## Invariants

- `cursor.gleam:channel` accepts supported reactions with coordinates in
  the inclusive range 0–1.

## Side effects

- `cursor.gleam:channel` tracks presence and broadcasts cursor/reaction events.

## Verification

From the repository root: `cd examples/showcase && gleam build`.
Package behavior tests use `gleam test`; browser tests use `pnpm test`.
