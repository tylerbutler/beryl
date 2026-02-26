# Task Completion Checklist

When a coding task is completed, run the following in order:

1. **Format**: `just format` (or `gleam format src test`)
2. **Type check**: `just check` (or `gleam check`)
3. **Test**: `just test` (or `gleam test`)
4. **Strict build**: `just build-strict` (or `gleam build --warnings-as-errors`)

Shortcut: `just ci` runs all of the above.

## Before Committing
- Ensure all CI checks pass
- Use conventional commit format: `type(scope): description`
- Keep commit messages brief, include body with details
