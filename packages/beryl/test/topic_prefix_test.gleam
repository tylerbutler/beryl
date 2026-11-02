import beryl
import beryl/channel
import beryl/topic
import beryl/wire
import beryl/wire/codec
import channel_dispatch_helper as helper
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleeunit/should

pub fn prefix_wildcards_preserve_exact_unicode_suffixes_test() -> Nil {
  [
    #("room:", "\u{0301}admin"),
    #("room:", "\u{200D}admin"),
    #("room:", "e\u{0301}admin"),
    #("room:👩", "\u{200D}💻admin"),
    #("room:🇺", "🇸admin"),
    #("rööm:", "\u{0301}admin"),
    #("", "\u{0301}admin"),
    #("room:", ""),
  ]
  |> list.each(fn(pair) {
    let #(prefix, suffix) = pair
    let pattern = topic.parse_pattern(prefix <> "*")
    let name = prefix <> suffix
    topic.matches(pattern, name) |> should.be_true
    topic.extract_id(pattern, name) |> should.equal(Ok(suffix))
    topic.extract_wildcards(pattern, name) |> should.equal(Ok([suffix]))
  })

  let pattern = topic.parse_pattern("room:*")
  topic.extract_id(pattern, "rööm:admin")
  |> should.equal(Error(topic.TopicMismatch))
  topic.extract_wildcards(pattern, "rööm:admin")
  |> should.equal(Error(topic.TopicMismatch))
}

pub fn channel_prefix_parameters_do_not_alias_exact_topics_test() -> Nil {
  let channels =
    helper.start(beryl.config(wire.phoenix_codec()), handlers: [
      channel.handler("room:admin", fn(_context) {
        channel.reject(json.string("privileged"))
      }),
      channel.handler("room:*", fn(context) {
        channel.accept(Nil)
        |> channel.with_reply(json.array(context.parameters, json.string))
      }),
    ])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:admin", "jr-1", "r-1")
  codec.TextFrame(helper.recv(frames))
  |> should.equal(wire.reply_json(
    Some("jr-1"),
    Some("r-1"),
    "room:admin",
    codec.StatusError,
    json.string("privileged"),
  ))

  ["\u{0301}admin", "\u{200D}admin", "e\u{0301}admin"]
  |> list.each(fn(suffix) {
    let name = "room:" <> suffix
    topic.validate(name) |> should.equal(Ok(name))
    helper.join(channels, "s1", name, "jr-2", "r-2")
    codec.TextFrame(helper.recv(frames))
    |> should.equal(wire.reply_json(
      Some("jr-2"),
      Some("r-2"),
      name,
      codec.StatusOk,
      json.array([suffix], json.string),
    ))
  })

  helper.disconnect(channels, "s1")
  beryl.stop(channels) |> should.equal(Ok(Nil))
}
