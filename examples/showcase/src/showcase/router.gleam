//// Top-level HTTP router for the showcase deployment. Dispatches by the
//// first path segment to the bundled cursors / chatrooms / collab_docs
//// routers, each pinned to its own URL prefix.

import beryl_demo/config as demo_config
import beryl_demo/router as demo_router
import chatroom/router as chatroom_router
import collab_document/router as document_router
import cursor/router as cursor_router
import example_helper/static
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import mist.{type Connection, type ResponseData}

pub type Context {
  Context(
    /// Status endpoint for the documentation site's presence lab.
    demo: demo_config.Config,
    cursor: cursor_router.Context,
    chatroom: chatroom_router.Context,
    collab_document: document_router.Context,
  )
}

pub fn handle_request(
  http_request: Request(Connection),
  context: Context,
) -> Response(ResponseData) {
  case request.path_segments(http_request) {
    [] -> landing_page()
    ["healthz"] -> healthz()
    ["v1", ..] -> demo_router.handle_request(http_request, context.demo)
    ["cursors", ..] ->
      cursor_router.handle_request(http_request, context.cursor)
    ["chat", ..] ->
      chatroom_router.handle_request(http_request, context.chatroom)
    // TODO: re-enable the collab_docs demo. The handler is still
    // registered in showcase.main so reinstating the route + landing
    // card is a one-line change.
    // ["docs", ..] ->
    //   document_router.handle_request(http_request, context.collab_document)
    _ -> static.not_found()
  }
}

fn healthz() -> Response(ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
}

fn landing_page() -> Response(ResponseData) {
  let html =
    "<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>beryl — realtime examples</title>
  <style>
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, sans-serif;
      background: #0f172a;
      color: #e2e8f0;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
    }
    header {
      padding: 4rem 2rem 2rem;
      text-align: center;
    }
    header h1 { font-size: 2.5rem; margin: 0 0 0.5rem; letter-spacing: -0.02em; }
    header p { margin: 0; color: #94a3b8; font-size: 1.1rem; }
    main {
      flex: 1;
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      gap: 1.5rem;
      max-width: 1100px;
      width: 100%;
      margin: 0 auto;
      padding: 1rem 2rem 3rem;
    }
    .card {
      background: #1e293b;
      border: 1px solid #334155;
      border-radius: 12px;
      padding: 1.75rem;
      text-decoration: none;
      color: inherit;
      transition: transform 0.15s ease, border-color 0.15s ease;
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
    }
    .card:hover { transform: translateY(-2px); border-color: #6366f1; }
    .card .emoji { font-size: 2rem; }
    .card h2 { margin: 0; font-size: 1.25rem; }
    .card p { margin: 0; color: #94a3b8; font-size: 0.95rem; line-height: 1.5; }
    footer {
      padding: 2rem;
      text-align: center;
      color: #64748b;
      font-size: 0.9rem;
    }
    footer a { color: #818cf8; text-decoration: none; }
    footer a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <header>
    <h1>beryl examples</h1>
    <p>Type-safe realtime channels and presence for Gleam, running on the BEAM.</p>
  </header>
  <main>
    <a class=\"card\" href=\"/cursors\">
      <span class=\"emoji\">🖱️</span>
      <h2>Collaborative cursors</h2>
      <p>Move your mouse and watch every other tab see it. Presence + low-latency broadcast.</p>
    </a>
    <a class=\"card\" href=\"/chat\">
      <span class=\"emoji\">💬</span>
      <h2>Chat rooms</h2>
      <p>Multi-room chat with typing indicators, presence sidebar, and named groups.</p>
    </a>
  </main>
  <footer>
    Powered by <a href=\"https://github.com/tylerbutler/beryl\">beryl</a>
  </footer>
</body>
</html>"

  static.html_response(html)
}
