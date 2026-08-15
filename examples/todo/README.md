# Lustre Todo

A standalone browser-only Todo app built with Gleam and Lustre. It has no Beryl,
Phoenix, Mist, or Erlang server code. Todos are stored in the browser's
`localStorage`.

## Run locally

From `examples/todo`:

```sh
pnpm dev
```

Open <http://localhost:8011>.

## Build

```sh
pnpm build
```

Lustre writes the production site to `client/priv/static/`. The generated output
is ignored by Git.

## Test

```sh
cd client
gleam test
cd ..
pnpm test
```

The Playwright suite starts the Lustre development server automatically.
