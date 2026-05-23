# Build stage: compile the showcase Gleam project (which bundles all three
# examples) to an erlang-shipment release.
#
# IMPORTANT: Build context MUST be the repository root, because the showcase
# project references local packages via `path = "../.."` and `path = "../*"`.
#
# Build from the repo root with:
#   docker build -f examples/showcase/Dockerfile -t beryl-showcase .
#
# Running `docker build .` from inside examples/showcase/ will fail to
# resolve the local path dependencies.
FROM ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine AS build

# git is required by `gleam deps download` for resolving dependencies.
RUN apk add --no-cache git

WORKDIR /src

# Copy the entire repo so path-based deps resolve. Verify the parent beryl
# package is present; fail fast with a clear message if the build context
# is wrong (e.g. someone ran `docker build .` from examples/showcase/).
COPY . .
RUN test -f /src/gleam.toml && grep -q '^name = "beryl"' /src/gleam.toml || ( \
  echo "ERROR: build context does not contain the beryl repository root."; \
  echo "Run from the repo root: docker build -f examples/showcase/Dockerfile ."; \
  exit 1 \
)

WORKDIR /src/examples/showcase
RUN gleam deps download \
 && gleam export erlang-shipment

# Runtime stage: minimal Erlang image running the shipment.
# OTP must match the build image (Gleam v1.16.0-erlang-alpine ships OTP 28);
# mismatched OTP between build and runtime corrupts .beam atom tables.
FROM erlang:28-alpine AS runtime

RUN apk add --no-cache libstdc++ ncurses-libs openssl ca-certificates

WORKDIR /app
COPY --from=build /src/examples/showcase/build/erlang-shipment ./

# Railway injects PORT; bind to all interfaces so the proxy can reach us.
ENV BIND_ADDRESS=0.0.0.0
EXPOSE 8000

CMD ["./entrypoint.sh", "run"]
