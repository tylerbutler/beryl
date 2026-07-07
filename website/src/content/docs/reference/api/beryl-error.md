---
title: beryl/error
description: Shared Beryl-owned error helpers.
---

Shared Beryl-owned error helpers.

## Types

### `StartFailure`

A stable description of an internal Beryl actor startup failure.

 This type hides OTP's `actor.StartError` so public APIs do not expose
 dependency-specific error constructors.

```gleam
pub type StartFailure
```

## Functions

### `describe_start_failure`

Convert a startup failure to a human-readable diagnostic string.

```gleam
pub fn describe_start_failure(StartFailure) -> String
```

### `from_actor_start_error`

Convert a `gleam/otp/actor.StartError` into beryl's `StartFailure`.

```gleam
pub fn from_actor_start_error(actor.StartError) -> StartFailure
```
