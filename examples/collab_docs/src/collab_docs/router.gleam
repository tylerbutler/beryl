import beryl
import collab_docs/auth
import collab_docs/doc_store.{type Store}
import example_helpers/static
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import mist.{type Connection, type ResponseData}

/// Tenant the demo will issue tokens for. In a real app this comes from
/// a session, IdP claim, or other auth context.
const demo_tenant = "demo"

pub type Context {
  Context(
    channels: beryl.Sockets,
    store: Store,
    secret: BitArray,
    base_path: String,
  )
}

pub fn handle_request(
  req: Request(Connection),
  context: Context,
) -> Response(ResponseData) {
  use <- static.serve_app_static(
    req,
    under: context.base_path <> "/static",
    app: "collab_docs",
  )

  case static.match_prefix(req, context.base_path) {
    Ok([]) -> index_page(context)
    _ -> static.not_found()
  }
}

fn index_page(context: Context) -> Response(ResponseData) {
  let token = auth.sign_tenant(demo_tenant, context.secret)
  let base = context.base_path
  let html = "<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <meta name=\"beryl-tenant\" content=\"" <> demo_tenant <> "\">
  <meta name=\"beryl-tenant-token\" content=\"" <> token <> "\">
  <title>Collaborative CRDT Docs — beryl demo</title>
  <link rel=\"stylesheet\" href=\"" <> base <> "/static/style.css\">
</head>
<body>
  <main id=\"app\">
    <header>
      <h1>Collaborative CRDT Docs</h1>
      <p>Type-safe realtime document state powered by beryl.</p>
    </header>
    <section id=\"toolbar\">
      <button id=\"add-todo\" type=\"button\">Add todo</button>
      <button id=\"add-note\" type=\"button\">Add note</button>
      <span id=\"status\">Connecting…</span>
    </section>
    <section id=\"blocks\" aria-live=\"polite\"></section>
  </main>
  <script src=\"https://unpkg.com/phoenix@1.7.20/priv/static/phoenix.js\" integrity=\"sha384-9Rsr2KoQMtWNQakugNsDiGsZ/5eQnJHeBhiocJMdHvnyN8ifwcytSTzPpb1xydYk\" crossorigin=\"anonymous\"></script>
  <script type=\"module\" src=\"" <> base <> "/static/app.js\"></script>
</body>
</html>"

  static.html_response(html)
}
