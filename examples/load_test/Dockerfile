FROM erlang:27.2.1-alpine AS build
ARG GLEAM_VERSION=v1.16.0
ARG SERVER=mist
RUN apk add --no-cache git rebar3 curl ca-certificates \
 && case "$(uname -m)" in \
      aarch64) GLEAM_ARCH=aarch64-unknown-linux-musl ;; \
      x86_64) GLEAM_ARCH=x86_64-unknown-linux-musl ;; \
      *) exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/${GLEAM_VERSION}/gleam-${GLEAM_VERSION}-${GLEAM_ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin gleam
WORKDIR /src
COPY . .
WORKDIR /src/examples/load_test
RUN gleam deps download \
 && test "$SERVER" = "mist" -o "$SERVER" = "ewe" \
 && gleam export erlang-shipment

FROM erlang:27.2.1-alpine
ARG SERVER=mist
RUN apk add --no-cache libstdc++ ncurses-libs openssl ca-certificates
WORKDIR /app
COPY --from=build /src/examples/load_test/build/erlang-shipment ./
ENV BIND_ADDRESS=0.0.0.0 PORT=8000 SERVER=$SERVER
EXPOSE 8000
CMD ["./entrypoint.sh", "run"]
