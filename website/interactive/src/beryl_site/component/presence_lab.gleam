import lustre
import lustre/effect
import lustre/element.{type Element}
import lustre/element/html

pub const tag = "beryl-presence-lab"

pub type Model {
  Model
}

pub type Message {
  NoOp
}

pub fn initial_model() -> Model {
  Model
}

fn init(_arguments: Nil) {
  #(initial_model(), effect.none())
}

fn update(model: Model, _message: Message) {
  #(model, effect.none())
}

pub fn view(_model: Model) -> Element(Message) {
  html.section([], [
    html.h2([], [html.text("Presence lab")]),
    html.p([], [html.text("Interactive client loading.")]),
  ])
}

pub fn app() {
  lustre.component(init:, update:, view:, options: [])
}
