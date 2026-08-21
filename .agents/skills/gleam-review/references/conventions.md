# Gleam Conventions, Patterns, and Anti-patterns

> Source: https://gleam.run/documentation/conventions-patterns-and-anti-patterns/
> (retrieved 2026-07-23). Content lightly reformatted; substance unchanged.

Conventions and anti-patterns are rules that should be adhered to always, while
patterns are to be applied whenever the programmer thinks it would benefit
their code.

## Table of Contents

- [Conventions](#conventions) — always follow
  - Avoid unqualified importing of functions and constants
  - Annotate all module functions
  - Use result for fallible functions
  - Use singular for module names
  - Treat acronyms as single words
  - Conventional conversion function naming
  - Conventional fallible function naming
  - Use the core libraries
  - Keep development tool config in gleam.toml
  - Use the correct source code directory
- [Patterns](#patterns) — apply when beneficial
  - Design descriptive errors
  - Comment liberally
  - Make invalid states impossible
  - Replace bools with custom types
  - The sans-io pattern
  - The builder pattern
- [Anti-patterns](#anti-patterns) — always avoid
  - Abbreviations
  - Fragmented modules
  - Panicking in libraries
  - Global namespace pollution
  - Namespace trespassing
  - Grouping by design pattern
  - Check-then-assert
  - Using dynamic with FFI
  - Match all variants
  - Category theory overuse

## Conventions

Gleam enforces `snake_case` for variables, constants, and functions, and
`PascalCase` for types and variants.

### Avoid unqualified importing of functions and constants

Always use the qualified syntax for functions and constants defined in other
modules.

```gleam
// Good
import gleam/list
import gleam/string

pub fn reverse(input: String) -> String {
  input
  |> string.to_graphemes
  |> list.reverse
  |> string.concat
}

// Bad
import gleam/list.{reverse}
import gleam/string.{to_graphemes, concat}

pub fn reverse(input: String) -> String {
  input
  |> to_graphemes
  |> reverse
  |> concat
}
```

Types and record constructors may be used with the unqualified syntax,
providing you think it does not make the code more difficult to read.

### Annotate all module functions

All module functions should have annotations for their argument types and for
their return type.

```gleam
// Good
fn calculate_total(amounts: List(Int), service_charge: Int) -> Int {
  int.sum(amounts) * service_charge
}

// Bad
fn calculate_total(amounts, service_charge) {
  int.sum(amounts) * service_charge
}

// Bad: missing return annotation
fn calculate_total(amounts: List(Int), service_charge: Int) {
  int.sum(amounts) * service_charge
}
```

### Use result for fallible functions

All functions that can succeed or fail should return a result in Gleam.

Some languages use both the result and the option type for fallible functions,
but Gleam does not. Using results always makes code consistent and removes the
boilerplate that would otherwise be required to convert between result and
option. If there is no extra information to return for failure then the result
error type can be `Nil`.

Panics are not used for fallible functions, especially within libraries.
Panicking may be appropriate at the top level of application code, handling the
result returned by fallible functions.

```gleam
// Good
pub fn first(list: List(a)) -> Result(a, Nil) {
  case list {
    [item, ..] -> Ok(item)
    _ -> Error(Nil)
  }
}

// Bad: returns an option
pub fn first(list: List(a)) -> option.Option(a) {
  case list {
    [item, ..] -> option.Some(item)
    _ -> option.None
  }
}

// Bad: panics on failure
pub fn first(list: List(a)) -> a {
  case list {
    [item, ..] -> item
    _ -> panic as "cannot get first of empty list"
  }
}
```

### Use singular for module names

Module names are singular, not plural.

```gleam
// Good
import app/user

// Bad
import app/users
```

This applies to all segments, not just the final one.

```gleam
// Good
import app/payment/invoice

// Bad
import app/payments/invoice
```

### Treat acronyms as single words

Acronyms are always written as if they were a single word.

```gleam
// Good
let json: Json = build_json()

// Bad
let j_s_o_n: JSON = build_j_s_o_n()
```

It may be tempting to ignore this convention and use the name `JSON`, but this
will result in the BEAM code generated from the Gleam code using the name
`j_s_o_n`.

### Conventional conversion function naming

When naming a function that converts from one type to another, use the
convention `x_to_y`.

```gleam
// Good
pub fn json_to_string(data: Json) -> String

// Bad
pub fn json_into_string(data: Json) -> String
pub fn json_as_string(data: Json) -> String
pub fn string_of_json(data: Json) -> String
```

If the module name matches the type name then do not repeat the name of the
type at the start of the function.

```gleam
// In src/my_app/identifier.gleam

// Good
pub fn to_string(id: Identifier) -> String

// Bad
pub fn identifier_to_string(id: Identifier) -> String
```

Functions are used with a module qualifier, so the name of the module clarifies
what the input value is:

```gleam
import my_app/identifier.{type Identifier}

pub fn run(id: Identifier) -> String {
  identifier.to_string(id)
}
```

If there is a name for the encoding, format, or variant used in the conversion
function, then use that in the name of the function.

```gleam
// Good
pub fn date_to_rfc3339(date: Date) -> String

// Bad
pub fn date_to_string(date: Date) -> String
```

If there is a more descriptive name for the conversion operation then use that
instead.

```gleam
// Good
pub fn round(data: Float) -> Int

// Bad
pub fn float_to_int(data: Float) -> Int
```

### Conventional fallible function naming

Functions that return results should be given a name that is appropriate for
the domain and the operation they perform.

```gleam
// Good
pub fn parse_json(input: String) -> Result(Json, ParseError)
pub fn enqueue(job: BackgroundJob) -> Result(Nil, EnqueueError)
```

If the function is a special result-handling version of an existing function
that returns early when there is an error, then the `try_` prefix can be used,
so long as there is not a more appropriate domain-specific name. Names based on
design patterns or abstract concepts should be avoided.

```gleam
pub fn map(list: List(a), f: fn(a) -> b) -> List(b)

// Good
pub fn try_map(
  list: List(a),
  f: fn(a) -> Result(b, e),
) -> Result(List(b), e)

// Bad
pub fn monadic_bind(
  list: List(a),
  f: fn(a) -> Result(b, e),
) -> Result(List(b), e)
```

### Use the core libraries

The Gleam core team maintain several packages that are to be used as a shared
foundation for other Gleam libraries and applications:
`gleam_stdlib`, `gleam_time`, `gleam_json`, `gleam_http`, `gleam_erlang`,
`gleam_otp`, `gleam_javascript`.

This shared foundation makes it easier for related Gleam packages to work
together, and helps avoid common problems that the design of the packages
guard against.

Do not replicate functionality provided by these packages. e.g. Do not create a
new time type instead of using `gleam_time`'s `Timestamp`.

### Keep development tool config in `gleam.toml`

If additional development tools (a security scanner, a licence compliance
checker, etc.) are configured via a file, that file should be `gleam.toml`,
with configuration going under the `tools.$TOOL_NAME` key prefix.

```toml
name = "thingy"
version = "1.0.0"

[dependencies]
gleam_stdlib = ">= 1.0.0 and < 2.0.0"

[tools.lustre.dev]
host = "0.0.0.0"

[tools.lustre.build]
minify = true
outdir = "../server/priv/static"
```

Do not use dedicated configuration files such as `my-tool.toml`, or
`config/my-tool.yaml`. Dynamic configuration can be read from environment
variables or provided as command line arguments.

### Use the correct source code directory

Gleam's build tool offers 3 directories for source code, each with a different
purpose:

- `src` is for code to be included in the application or library itself. Code
  here can import modules from `dependencies` and `src/`, but not
  `dev_dependencies`, `dev/`, or `test/`.
- `test` is for code that tests the package, such as automated unit and
  integration tests. Code here can import modules from any dependencies and
  any directory.
- `dev` is for any additional code used in development, such as code
  generators and helper scripts. Code here can import modules from any
  dependencies and any directory.

## Patterns

### Design descriptive errors

When creating an error type, design the variants to describe what the error
was in terms of your business domain. Each variant should hold additional
information about the error instance, to aid debugging or with creation of
helpful error messages.

If the error was caused by a lower-level error, e.g. being unable to load
application data due to failing to read a file, then that lower error can be
one of the fields of the higher error.

```gleam
// Good
pub type NoteBookError {
  NoteAlreadyExists(path: String)
  NoteCouldNotBeCreated(path: String, reason: simplifile.FileError)
  NoteCouldNotBeRead(path: String, reason: simplifile.FileError)
  NoteInvalidFrontmatter(path: String, reason: tom.ParseError)
}

// Bad: not enough detail
pub type NotesError {
  NoteAlreadyExists
  NoteCouldNotBeCreated
  NoteCouldNotBeRead
  NoteInvalidFrontmatter
}

// Bad: designed around dependencies, not business domain
pub type NotesError {
  FileError(path: String, reason: simplifile.FileError)
  TomlError(path: String, reason: tom.ParseError)
}
```

### Comment liberally

Comments can explain both what the code does as well as why the code does what
it does. Often the reader could determine the what without the aid of the
comment, but that may not be the case for unfamiliar readers, or if the code
is later determined to have a bug, so what it does and what the writer
intended it to do do not match.

Adding comments does not mean the code itself can be written in an unclear
way, and having well written code doesn't mean that comments are not a
valuable addition.

### Make invalid states impossible

Gleam's type system and custom types enable precise domain modelling. Type
definitions that sufficiently encode the business rules make it impossible to
construct invalid data, removing many types of bugs and turning the type
definitions into documentation for the business logic.

```gleam
// Bad: a guest visitor with only an email, or only an id, can be constructed
pub type Visitor {
  Visitor(id: Option(Int), email: Option(String))
}

// Good: invalid combinations cannot exist
pub type Visitor {
  LoggedInUser(id: Int, email: String)
  Guest
}
```

### Replace bools with custom types

Drawbacks of `Bool` for domain data:

- `Bool`, `True`, and `False` have no meaning without context, making it
  easier to misunderstand what values represent.
- The bool type will be used for many unrelated pieces of data, so it is
  possible to mistake one bool value for another without a type error to
  prevent the mistake.
- If a third state is required in future then bool can no longer be used, and
  a larger refactoring will be needed. A second bool results in 4 states, a
  third in 8; combinations of bools are especially unclear.

```gleam
// Bad
pub type SchoolPerson {
  SchoolPerson(name: String, is_student: Bool)
}

// Good
pub type SchoolPerson {
  SchoolPerson(name: String, role: Role)
}

pub type Role {
  Student
  Teacher
}
```

### The sans-io pattern

Design API clients, SDKs, and similar packages so that they do not depend on
any particular HTTP client — the user is responsible for sending requests.
This lets the library work on any target, inside any framework, and lets users
add rate limiting, retries, etc.

Structure the code so each API action has a pair of functions: one that
constructs a HTTP request, and another that takes a HTTP response and returns
the resulting data.

```gleam
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}

/// Construct a request for the create-user endpoint.
pub fn create_user_request(name: String) -> Request(String) {
  request.new()
  |> request.set_method(Post)
  |> request.set_host("example.com")
  |> request.set_body(json.to_string(json.object([#("name", name)])))
  |> request.prepend_header("accept", "application/json")
  |> request.prepend_header("content-type", "application/json")
}

/// Parse a response from the create-user endpoint.
pub fn create_user_response(response: Response(String)) -> Result(User, ApiError) {
  case response.status {
    201 -> Ok(User(name: response.body))
    409 -> Error(UserNameAlreadyInUse)
    429 -> Error(RateLimitWasHit)
    code -> Error(GotUnexpectedResponse(code, response.body))
  }
}
```

Note: this is not the same as taking a HTTP-sending function as an argument —
that design limits which clients can be used and cannot work on both the
Erlang and JavaScript targets (one uses promises, the other does not).

### The builder pattern

A flexible way to create records with multiple optional fields, often used for
configuration.

```gleam
// Usage
button.new(text: "Continue")
|> button.colour("green")
|> button.large
|> button.to_html
```

Required fields are taken as arguments by the function that starts the builder
pipeline; the remaining fields get default values.

```gleam
pub type Button {
  Button(text: String, colour: String, classes: Set(String))
}

pub fn new(text text: String) -> Button {
  Button(text:, colour: "pink", classes: set.new())
}

pub fn colour(button: Button, value: String) -> Button {
  Button(..button, colour: value)
}

pub fn large(button: Button) -> Button {
  let classes = button.classes |> set.delete("small") |> set.insert("large")
  Button(..button, classes:)
}
```

The builder type may be made opaque to force the builder functions to be used,
e.g. for validation or data-integrity reasons.

## Anti-patterns

### Abbreviations

Using shortened names can save a few keystrokes when typing, but they greatly
hinder code reading and understanding. Abbreviations are ambiguous, so the
reader has to guess what they are short for, and often they will get it wrong.
Always write names in full.

```gleam
// Bad
let cap = 5
let off = 0
let cnt = proc_dat(ss)

// Good
let capacity = 5
let offset = 0
let continuation = process_data(session)
```

### Fragmented modules

Do not prematurely split up modules into multiple smaller modules, and do not
view large modules as a problem. Instead focus on the business domain and
making the best API for the users of the code.

An API split over many modules is harder to understand and requires more
boilerplate to use than one well designed module, and it becomes more
challenging to hide internal implementation details when they have to be
exposed for other modules to use. The best APIs are small and focused.

Import cycles, or multiple modules needing to be imported to perform a simple
task, are signs that code has been split up that should be a single module.

```gleam
// Bad
import my_library/client
import my_library/config
import my_library/decode
import my_library/error
import my_library/parser
import my_library/types

// Good
import my_library
```

This anti-pattern is especially common with AI-generated code — pay extra
attention to this rule.

### Panicking in libraries

Libraries must not panic, so they should not use `panic` or `let assert`.

Panicking instead of returning a result takes control away from the users of
the library, preventing them from being able to handle errors. A library does
not know the context in which it is used, so it is impossible for the author
of a library to know if it is acceptable to panic, so they never can.

The one exception is libraries about OTP, the BEAM application framework: OTP
has non-local error handling through supervision trees, so there may be some
circumstances in which it is appropriate to panic, provided there is a
suitably designed supervision tree.

### Global namespace pollution

Gleam has a global module namespace. If two packages each define a module with
the same name then a project adding both packages as dependencies will fail to
compile. Packages should define their own namespace by placing their modules
within a uniquely named directory matching the package name.

```
# Good
src/
├── my_package.gleam
└── my_package/
    ├── distribution.gleam
    └── inventory.gleam

# Bad
src/
├── distribution.gleam
├── inventory.gleam
└── my_package.gleam
```

### Namespace trespassing

Never place modules within a top-level directory that belongs to a different
package (e.g. `src/lustre/`), even when making a package intended to be used
with that package. Trespassing can cause compilation errors due to module
collisions, and confusing code where it is unclear where modules come from.

### Grouping by design pattern

Design module boundaries around the business domain and the best API for the
users of the code — never around design patterns or abstract code constructs.

```gleam
// Bad: kind grouping
import app/constants
import app/functions
import app/types
import app/utilities

// Bad: category theory grouping
import app/functors
import app/monads

// Bad: design pattern grouping
import app/controllers/user_controller
import app/services/user_service
import app/views/user_view

// Good: business domain grouping
import app/stock
import app/billing
```

### Check-then-assert

Checking that a value is in some desired state and then acting on that
knowledge with an assertion is an anti-pattern in Gleam and should never be
done. Use pattern matching or functions such as `result.try` and `result.map`
instead — the type system then ensures there is no disconnect between the
checking and the using, and there can be performance benefits too.

```gleam
// Bad: check then assert
case result.is_ok(data) {
  True -> {
    let assert Ok(value) = data
    process(value)
  }
  False -> data
}

// Bad: check then assert with `use`
use <- bool.guard(when: result.is_error(data), return: data)
let assert Ok(value) = data
process(value)

// Good: pattern matching
case data {
  Ok(value) -> process(value)
  Error(e) -> Error(e)
}

// Good: combinators
data |> result.try(process)

// Good: combinators with `use`
use value <- result.try(value)
process(value)
```

### Using dynamic with FFI

When using code written in other languages, some arguments and return values
cannot be represented with the Gleam type system. Never use the
`gleam/dynamic` module's `Dynamic` type to represent these — it accepts any
value at all, which will cause runtime errors. Instead create a new type that
represents exactly the expected type.

```gleam
// Good
pub type Buffer

pub fn byte_size(data: Buffer) -> Int

// Bad
import gleam/dynamic.{type Dynamic}

pub fn byte_size(data: Dynamic) -> Int
```

### Match all variants

Gleam's exhaustiveness checking of case expressions ensures that when you
change your data model, all your code must be updated before it compiles
again. A final catch-all pattern disables this refactoring assistance for new
variants, making it easy to introduce bugs from old logic that is no longer
correct. Avoid catch-all patterns where possible.

```gleam
// Bad: assumes all other variants are teachers
case role {
  Student -> handle_student()
  _ -> handle_teacher()
}

// Good: cannot silently become incorrect
case role {
  Student -> handle_student()
  Teacher -> handle_teacher()
}
```

### Category theory overuse

Avoid creation of complex category theory based abstractions. Gleam does not
have the ergonomics to make these abstractions easy to work with, nor the
compiler and runtime optimisations required to erase the significant runtime
overhead they introduce. They also add high cognitive overhead, running
contrary to Gleam's simple, concrete, and approachable style.

Solve specific problems with specific solutions.

```gleam
// Bad: abstract style
pub fn sum(
  data: a,
  monoid: Monoid(a),
  catamorphism: Catamorphism(a, b),
) -> b {
  catamorphism.apply(data, monoid.empty, monoid.append)
}

// Good: concrete style
pub fn total_cost(costs: List(Int)) -> Int {
  int.sum(costs)
}
```
