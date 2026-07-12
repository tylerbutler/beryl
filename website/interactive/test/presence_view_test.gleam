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

pub fn disconnected_view_has_progressive_controls_test() {
  let rendered =
    presence_lab.view(presence_lab.initial_model())
    |> element.to_readable_string

  rendered |> string.contains("data-testid=\"primary-name\"") |> should.be_true
  rendered
  |> string.contains("data-testid=\"connect-primary\"")
  |> should.be_true
  rendered |> string.contains("aria-live=\"polite\"") |> should.be_true
}
