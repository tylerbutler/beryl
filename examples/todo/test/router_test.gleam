import gleam/string
import gleeunit/should
import todo_server/router

pub fn index_loads_the_built_lustre_assets_test() {
  let html = router.index_html()

  string.contains(html, "/static/style.css")
  |> should.be_true
  string.contains(html, "/static/todo_client.js")
  |> should.be_true
  string.contains(html, "<main id=\"app\"></main>")
  |> should.be_true
}
