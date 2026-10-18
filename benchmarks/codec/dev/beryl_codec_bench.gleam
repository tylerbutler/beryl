import beryl/wire
import beryl/wire/codec
import beryl_codec_bench/fixture
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glychee/benchmark
import glychee/configuration

/// Measure completed codec calls after checking all fixture results.
pub fn main() -> Nil {
  let assert Ok(texts) = fixture.text()
  let binaries = fixture.binary()
  let assert Ok(Nil) = fixture.preflight(texts, binaries)
  io.println("Codec fixture preflight passed; mode=dev, parallel=1")

  configuration.initialize()
  let assert True = configuration.set_pair(configuration.Parallel, 1)
  let assert True = configuration.set_pair(configuration.Warmup, 1)
  let assert True = configuration.set_pair(configuration.Time, 3)
  let assert True = configuration.set_pair(configuration.MemoryTime, 1)
  let assert True = configuration.set_pair(configuration.ReductionTime, 1)

  let text_data =
    list.map(texts, fn(input) {
      benchmark.Data(label: input.label, data: input)
    })
  benchmark.run(
    [
      benchmark.Function("wire.decode_message", fn(input: fixture.TextFixture) {
        let frame = input.frame
        fn() { wire.decode_message(frame) }
      }),
    ],
    text_data,
  )
  benchmark.run(
    [
      benchmark.Function("wire.encode", fn(input: fixture.TextFixture) {
        let inbound = input.inbound
        fn() { wire.encode(inbound) }
      }),
    ],
    text_data,
  )
  benchmark.run(
    [
      benchmark.Function("wire.push", fn(input: fixture.TextFixture) {
        let payload = input.payload
        fn() { wire.push("bench:codec", "echo", payload) }
      }),
      benchmark.Function("wire.reply_json", fn(input: fixture.TextFixture) {
        let payload = input.payload
        fn() {
          wire.reply_json(
            Some("j1"),
            Some("r1"),
            "bench:codec",
            codec.StatusOk,
            payload,
          )
        }
      }),
    ],
    text_data,
  )

  let binary_data =
    list.map(binaries, fn(input) {
      benchmark.Data(label: input.label, data: input)
    })
  benchmark.run(
    [
      benchmark.Function(
        "wire.decode_binary_message",
        fn(input: fixture.BinaryFixture) {
          let frame = input.frame
          fn() { wire.decode_binary_message(frame) }
        },
      ),
    ],
    binary_data,
  )
  benchmark.run(
    [
      benchmark.Function("wire.binary_push", fn(input: fixture.BinaryFixture) {
        let payload = input.payload
        fn() { wire.binary_push(Some("j1"), "bench:codec", "echo", payload) }
      }),
      benchmark.Function("wire.binary_reply", fn(input: fixture.BinaryFixture) {
        let payload = input.payload
        fn() {
          wire.binary_reply(
            Some("j1"),
            Some("r1"),
            "bench:codec",
            codec.StatusOk,
            payload,
          )
        }
      }),
      benchmark.Function(
        "wire.binary_broadcast",
        fn(input: fixture.BinaryFixture) {
          let payload = input.payload
          fn() { wire.binary_broadcast("bench:codec", "echo", payload) }
        },
      ),
    ],
    binary_data,
  )

  benchmark.run(
    [
      benchmark.Function(
        "wire.decode_message/reject",
        fn(input: fixture.TextRejection) {
          let frame = input.frame
          fn() { wire.decode_message(frame) }
        },
      ),
    ],
    list.map(fixture.rejected_text(), fn(input) {
      benchmark.Data(label: input.label, data: input)
    }),
  )
  benchmark.run(
    [
      benchmark.Function("wire.decode_binary_message/reject", fn(frame) {
        fn() { wire.decode_binary_message(frame) }
      }),
    ],
    list.map(fixture.rejected_binary(), fn(input) {
      let #(label, frame) = input
      benchmark.Data(label: label, data: frame)
    }),
  )
  benchmark.run(
    [
      benchmark.Function("wire.binary_push/reject", fn(topic) {
        fn() { wire.binary_push(None, topic, "echo", <<>>) }
      }),
    ],
    [benchmark.Data("topic_bytes=256", string.repeat("a", 256))],
  )
}
