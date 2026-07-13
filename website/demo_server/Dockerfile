FROM erlang:27.2.1-alpine AS build

ARG GLEAM_VERSION=v1.16.0

RUN apk add --no-cache git rebar3 curl ca-certificates \
 && case "$(uname -m)" in \
      aarch64) GLEAM_ARCH=aarch64-unknown-linux-musl ;; \
      x86_64)  GLEAM_ARCH=x86_64-unknown-linux-musl ;; \
      *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/${GLEAM_VERSION}/gleam-${GLEAM_VERSION}-${GLEAM_ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin gleam

WORKDIR /src
COPY . .
RUN test -f /src/gleam.toml && grep -q '^name = "beryl"' /src/gleam.toml

WORKDIR /src/website/demo_server
RUN gleam deps download \
 && gleam export erlang-shipment

FROM erlang:27.2.1-alpine AS runtime

RUN apk add --no-cache libstdc++ ncurses-libs openssl ca-certificates

WORKDIR /app
COPY --from=build /src/website/demo_server/build/erlang-shipment ./

ENV BIND_ADDRESS=0.0.0.0
ENV PORT=4100
EXPOSE 4100

CMD ["./entrypoint.sh", "run"]
