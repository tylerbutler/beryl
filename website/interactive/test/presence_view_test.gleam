import beryl_site/component/presence_lab
import gleam/string
import gleeunit/should
import lustre/element

pub fn static_component_names_the_presence_lab_test() {
  presence_lab.view(presence_lab.initial_model())
  |> element.to_readable_string
  |> string.contains("Presence lab")
  |> should.be_true
}
