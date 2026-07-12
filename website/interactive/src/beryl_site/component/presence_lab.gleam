import beryl_site/phoenix
import beryl_site/presence/model
import beryl_site/presence/view as presence_view
import gleam/int
import gleam/result
import lustre
import lustre/component
import lustre/effect

pub const tag = "beryl-presence-lab"

pub type Model =
  model.Model

pub type Message =
  model.Message

pub fn initial_model() -> Model {
  model.initial()
}

fn init(_arguments: Nil) {
  #(initial_model(), effect.none())
}

fn update(current: Model, message: Message) {
  let #(next, commands) = model.update(current, message)
  #(next, phoenix.run(commands))
}

pub fn view(current: Model) {
  presence_view.view(current)
}

pub fn app() {
  lustre.component(init:, update:, view:, options: [
    component.on_attribute_change("service-url", fn(value) {
      Ok(model.ServiceUrlChanged(value))
    }),
    component.on_attribute_change("compatibility-version", fn(value) {
      int.parse(value)
      |> result.map(model.CompatibilityVersionChanged)
      |> result.replace_error(Nil)
    }),
    component.on_disconnect(model.ComponentDisconnected),
    component.adopt_styles(False),
  ])
}
