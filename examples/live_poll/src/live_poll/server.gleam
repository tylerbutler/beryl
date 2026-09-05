import beryl
import beryl/transport/server
import beryl_mist as mist_transport
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/otp/static_supervisor
import gleam/otp/supervision
import mist

pub type HealthEndpoint {
  HealthEndpointEnabled
  HealthEndpointDisabled
}

pub type GuideChannel {
  GuideChannelEnabled
  GuideChannelDisabled
}

pub fn run(
  sockets: beryl.Sockets,
  child_specification: supervision.ChildSpecification(
    static_supervisor.Supervisor,
  ),
  title: String,
  port: Int,
  health_endpoint: HealthEndpoint,
  guide_channel: GuideChannel,
) -> Nil {
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(child_specification)
    |> static_supervisor.start()

  let assert Ok(_) =
    fn(http_request) {
      mist_transport.upgrade(
        http_request,
        sockets,
        server.default_config("/socket/websocket"),
        fn() {
          case request.path_segments(http_request), health_endpoint {
            ["healthz"], HealthEndpointEnabled -> text(200, "ok")
            ["healthz"], HealthEndpointDisabled -> text(404, "Not found")
            [], HealthEndpointEnabled | [], HealthEndpointDisabled ->
              html(guide_channel)
            [_, ..], HealthEndpointEnabled | [_, ..], HealthEndpointDisabled ->
              text(404, "Not found")
          }
        },
      )
    }
    |> mist.new
    |> mist.port(port)
    |> mist.start

  io.println(title)
  io.println("Open http://localhost:" <> int.to_string(port))
  process.sleep_forever()
}

fn text(status: Int, body: String) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn html(guide_channel: GuideChannel) -> response.Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(client_html(guide_channel))),
  )
}

fn client_html(guide_channel: GuideChannel) -> String {
  let guide_enabled = case guide_channel {
    GuideChannelEnabled -> "true"
    GuideChannelDisabled -> "false"
  }

  "<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
  <title>beryl live poll</title>
  <style>
    body{font:16px system-ui;max-width:42rem;margin:3rem auto;padding:0 1rem}
    fieldset{display:grid;gap:.75rem;border:1px solid #bbb;border-radius:.5rem;padding:1rem}
    label{display:grid;gap:.25rem}button,input{font:inherit;padding:.6rem}
    #counts{font-size:1.2rem}#status{min-height:1.5rem;color:#555}
  </style>
</head>
<body>
  <h1>Room-scoped live poll</h1>
  <p>Open this page in two tabs, join the same room, and vote.</p>
  <label>Room <input id=\"room\" value=\"demo\" pattern=\"[A-Za-z0-9_-]+\"></label>
  <p><button id=\"join\">Join poll</button></p>
  <fieldset disabled id=\"poll\">
    <legend id=\"question\">Poll</legend>
    <button data-vote=\"gleam\">Vote Gleam</button>
    <button data-vote=\"erlang\">Vote Erlang</button>
    <div id=\"counts\">Gleam 0 / Erlang 0</div>
    <button id=\"close\" type=\"button\">Close poll now</button>
  </fieldset>
  <p id=\"status\">Disconnected</p>
  <script src=\"https://unpkg.com/phoenix@1.7.20/priv/static/phoenix.js\"></script>
  <script>
    const q = s => document.querySelector(s)
    let socket, channel
    function render(state) {
      q('#question').textContent = state.question
      q('#counts').textContent = `Gleam ${state.gleam} / Erlang ${state.erlang}`
      q('#poll').disabled = !state.open
      q('#status').textContent = state.open ? 'Poll open' : 'Poll closed'
    }
    function push(event, payload = {}) {
      channel.push(event, payload)
        .receive('ok', render)
        .receive('error', error => q('#status').textContent = error.reason)
        .receive('timeout', () => q('#status').textContent = `${event} is not available in this checkpoint`)
    }
    q('#join').onclick = () => {
      if (socket) socket.disconnect()
      socket = new Phoenix.Socket('/socket')
      socket.connect()
      channel = socket.channel(`poll:${q('#room').value}`, {})
      channel.on('poll_state', render)
      channel.on('poll_closed', render)
      channel.join()
        .receive('ok', () => { q('#poll').disabled = false; push('get_state') })
        .receive('error', error => q('#status').textContent = JSON.stringify(error))
      if (" <> guide_enabled <> ") {
        const guide = socket.channel('guide', {})
        guide.on('tip', tip => q('#status').title = tip.text)
        guide.join()
      }
    }
    document.querySelectorAll('[data-vote]').forEach(button => {
      button.onclick = () => push('vote', {option: button.dataset.vote})
    })
    q('#close').onclick = () => push('close_poll')
  </script>
</body>
</html>"
}
