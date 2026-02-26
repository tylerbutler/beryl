# Suggested Commands

## Development
| Command | Description |
|---------|-------------|
| `just build` / `gleam build` | Compile project |
| `just test` / `gleam test` | Run all tests |
| `just check` / `gleam check` | Type check without building |
| `just format` / `gleam format src test` | Format source code |
| `just format-check` | Check formatting without changes |
| `just docs` / `gleam docs build` | Build documentation |
| `just deps` / `gleam deps download` | Download dependencies |
| `just clean` | Remove build artifacts |
| `just ci` | Run all CI checks (format, check, test, build) |

## Build Variants
| Command | Description |
|---------|-------------|
| `just build-strict` / `gleam build --warnings-as-errors` | Build with warnings as errors |

## System Utilities (macOS / Darwin)
| Command | Description |
|---------|-------------|
| `fd` | File finder (preferred over `find`) |
| `sd` | Stream editor (preferred over `sed`) |
| `rg` | Ripgrep (preferred over `grep`) |
| `git` | Version control |

## Task Completion Checklist
After completing a task, run:
1. `just format` - Format code
2. `just check` - Type check
3. `just test` - Run tests
4. `just build-strict` - Build with warnings as errors
Or use `just ci` to run all of the above.
