//// Showcase: all three example channels on one socket, composed with
//// `beryl/channel`.
////
//// Each example's topic namespace is a channel handler here — `cursor:*`,
//// `room:*`, and `document:` — and the layer routes every socket event
//// to the handler that owns its topic. There is no socket-wide model, no
//// message union, and no hand-written router: a channel keeps its own
//// private state per joined topic and the layer prunes it when the topic
//// closes.
////
//// Chat and documents use the standalone apps' handlers. The cursor handler
//// adapts the standalone cursor example's raw dispatch to this channel table.

import beryl
import beryl/channel
import beryl/group
import beryl/transport/server
import beryl/wire
import beryl_ewe
import chatroom/app as chat_app
import chatroom/router as chatroom_router
import collab_document/app as document_app
import collab_document/auth as document_auth
import collab_document/document_store
import collab_document/router as document_router
import cursor/router as cursor_router
import envoy
import ewe
import example_helper/broadcast_hub as hub
import example_helper/session_presence
import example_helper/static
import gleam/erlang/application
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import relay_supervisor as relay
import showcase/channel/cursor as cursor_channel
import showcase/router

/// Everything the showcase channels read. Assembled at startup and passed
/// to `handlers`, which is also what the tests register, so the deployed
/// table and the tested table cannot drift.
pub type Dependencies {
  Dependencies(
    presence: session_presence.Tracker,
    groups: group.Groups,
    store: document_store.Store,
    secret: BitArray,
    hub: hub.Hub,
  )
}

/// The showcase's channel table: one handler per topic namespace plus the
/// read-only lobby mounted by the standalone chat app.
///
/// Handlers are consulted in list order and the first matching pattern
/// owns the topic; these patterns do not overlap, so the order is
/// documentation rather than resolution.
pub fn handlers(dependencies: Dependencies) -> List(channel.Handler) {
  [
    chat_app.lobby(),
    cursor_channel.channel(cursor_channel.Context(dependencies.presence)),
    chat_app.room(
      chat_app.Context(
        presence: dependencies.presence,
        groups: dependencies.groups,
        hub: dependencies.hub,
      ),
      room_display_name,
      "[room]",
    ),
    document_app.handler_with_log_prefix(
      document_app.Context(
        store: dependencies.store,
        secret: dependencies.secret,
      ),
      "[showcase.channel.document]",
    ),
  ]
}

fn room_display_name(topic: String) -> String {
  case string.split(topic, ":") {
    [_, name] -> name
    _ -> "unknown"
  }
}

/// Start the service under its OTP application. Other entrypoints, including
/// `gleam test`, start the application but do not open a listening port.
pub fn main() -> Nil {
  let entrypoint = entrypoint_name()
  let assert Ok(Nil) = process.register(process.self(), entrypoint)
  let server = factory.get_by_name(server_name())
  let assert Ok(started) = factory.start_child(server, Nil)
  process.new_selector()
  |> process.select_specific_monitor(process.monitor(started.pid), fn(_) { Nil })
  |> process.selector_receive_forever
  // Restart exhaustion also exits with `shutdown`. Only prep_stop authorizes
  // a successful exit, and its notice precedes the shutdown of the tree.
  let assert Ok(Nil) = process.receive(process.named_subject(entrypoint), 0)
    as "showcase service stopped outside application shutdown"
  Nil
}

// The OTP callbacks and the deployment entrypoint run in separate processes.
// Only the two literal names below enter the atom table.
@external(erlang, "erlang", "binary_to_atom")
fn registered_name(label: String) -> process.Name(message)

fn server_name() -> process.Name(factory.Message(Nil, relay.Supervisor)) {
  registered_name("showcase")
}

fn entrypoint_name() -> process.Name(Nil) {
  registered_name("showcase_entrypoint")
}

/// OTP application callback. Only the server entrypoint starts a child.
pub fn start(
  _type: application.StartType,
  _arguments: List(Nil),
) -> Result(process.Pid, actor.StartError) {
  factory.supervisor_child(start_server)
  |> factory.named(server_name())
  |> factory.start
  |> result.map(fn(started) { started.pid })
}

/// Notify the deployment before OTP starts shutting down its supervisor.
pub fn prep_stop(state: a) -> a {
  let entrypoint = entrypoint_name()
  // OTP also calls prep_stop after an unexpected exit of the root supervisor.
  case process.named(server_name()), process.named(entrypoint) {
    Ok(_), Ok(_) -> process.send(process.named_subject(entrypoint), Nil)
    _, _ -> Nil
  }
  state
}

/// OTP stops the server tree before it calls `stop`.
pub fn stop(_state: a) -> Nil {
  Nil
}

fn start_server(_argument: Nil) -> actor.StartResult(relay.Supervisor) {
  // The domain owner starts the helpers that return process-specific handles.
  // Its younger sibling uses those handles and must stop before the owner.
  let owner =
    relay.Template(
      start: fn(_) {
        actor.new_with_initialiser(5000, fn(_) {
          Ok(actor.initialised(Nil) |> actor.returning(server_tree()))
        })
        |> actor.start
      },
      child_type: supervision.Worker(5000),
    )
  let server =
    relay.Template(
      start: static_supervisor.start,
      child_type: supervision.Supervisor,
    )
  relay.new(fn(children) {
    children |> relay.add(relay.child(owner)) |> relay.add(relay.child(server))
  })
  |> relay.start
}

fn server_tree() -> static_supervisor.Builder {
  let assert Ok(cursor_static_directory) = static.priv_static("cursor")
  let assert Ok(chatroom_static_directory) = static.priv_static("chatroom")
  let assert Ok(document_static_directory) =
    static.priv_static("collab_document")
  // Shared example-local session presence. Mutations and capacity reads are
  // synchronous ETS operations; snapshots publish asynchronously.
  let assert Ok(presence_tracker) = session_presence.start()

  // Chatrooms-specific state.
  let #(groups, groups_specification) = public_rooms()

  // collab_docs-specific state.
  let document_secret = document_auth.new_secret()
  let assert Ok(document_store_process) = document_store.start()

  // The showcase's broadcast hub: bound to the running system below, and
  // used for the one announcement no channel's own topic can carry (the
  // `lobby` room list).
  let assert Ok(hub) = hub.start()

  // Per-topic-pattern rate limits replace the old single global
  // channel-rate compromise: cursors stream fast, chat and docs do not.
  // The frame budget sits modestly above the decoded-message budget to
  // account for joins and malformed frames.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_frame_rate(per_second: 35, burst: 70)
    |> beryl.with_message_rate(per_second: 30, burst: 60)
    |> beryl.with_join_rate(per_second: 5, burst: 10)
    |> beryl.with_topic_rate(pattern: "cursor:*", per_second: 30, burst: 60)
    |> beryl.with_topic_rate(pattern: "room:*", per_second: 10, burst: 20)
    |> beryl.with_topic_rate(pattern: "document:*:*", per_second: 10, burst: 20)

  let dependencies =
    Dependencies(
      presence: presence_tracker,
      groups: groups,
      store: document_store_process,
      secret: document_secret,
      hub: hub,
    )

  let assert Ok(#(channels, beryl_specification)) =
    channel.child_spec(config, handlers: handlers(dependencies))

  session_presence.configure(presence_tracker, channels)
  hub.bind(hub, channels)

  // Build per-example contexts pinned to their URL prefix.
  let cursor_context =
    cursor_router.Context(
      channels:,
      presence: presence_tracker,
      base_path: "/cursors",
      static_directory: cursor_static_directory,
    )
  let chatroom_context =
    chatroom_router.Context(
      channels:,
      presence: presence_tracker,
      groups:,
      base_path: "/chat",
      static_directory: chatroom_static_directory,
    )
  let collab_document_context =
    document_router.Context(
      channels:,
      store: document_store_process,
      secret: document_secret,
      base_path: "/docs",
      static_directory: document_static_directory,
    )
  let showcase_context =
    router.Context(
      cursor: cursor_context,
      chatroom: chatroom_context,
      collab_document: collab_document_context,
    )

  let port =
    envoy.get("PORT")
    |> result.try(int.parse)
    |> result.unwrap(8000)
  let interface =
    envoy.get("BIND_ADDRESS")
    |> result.unwrap("localhost")

  // Single WebSocket endpoint at /socket/websocket. No token gate — this
  // is a public demo. Phoenix JS client (new Socket("/socket")) in every
  // example targets this URL out of the box.
  let listener =
    fn(http_request) {
      use <- beryl_ewe.upgrade(
        http_request,
        channels,
        server.default_config("/socket/websocket"),
      )
      router.handle_request(http_request, showcase_context)
    }
    |> ewe.new
    |> ewe.listening(on: port)
    |> ewe.bind(to: interface)
    |> ewe.supervised

  io.println("✨ beryl examples showcase (beryl/channel)")
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(groups_specification)
  |> static_supervisor.add(beryl_specification)
  |> static_supervisor.add(listener)
}

/// Seed the public rooms each time the groups actor starts.
@internal
pub fn public_rooms() -> #(
  group.Groups,
  supervision.ChildSpecification(process.Subject(group.Message)),
) {
  let #(groups, specification) = group.child_spec()
  let seeded =
    supervision.map_data(specification, fn(subject) {
      let assert Ok(Nil) = group.create(groups, "public")
      let assert Ok(Nil) = group.add(groups, "public", "room:general")
      let assert Ok(Nil) = group.add(groups, "public", "room:random")
      let assert Ok(Nil) = group.add(groups, "public", "room:help")
      subject
    })
  #(groups, seeded)
}
