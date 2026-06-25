---
title: beryl/topic
description: Topic - Pattern matching for channel routing
---

Topic - Pattern matching for channel routing

 Topics are string identifiers that clients join (e.g., "room:lobby").
 Patterns define how topics are routed to channel handlers. Patterns can be
 exact, legacy trailing prefix wildcards, or segment-aware wildcards where
 "*" occupies a complete colon-delimited segment.

## Types

### `ExtractError`

Errors from extracting wildcard values from a topic pattern.

```gleam
pub type ExtractError {
  NoWildcard
  TopicMismatch
  ExpectedOneWildcard(Int)
  EmptyNamespace
}
```

#### Constructors

##### `NoWildcard`

The pattern has no wildcard to extract.

##### `TopicMismatch`

The topic does not match the pattern.

##### `ExpectedOneWildcard(Int)`

`extract_id` expected exactly one wildcard value but found this many.

##### `EmptyNamespace`

`namespace` was called with an empty topic.

### `TopicError`

```gleam
pub type TopicError {
  EmptyTopic
  InvalidFormat(String)
}
```

### `TopicPattern`

Topic pattern for routing

```gleam
pub type TopicPattern {
  Exact(String)
  Wildcard(prefix: String)
  SegmentWildcard(segments: List(String))
}
```

#### Constructors

##### `Exact(String)`

Exact match: "room:lobby" only matches "room:lobby"

##### `Wildcard(prefix: String)`

Wildcard suffix: "room:*" matches "room:lobby", "room:123", etc.

##### `SegmentWildcard(segments: List(String))`

Segment wildcard: "document:*:ops" matches the same number of ":"
 segments where "*" occupies one complete segment.

## Functions

### `extract_id`

Extract the wildcard portion from a topic

 ## Examples

 ```gleam
 extract_id(Wildcard("room:"), "room:lobby") // -> Ok("lobby")
 extract_id(Wildcard("doc:"), "doc:abc:123") // -> Ok("abc:123")
 extract_id(SegmentWildcard(["doc", "*", "ops"]), "doc:abc:ops") // -> Ok("abc")
 extract_id(Exact("room:lobby"), "room:lobby") // -> Error(NoWildcard)
 ```

```gleam
pub fn extract_id(
  TopicPattern,
  String
) -> Result(String, ExtractError)
```

### `extract_wildcards`

Extract values captured by wildcard segments.

 For legacy prefix wildcards, returns the suffix as a single value.
 For segment wildcards, returns each topic segment matched by "*".

 ## Examples

 ```gleam
 extract_wildcards(parse_pattern("document:*:*"), "document:tenant-a:doc-42")
 // -> Ok(["tenant-a", "doc-42"])
 ```

```gleam
pub fn extract_wildcards(
  TopicPattern,
  String
) -> Result(List(String), ExtractError)
```

### `from_segments`

Build a topic from segments

 ## Examples

 ```gleam
 from_segments(["room", "lobby"]) // -> "room:lobby"
 from_segments(["doc", "tenant", "123"]) // -> "doc:tenant:123"
 ```

```gleam
pub fn from_segments(List(String)) -> String
```

### `matches`

Check if a topic matches a pattern

 ## Examples

 ```gleam
 matches(Wildcard("room:"), "room:lobby") // -> True
 matches(Wildcard("room:"), "user:123") // -> False
 matches(Exact("room:lobby"), "room:lobby") // -> True
 matches(Exact("room:lobby"), "room:other") // -> False
 matches(parse_pattern("document:*:ops"), "document:tenant-a:ops") // -> True
 matches(parse_pattern("document:*:ops"), "document:tenant-a:view") // -> False
 ```

```gleam
pub fn matches(
  TopicPattern,
  String
) -> Bool
```

### `namespace`

Get the first segment (namespace) of a topic

 ## Examples

 ```gleam
 namespace("room:lobby") // -> Ok("room")
 namespace("") // -> Error(EmptyNamespace)
 ```

```gleam
pub fn namespace(String) -> Result(String, ExtractError)
```

### `parse_pattern`

Parse a pattern string into TopicPattern

 ## Examples

 ```gleam
 parse_pattern("room:*") // -> Wildcard("room:")
 parse_pattern("room:lobby") // -> Exact("room:lobby")
 parse_pattern("document:*:ops") // -> SegmentWildcard(["document", "*", "ops"])
 parse_pattern("document:*:*") // -> SegmentWildcard(["document", "*", "*"])
 parse_pattern("document:tenant-a:*") // -> Wildcard("document:tenant-a:")
 ```

```gleam
pub fn parse_pattern(String) -> TopicPattern
```

### `segments`

Parse a topic into segments by splitting on ":"

 ## Examples

 ```gleam
 segments("room:lobby") // -> ["room", "lobby"]
 segments("doc:tenant:123:ops") // -> ["doc", "tenant", "123", "ops"]
 ```

```gleam
pub fn segments(String) -> List(String)
```

### `validate`

Validate a topic string

 Topics must:
 - Not be empty
 - Not contain control characters
 - Not start or end with ":"

```gleam
pub fn validate(String) -> Result(String, TopicError)
```
