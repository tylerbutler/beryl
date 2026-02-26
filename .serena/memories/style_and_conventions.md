# Style and Conventions

## Language Conventions (Gleam)
- Use **Result types** over exceptions for error handling
- Use **exhaustive pattern matching** everywhere
- Follow `gleam format` output exactly
- Keep public API minimal
- Document public functions with `///` comments
- Module-level docs use `////` comments

## Naming
- snake_case for functions and variables (Gleam standard)
- PascalCase for types and constructors (Gleam standard)
- Descriptive module names reflecting their role

## Code Style
- Builder pattern for complex type construction (e.g. `channel.new()` + `with_handle_in()`)
- Type erasure via FFI for heterogeneous collections
- OTP actors for stateful components
- Functional patterns with immutable data

## Project Conventions
- **Package manager**: Not applicable (Gleam uses `gleam deps`)
- **Tool versions**: Defined in `.tool-versions` (erlang 27.2.1, gleam 1.14.0, just 1.38.0)
- **Local dev**: Can use `.mise.toml` for flexible versions
- **CI**: Uses `just ci` which runs format-check, check, test, build-strict

## Git
- Conventional commits: `type(scope): description`
- Keep commit messages brief
- Include commit bodies with brief details
