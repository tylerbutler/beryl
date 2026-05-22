# Build stage: compile Gleam project to an erlang-shipment release.
# Build context MUST be the repository root because the example references
# the local beryl package via `path = "../.."`.
FROM ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine AS build

WORKDIR /src

# Copy the entire repo so path-based deps resolve.
COPY . .

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
