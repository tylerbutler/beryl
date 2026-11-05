# Phoenix framing adapter

## Overview

This adapter maps Roost Phoenix framing to the local portable host boundary.
Roost owns the wire codec.

## Interface

- `phoenix.gleam:Inbound` carries optional references, topic, event, and payload.
- `phoenix.gleam:decode`, `encode`, and `reply` expose framing and reply creation.

## Invariants

- `phoenix.gleam:decode` accepts client `Push` frames; binary payloads become
  bit arrays.

## Side effects

None. These functions transform frames and values.

## Verification

From the repository root:
`cd examples/portable_channels && gleam build --target javascript --warnings-as-errors`.
