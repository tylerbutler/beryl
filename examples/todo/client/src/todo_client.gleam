import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import todo_app/domain
import todo_channel

pub type Connection {
  Connecting
  Connected
  Disconnected
}

pub type Model {
  Model(
    state: domain.State,
    input: String,
    client: Option(todo_channel.Client),
    connection: Connection,
    pending_add: Option(String),
    form_error: Option(String),
    channel_error: Option(String),
    status: String,
  )
}

pub type Message {
  InputChanged(String)
  TodoSubmitted
  TodoToggled(Int)
  TodoDeleted(Int)
  ChannelReady(todo_channel.Client)
  ChannelEvent(todo_channel.Event)
  AddFinished(String, Result(domain.Todo, todo_channel.MutationError))
  ToggleFinished(Result(domain.Todo, todo_channel.MutationError))
  DeleteFinished(Result(Int, todo_channel.MutationError))
}

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", initial_model())

  Nil
}

pub fn initial_model() -> Model {
  Model(
    state: domain.new(),
    input: "",
    client: None,
    connection: Connecting,
    pending_add: None,
    form_error: None,
    channel_error: None,
    status: "Connecting to the Todo server…",
  )
}

fn init(model: Model) -> #(Model, Effect(Message)) {
  #(model, connect())
}

fn connect() -> Effect(Message) {
  effect.from(fn(dispatch) {
    let client =
      todo_channel.connect(fn(event) { dispatch(ChannelEvent(event)) })
    dispatch(ChannelReady(client))
  })
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    InputChanged(input) -> #(
      Model(..model, input: input, form_error: None),
      effect.none(),
    )

    ChannelReady(client) -> #(
      Model(..model, client: Some(client)),
      effect.none(),
    )

    ChannelEvent(event) -> handle_channel_event(model, event)

    TodoSubmitted -> submit_todo(model)

    TodoToggled(id) ->
      case ready_client(model) {
        Error(Nil) -> not_connected(model)
        Ok(client) -> #(
          Model(..model, channel_error: None, status: "Updating todo…"),
          effect.from(fn(dispatch) {
            todo_channel.toggle(client, id, fn(result) {
              dispatch(ToggleFinished(result))
            })
          }),
        )
      }

    TodoDeleted(id) ->
      case ready_client(model) {
        Error(Nil) -> not_connected(model)
        Ok(client) -> #(
          Model(..model, channel_error: None, status: "Deleting todo…"),
          effect.from(fn(dispatch) {
            todo_channel.delete(client, id, fn(result) {
              dispatch(DeleteFinished(result))
            })
          }),
        )
      }

    AddFinished(submitted, result) ->
      case result {
        Ok(item) -> #(
          Model(
            ..model,
            state: domain.put(model.state, item),
            input: case model.input == submitted {
              True -> ""
              False -> model.input
            },
            pending_add: None,
            form_error: None,
            channel_error: None,
            status: "Todo added.",
          ),
          effect.none(),
        )
        Error(error) -> mutation_failed(model, error)
      }

    ToggleFinished(result) ->
      case result {
        Ok(item) -> #(
          Model(
            ..model,
            state: domain.put(model.state, item),
            channel_error: None,
            status: "Todo updated.",
          ),
          effect.none(),
        )
        Error(error) -> mutation_failed(model, error)
      }

    DeleteFinished(result) ->
      case result {
        Ok(id) -> #(
          Model(
            ..model,
            state: domain.delete(model.state, id),
            channel_error: None,
            status: "Todo deleted.",
          ),
          effect.none(),
        )
        Error(error) -> mutation_failed(model, error)
      }
  }
}

fn submit_todo(model: Model) -> #(Model, Effect(Message)) {
  case ready_client(model), model.pending_add {
    Error(Nil), _ -> not_connected(model)
    _, Some(_) -> #(model, effect.none())
    Ok(client), None -> {
      let text = string.trim(model.input)
      case text {
        "" -> #(
          Model(
            ..model,
            form_error: Some("Enter a todo before adding it."),
            status: "Todo not added.",
          ),
          effect.none(),
        )
        _ -> #(
          Model(
            ..model,
            pending_add: Some(model.input),
            form_error: None,
            channel_error: None,
            status: "Adding todo…",
          ),
          effect.from(fn(dispatch) {
            todo_channel.add(client, model.input, fn(result) {
              dispatch(AddFinished(model.input, result))
            })
          }),
        )
      }
    }
  }
}

fn handle_channel_event(
  model: Model,
  channel_event: todo_channel.Event,
) -> #(Model, Effect(Message)) {
  case channel_event {
    todo_channel.Connecting -> #(
      Model(
        ..model,
        connection: Connecting,
        channel_error: None,
        status: "Connecting to the Todo server…",
      ),
      effect.none(),
    )

    todo_channel.Joined(todos) ->
      case domain.from_todos(todos) {
        Ok(state) -> #(
          Model(
            ..model,
            state: state,
            connection: Connected,
            pending_add: None,
            channel_error: None,
            status: "Connected to the Todo server.",
          ),
          effect.none(),
        )
        Error(Nil) -> decode_failed(model, "The Todo snapshot was invalid.")
      }

    todo_channel.Disconnected(reason) -> #(
      Model(
        ..model,
        connection: Disconnected,
        pending_add: None,
        channel_error: Some(reason),
        status: "Disconnected. Waiting to reconnect…",
      ),
      effect.none(),
    )

    todo_channel.Added(item) -> #(
      Model(
        ..model,
        state: domain.put(model.state, item),
        status: "Todo added.",
      ),
      effect.none(),
    )

    todo_channel.Updated(item) -> #(
      Model(
        ..model,
        state: domain.put(model.state, item),
        status: "Todo updated.",
      ),
      effect.none(),
    )

    todo_channel.Deleted(id) -> #(
      Model(
        ..model,
        state: domain.delete(model.state, id),
        status: "Todo deleted.",
      ),
      effect.none(),
    )

    todo_channel.DecodeFailed(message) -> decode_failed(model, message)
  }
}

fn decode_failed(model: Model, message: String) -> #(Model, Effect(Message)) {
  #(
    Model(
      ..model,
      channel_error: Some(message),
      status: "Received unreadable server data.",
    ),
    effect.none(),
  )
}

fn mutation_failed(
  model: Model,
  error: todo_channel.MutationError,
) -> #(Model, Effect(Message)) {
  let message = case error {
    todo_channel.Rejected(_, message) -> message
    todo_channel.InvalidResponse(message) -> message
  }
  #(
    Model(
      ..model,
      pending_add: None,
      channel_error: Some(message),
      status: "The Todo server rejected the change.",
    ),
    effect.none(),
  )
}

fn ready_client(model: Model) -> Result(todo_channel.Client, Nil) {
  case model.connection, model.client {
    Connected, Some(client) -> Ok(client)
    _, _ -> Error(Nil)
  }
}

fn not_connected(model: Model) -> #(Model, Effect(Message)) {
  #(
    Model(
      ..model,
      channel_error: Some("Wait for the Todo channel to connect."),
      status: "Not connected.",
    ),
    effect.none(),
  )
}

fn view(model: Model) -> Element(Message) {
  let todos = domain.todos(model.state)

  html.section([attribute.class("todo-app")], [
    html.header([attribute.class("app-header")], [
      html.h1([], [html.text("Things worth doing")]),
      html.p([], [
        html.text(
          "A shared list kept authoritative by a Gleam server and synchronized through Beryl.",
        ),
      ]),
    ]),
    view_error(model),
    view_form(model),
    html.div([attribute.class("list-heading")], [
      html.h2([], [html.text("Your list")]),
      html.p([attribute.id("items-left")], [
        html.text(items_left_label(domain.items_left(model.state))),
      ]),
    ]),
    case todos {
      [] ->
        html.p([attribute.class("empty-state")], [
          html.text("Nothing here yet. Add the first thing you want to finish."),
        ])
      _ ->
        keyed.ul(
          [
            attribute.class("todo-list"),
            attribute.aria_label("Todo list"),
          ],
          list.map(todos, fn(item) { view_todo(item, model.connection) }),
        )
    },
    html.footer([attribute.class("app-footer")], [
      html.p(
        [
          attribute.id("connection-status"),
          attribute.class("connection-status"),
        ],
        [html.text(connection_label(model.connection))],
      ),
      html.p(
        [
          attribute.id("app-status"),
          attribute.aria_live("polite"),
          attribute.aria_atomic(True),
        ],
        [html.text(model.status)],
      ),
      html.p([], [html.text("Server-authoritative through Beryl.")]),
    ]),
  ])
}

fn view_error(model: Model) -> Element(Message) {
  let error = case model.form_error {
    Some(error) -> Some(error)
    None -> model.channel_error
  }

  case error {
    None -> html.text("")
    Some(error) ->
      html.p(
        [
          attribute.class("error-message"),
          attribute.id("todo-error"),
          attribute.role("alert"),
        ],
        [html.text(error)],
      )
  }
}

fn view_form(model: Model) -> Element(Message) {
  let invalid = case model.form_error {
    Some(_) -> "true"
    None -> "false"
  }
  let enabled = model.connection == Connected
  let submitting = model.pending_add != None

  html.form(
    [attribute.class("todo-form"), event.on_submit(fn(_) { TodoSubmitted })],
    [
      html.label([attribute.for("new-todo")], [html.text("New todo")]),
      html.div([attribute.class("input-row")], [
        html.input([
          attribute.id("new-todo"),
          attribute.name("todo"),
          attribute.type_("text"),
          attribute.value(model.input),
          attribute.placeholder("What needs doing?"),
          attribute.autocomplete("off"),
          attribute.autofocus(True),
          attribute.maxlength(160),
          attribute.disabled(!enabled),
          attribute.aria_invalid(invalid),
          attribute.aria_describedby("todo-hint todo-error"),
          event.on_input(InputChanged),
        ]),
        html.button(
          [
            attribute.type_("submit"),
            attribute.disabled(!enabled || submitting),
          ],
          [html.text("Add todo")],
        ),
      ]),
      html.p([attribute.id("todo-hint"), attribute.class("form-hint")], [
        html.text("Press Enter to add. Blank todos are rejected."),
      ]),
    ],
  )
}

fn view_todo(
  item: domain.Todo,
  connection: Connection,
) -> #(String, Element(Message)) {
  let domain.Todo(id:, text:, completed:) = item
  let input_id = "todo-" <> int.to_string(id)
  let disabled = connection != Connected

  #(
    int.to_string(id),
    html.li(
      [
        attribute.class("todo-row"),
        attribute.classes([#("is-complete", completed)]),
      ],
      [
        html.input([
          attribute.id(input_id),
          attribute.type_("checkbox"),
          attribute.checked(completed),
          attribute.disabled(disabled),
          event.on_check(fn(_) { TodoToggled(id) }),
        ]),
        html.label([attribute.for(input_id)], [html.text(text)]),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("delete-button"),
            attribute.aria_label("Delete " <> text),
            attribute.disabled(disabled),
            event.on_click(TodoDeleted(id)),
          ],
          [html.text("Delete")],
        ),
      ],
    ),
  )
}

fn connection_label(connection: Connection) -> String {
  case connection {
    Connecting -> "Connecting"
    Connected -> "Connected"
    Disconnected -> "Disconnected"
  }
}

fn items_left_label(count: Int) -> String {
  case count {
    1 -> "1 item left"
    _ -> int.to_string(count) <> " items left"
  }
}
