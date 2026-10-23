import beryl_site/phoenix
import beryl_site/presence/model.{type Message, type Model}
import beryl_site/presence/view
import gleam/int
import gleam/result
import lustre.{type App}
import lustre/component
import lustre/effect.{type Effect}

pub const tag = "beryl-presence-lab"

fn init(_arguments: Nil) -> #(Model, Effect(Message)) {
  #(model.initial(), effect.none())
}

fn update(current: Model, message: Message) -> #(Model, Effect(Message)) {
  let #(next, commands) = model.update(current, message)
  #(next, phoenix.run(commands))
}

pub fn app() -> App(Nil, Model, Message) {
  lustre.component(init:, update:, view: view.view, options: [
    component.on_attribute_change("service-url", fn(value) {
      Ok(model.ServiceUrlChanged(value))
    }),
    component.on_attribute_change("compatibility-version", fn(value) {
      int.parse(value)
      |> result.map(model.CompatibilityVersionChanged)
      |> result.replace_error(Nil)
    }),
    component.on_attribute_change("reset-token", fn(value) {
      Ok(model.ResetRequested(value))
    }),
    component.on_disconnect(model.ComponentDisconnected),
    component.adopt_styles(False),
  ])
}
