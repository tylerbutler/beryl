# Build stage: compile the showcase Gleam project (which bundles all three
# examples) to an erlang-shipment release.
#
# IMPORTANT: Build context MUST be the repository root, because the showcase
# project references the local beryl packages via `path = "../../packages/..."`
# and the sibling examples via `path = "../*"`.
#
# Build from the repo root with:
#   docker build -f examples/showcase/Dockerfile -t beryl-showcase .
#
# Running `docker build .` from inside examples/showcase/ will fail to
# resolve the local path dependencies.
FROM erlang:28-alpine AS build
COPY --from=ghcr.io/gleam-lang/gleam:v1.19.2-erlang-alpine /bin/gleam /usr/local/bin/gleam

# Use the same OTP as the runtime stage to compile Erlang dependencies.
RUN apk add --no-cache git rebar3

WORKDIR /src

# Copy the entire repo so path-based deps resolve. Verify the beryl packages
# are present; fail fast with a clear message if the build context is wrong
# (e.g. someone ran `docker build .` from examples/showcase/).
COPY . .
RUN test -f /src/packages/beryl/gleam.toml && test -f /src/packages/beryl_ewe/gleam.toml || ( \
  echo "ERROR: build context does not contain the beryl repository root."; \
  echo "Run from the repo root: docker build -f examples/showcase/Dockerfile ."; \
  exit 1 \
)

WORKDIR /src/examples/showcase
RUN gleam deps download \
 && gleam export erlang-shipment

# Runtime stage: minimal Erlang image running the shipment.
FROM erlang:28-alpine AS runtime

RUN apk add --no-cache libstdc++ ncurses-libs openssl ca-certificates

WORKDIR /app
COPY --from=build /src/examples/showcase/build/erlang-shipment ./

# Bind to all interfaces so the hosting platform's proxy can reach us.
ENV BIND_ADDRESS=0.0.0.0
EXPOSE 8000

CMD ["./entrypoint.sh", "run"]
