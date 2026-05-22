# Build stage: compile Gleam project to an erlang-shipment release.
#
# IMPORTANT: Build context MUST be the repository root, because the example
# references the local beryl package via `path = "../.."`.
#
# Build from the repo root with:
#   docker build -f examples/cursors/Dockerfile -t beryl-cursors .
#
# Running `docker build .` from inside examples/cursors/ will fail to resolve
# the local beryl dependency.
FROM ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine AS build

# git is required by `gleam deps download` for resolving dependencies.
RUN apk add --no-cache git

WORKDIR /src

# Copy the entire repo so path-based deps resolve. Verify the parent beryl
# package is present; fail fast with a clear message if the build context
# is wrong (e.g. someone ran `docker build .` from examples/cursors/).
COPY . .
RUN test -f /src/gleam.toml && grep -q '^name = "beryl"' /src/gleam.toml || ( \
  echo "ERROR: build context does not contain the beryl repository root."; \
  echo "Run from the repo root: docker build -f examples/cursors/Dockerfile ."; \
  exit 1 \
)

WORKDIR /src/examples/cursors
RUN gleam deps download \
 && gleam export erlang-shipment

# Runtime stage: minimal Erlang image running the shipment.
FROM erlang:27.2.1-alpine AS runtime

RUN apk add --no-cache libstdc++ ncurses-libs openssl ca-certificates

WORKDIR /app
COPY --from=build /src/examples/cursors/build/erlang-shipment ./

# Railway injects PORT; bind to all interfaces so the proxy can reach us.
ENV BIND_ADDRESS=0.0.0.0
EXPOSE 8000

CMD ["./entrypoint.sh", "run"]
