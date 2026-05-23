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
# Pin the build stage to the same Erlang/OTP version as the runtime stage so
# the generated .beam files load cleanly. The upstream
# `ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine` image ships OTP 28, whose
# atom-table encoding cannot be loaded by OTP 27 ("corrupt atom table" →
# `cursors@@main:run/1` undef at boot). Building Gleam on top of the same
# erlang:27.2.1-alpine base we use at runtime avoids that mismatch.
FROM erlang:27.2.1-alpine AS build

ARG GLEAM_VERSION=v1.16.0

# git is required by `gleam deps download`; rebar3 is required to compile
# Erlang/OTP dependencies (e.g. hpack, gramps).
RUN apk add --no-cache git rebar3 curl ca-certificates \
 && case "$(uname -m)" in \
      aarch64) GLEAM_ARCH=aarch64-unknown-linux-musl ;; \
      x86_64)  GLEAM_ARCH=x86_64-unknown-linux-musl ;; \
      *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/${GLEAM_VERSION}/gleam-${GLEAM_VERSION}-${GLEAM_ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin gleam \
 && gleam --version

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
