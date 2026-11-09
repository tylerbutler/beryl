import beryl_demo/presence_channel
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn accepts_randomized_demo_topic_test() {
  presence_channel.valid_topic("demo:presence:0123456789abcdef0123456789abcdef")
  |> should.be_true
}

pub fn rejects_short_or_cross_scenario_topics_test() {
  presence_channel.valid_topic("demo:presence:short") |> should.be_false
  presence_channel.valid_topic("room:lobby") |> should.be_false
}

pub fn validates_join_fields_test() {
  presence_channel.validate_join(
    client_id: "0d784f76-ae17-4812-98cc-f4339efac343",
    compatibility_version: 1,
    name: "Alice",
    color: "emerald",
  )
  |> should.be_ok
}
