import beryl
import beryl/snapshot
import gleam/json
import load_test/runtime_snapshot

pub type EndpointResult {
  EndpointResult(status: Int, body: String)
}

pub fn health() -> EndpointResult {
  EndpointResult(
    status: 200,
    body: json.object([#("status", json.string("ok"))]) |> json.to_string,
  )
}

pub fn stats(channels: beryl.Sockets) -> EndpointResult {
  case snapshot.get(channels) {
    Error(error) -> stats_error(error)
    Ok(beryl_snapshot) ->
      case runtime_snapshot.snapshot() {
        Error(_) -> error_response(503, "runtime_stats_unavailable")
        Ok(runtime_snapshot) ->
          EndpointResult(
            status: 200,
            body: json.object([
              #(
                "beryl",
                json.object([
                  #(
                    "connected_sockets",
                    json.int(snapshot.connected_sockets(beryl_snapshot)),
                  ),
                  #(
                    "joined_socket_topic_pairs",
                    json.int(snapshot.joined_socket_topic_pairs(beryl_snapshot)),
                  ),
                  #(
                    "active_topics",
                    json.int(snapshot.active_topics(beryl_snapshot)),
                  ),
                ]),
              ),
              #(
                "beam",
                json.object([
                  #("process_count", json.int(runtime_snapshot.process_count)),
                  #("port_count", json.int(runtime_snapshot.port_count)),
                  #("memory_bytes", json.int(runtime_snapshot.memory_bytes)),
                  #("run_queue", json.int(runtime_snapshot.run_queue)),
                  #(
                    "schedulers_online",
                    json.int(runtime_snapshot.schedulers_online),
                  ),
                  #(
                    "runtime_version",
                    json.string(runtime_snapshot.runtime_version),
                  ),
                ]),
              ),
            ])
              |> json.to_string,
          )
      }
  }
}

pub fn stats_error(error: snapshot.SnapshotError) -> EndpointResult {
  case error {
    snapshot.RuntimeUnavailable -> error_response(503, "runtime_unavailable")
    snapshot.RequestTimedOut -> error_response(504, "runtime_timeout")
  }
}

fn error_response(status: Int, code: String) -> EndpointResult {
  EndpointResult(
    status:,
    body: json.object([#("error", json.string(code))]) |> json.to_string,
  )
}
