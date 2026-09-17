import beryl/overload
import beryl/work_queue
import gleam/erlang/process
import gleam/list
import gleeunit/should

@external(erlang, "beryl_test_process_ffi", "queue_memory_evidence")
fn queue_memory_evidence() -> String

@external(erlang, "beryl_test_process_ffi", "queue_call_lifecycle")
pub fn pending_call_cancels_and_running_call_keeps_credit_test() -> Nil

@external(erlang, "beryl_test_process_ffi", "publication_cleanup_races")
pub fn publication_and_producer_cleanup_are_atomic_test() -> Nil

@external(erlang, "binary", "copy")
fn copy_binary(value: BitArray, copies: Int) -> BitArray

@external(erlang, "binary", "part")
fn binary_part(value: BitArray, start: Int, length: Int) -> BitArray

pub fn rejected_attempts_do_not_retain_payloads_test() -> Nil {
  let _evidence = queue_memory_evidence()
  Nil
}

pub fn sub_binary_is_charged_for_its_backing_allocation_test() -> Nil {
  let assert Ok(limits) = overload.limits(items: 8, bytes: 4096)
  let queue = work_queue.new(limits, overload.WorkerQueue, False, fn() { Nil })
  let backing = copy_binary(<<0>>, 8192)
  let slice = binary_part(backing, 0, 128)
  work_queue.publish_value(queue, slice)
  |> should.equal(Error(overload.ItemTooLarge(overload.WorkerQueue)))
  let assert Ok(snapshot) = work_queue.snapshot(queue)
  snapshot.items |> should.equal(0)
  snapshot.bytes |> should.equal(0)
}

pub fn unaligned_sub_binary_is_charged_for_its_backing_allocation_test() -> Nil {
  let assert Ok(limits) = overload.limits(items: 8, bytes: 4096)
  let queue = work_queue.new(limits, overload.WorkerQueue, False, fn() { Nil })
  let backing = copy_binary(<<0>>, 8192)
  let assert <<_:1, slice:bits-size(1023), _:bits>> = backing
  work_queue.publish_value(queue, slice)
  |> should.equal(Error(overload.ItemTooLarge(overload.WorkerQueue)))
  let assert Ok(snapshot) = work_queue.snapshot(queue)
  snapshot.items |> should.equal(0)
  snapshot.bytes |> should.equal(0)
}

pub fn output_after_close_still_obeys_aggregate_limits_test() -> Nil {
  let assert Ok(limits) = overload.limits(items: 1, bytes: 8)
  let queue = work_queue.new(limits, overload.WorkerQueue, False, fn() { Nil })
  work_queue.close(queue)
  let assert Ok(reservation) = work_queue.retain_output(queue, Nil)
  work_queue.retain_output(queue, Nil)
  |> should.equal(Error(overload.Overloaded(overload.WorkerQueue)))
  work_queue.release(queue, reservation)
  let assert Ok(snapshot) = work_queue.snapshot(queue)
  snapshot.items |> should.equal(0)
}

pub fn finite_limits_test() -> Nil {
  overload.limits(items: 0, bytes: 1)
  |> should.equal(Error(overload.InvalidItemLimit))
  overload.limits(items: 1, bytes: 0)
  |> should.equal(Error(overload.InvalidByteLimit))
}

pub fn reservation_survives_dequeue_test() -> Nil {
  let assert Ok(limits) = overload.limits(items: 1, bytes: 8)
  let queue = work_queue.new(limits, overload.WorkerQueue, False, fn() { Nil })
  let assert Ok(reservation) = work_queue.publish(queue, "first", 8)
  work_queue.take(queue) |> should.equal(Ok(#(reservation, "first")))
  work_queue.publish(queue, "second", 1)
  |> should.equal(Error(overload.Overloaded(overload.WorkerQueue)))
  work_queue.release(queue, reservation)
  work_queue.release(queue, reservation)
  let assert Ok(_) = work_queue.publish(queue, "second", 1)
  let assert Ok(snapshot) = work_queue.snapshot(queue)
  snapshot.items |> should.equal(1)
  snapshot.bytes |> should.equal(1)
}

pub fn cancel_pending_preserves_fifo_test() -> Nil {
  let queue =
    work_queue.new(overload.worker_limits(), overload.WorkerQueue, False, fn() {
      Nil
    })
  let assert Ok(first) = work_queue.publish(queue, 1, 1)
  let assert Ok(cancelled) = work_queue.publish(queue, 2, 1)
  let assert Ok(third) = work_queue.publish(queue, 3, 1)
  work_queue.release(queue, cancelled)
  work_queue.take(queue) |> should.equal(Ok(#(first, 1)))
  work_queue.take(queue) |> should.equal(Ok(#(third, 3)))
  work_queue.take(queue) |> should.equal(Error(Nil))
  let assert Ok(snapshot) = work_queue.snapshot(queue)
  snapshot.cancelled |> should.equal(1)
}

pub fn wake_is_coalesced_test() -> Nil {
  let wakes = process.new_subject()
  let queue =
    work_queue.new(overload.worker_limits(), overload.WorkerQueue, False, fn() {
      process.send(wakes, Nil)
    })
  let assert Ok(_) = work_queue.publish(queue, 1, 0)
  let assert Ok(_) = work_queue.publish(queue, 2, 0)
  process.receive(wakes, 0) |> should.equal(Ok(Nil))
  process.receive(wakes, 0) |> should.equal(Error(Nil))
  let assert Ok(_) = work_queue.take(queue)
  let assert Ok(_) = work_queue.take(queue)
  let assert Error(Nil) = work_queue.take(queue)
  let assert Ok(_) = work_queue.publish(queue, 3, 0)
  process.receive(wakes, 0) |> should.equal(Ok(Nil))
}

pub fn closed_queue_drains_but_rejects_new_work_test() -> Nil {
  let queue =
    work_queue.new(overload.worker_limits(), overload.WorkerQueue, False, fn() {
      Nil
    })
  let assert Ok(reservation) = work_queue.publish(queue, 1, 0)
  work_queue.close(queue)
  work_queue.publish(queue, 2, 0) |> should.equal(Error(overload.Closed))
  work_queue.take(queue) |> should.equal(Ok(#(reservation, 1)))
}

pub fn concurrent_publication_obeys_both_limits_test() -> Nil {
  let assert Ok(limits) = overload.limits(items: 8, bytes: 12)
  let queue = work_queue.new(limits, overload.WorkerQueue, False, fn() { Nil })
  let results = process.new_subject()
  list.repeat(Nil, 64)
  |> list.each(fn(value) {
    let _producer =
      process.spawn_unlinked(fn() {
        process.send(results, work_queue.publish(queue, value, 2))
      })
  })
  let accepted =
    list.repeat(Nil, 64)
    |> list.filter_map(fn(_) {
      let assert Ok(result) = process.receive(results, 2000)
      result
    })
  list.length(accepted) |> should.equal(6)
  let assert Ok(snapshot) = work_queue.snapshot(queue)
  snapshot.items |> should.equal(6)
  snapshot.bytes |> should.equal(12)
  list.each(accepted, work_queue.release(queue, _))
  let assert Ok(empty) = work_queue.snapshot(queue)
  empty.items |> should.equal(0)
  empty.bytes |> should.equal(0)
}

pub fn producer_crash_after_publication_does_not_lose_work_test() -> Nil {
  let entered = process.new_subject()
  let queue =
    work_queue.new(overload.worker_limits(), overload.WorkerQueue, False, fn() {
      process.send(entered, Nil)
      let blocked = process.new_subject()
      process.receive_forever(blocked)
    })
  let producer =
    process.spawn_unlinked(fn() {
      let assert Ok(_) = work_queue.publish(queue, "published", 9)
    })
  process.receive(entered, 1000) |> should.equal(Ok(Nil))
  let monitor = process.monitor(producer)
  process.kill(producer)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  let assert Ok(#(reservation, message)) = work_queue.take(queue)
  message |> should.equal("published")
  work_queue.release(queue, reservation)
  let assert Ok(snapshot) = work_queue.snapshot(queue)
  snapshot.items |> should.equal(0)
}

pub fn owner_crash_invalidates_queue_test() -> Nil {
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let queue =
        work_queue.new(
          overload.worker_limits(),
          overload.WorkerQueue,
          False,
          fn() { Nil },
        )
      process.send(ready, queue)
      let blocked = process.new_subject()
      process.receive_forever(blocked)
    })
  let assert Ok(queue) = process.receive(ready, 1000)
  let assert Ok(reservation) = work_queue.publish(queue, 1, 1)
  let monitor = process.monitor(owner)
  process.kill(owner)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  work_queue.publish(queue, 2, 1) |> should.equal(Error(overload.Unavailable))
  work_queue.snapshot(queue) |> should.equal(Error(overload.Unavailable))
  work_queue.release(queue, reservation)
}

pub fn published_report_survives_producer_cleanup_test() -> Nil {
  let entered = process.new_subject()
  let assert Ok(limits) = overload.limits(items: 1, bytes: 128)
  let queue =
    work_queue.new(limits, overload.SocketQueue, False, fn() {
      process.send(entered, Nil)
      process.receive_forever(process.new_subject())
    })
  let producer =
    process.spawn_unlinked(fn() {
      let assert Ok(reservation) = work_queue.retain(queue, Nil)
      let assert Ok(_) =
        work_queue.publish_reserved(queue, reservation, "report")
    })
  process.receive(entered, 1000) |> should.equal(Ok(Nil))
  let monitor = process.monitor(producer)
  process.kill(producer)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  work_queue.release_producer(queue, producer)
  let assert Ok(before) = work_queue.snapshot(queue)
  before.items |> should.equal(1)
  let assert Ok(#(reservation, "report")) = work_queue.take(queue)
  work_queue.release_producer(queue, producer)
  let assert Ok(running) = work_queue.snapshot(queue)
  running.items |> should.equal(1)
  work_queue.publish_reserved(queue, reservation, "duplicate")
  |> should.equal(Error(overload.Closed))
  work_queue.release(queue, reservation)
  let assert Ok(empty) = work_queue.snapshot(queue)
  empty.items |> should.equal(0)
}

pub fn retained_resize_cannot_exceed_aggregate_bytes_test() -> Nil {
  let assert Ok(limits) = overload.limits(items: 2, bytes: 32)
  let queue = work_queue.new(limits, overload.SocketQueue, False, fn() { Nil })
  let assert Ok(first) = work_queue.retain(queue, Nil)
  let assert Ok(second) = work_queue.retain(queue, Nil)
  work_queue.resize(queue, first, #(Nil, Nil)) |> should.equal(Ok(Nil))
  work_queue.resize(queue, first, #(Nil, Nil, Nil))
  |> should.equal(Error(overload.Overloaded(overload.SocketQueue)))
  work_queue.resize(queue, first, #(Nil, Nil, Nil, Nil))
  |> should.equal(Error(overload.ItemTooLarge(overload.SocketQueue)))
  let assert Ok(full) = work_queue.snapshot(queue)
  full.items |> should.equal(2)
  full.bytes |> should.equal(32)
  full.rejected |> should.equal(2)
  work_queue.release(queue, first)
  work_queue.release(queue, second)
  let assert Ok(empty) = work_queue.snapshot(queue)
  empty.bytes |> should.equal(0)
}

pub fn cleanup_is_reserved_and_coalesced_under_saturation_test() -> Nil {
  let assert Ok(limits) = overload.limits(items: 2, bytes: 1024)
  let queue =
    work_queue.new(limits, overload.PresenceQueue, False, fn() { Nil })
  let assert Ok(mutation) =
    work_queue.publish_with_cleanup(queue, "session", "track", "cleanup")
  work_queue.send(queue, "extra")
  |> should.equal(Error(overload.Overloaded(overload.PresenceQueue)))
  work_queue.take(queue) |> should.equal(Ok(#(mutation, "track")))
  work_queue.release(queue, mutation)
  let assert Ok(other) = work_queue.publish_value(queue, "other")
  work_queue.activate_cleanup(queue, "session") |> should.equal(Ok(Nil))
  work_queue.activate_cleanup(queue, "session") |> should.equal(Ok(Nil))
  let assert Ok(full) = work_queue.snapshot(queue)
  full.items |> should.equal(2)
  work_queue.take(queue) |> should.equal(Ok(#(other, "other")))
  work_queue.release(queue, other)
  let assert Ok(#(cleanup, "cleanup")) = work_queue.take(queue)
  work_queue.release(queue, cleanup)
  work_queue.take(queue) |> should.equal(Error(Nil))
  let assert Ok(empty) = work_queue.snapshot(queue)
  empty.items |> should.equal(0)
  let assert Ok(next) =
    work_queue.publish_with_cleanup(queue, "session", "track", "cleanup")
  work_queue.release(queue, next)
  work_queue.activate_cleanup(queue, "session") |> should.equal(Ok(Nil))
  let assert Ok(#(cleanup, "cleanup")) = work_queue.take(queue)
  work_queue.release(queue, cleanup)
}

pub fn abandoned_provisional_resource_is_cleaned_once_test() -> Nil {
  let ready = process.new_subject()
  let cleaned = process.new_subject()
  let queue =
    work_queue.new(overload.worker_limits(), overload.RouterQueue, False, fn() {
      Nil
    })
  let producer =
    process.spawn_unlinked(fn() {
      let assert Ok(reservation) = work_queue.retain(queue, "provisional")
      work_queue.attach_cleanup(queue, reservation, fn() {
        process.send(cleaned, Nil)
      })
      |> should.equal(Ok(Nil))
      process.send(ready, reservation)
      process.receive_forever(process.new_subject())
    })
  let assert Ok(reservation) = process.receive(ready, 1000)
  let monitor = process.monitor(producer)
  process.kill(producer)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  work_queue.recover(queue)
  process.receive(cleaned, 0) |> should.equal(Ok(Nil))
  work_queue.recover(queue)
  work_queue.release(queue, reservation)
  process.receive(cleaned, 0) |> should.equal(Error(Nil))
  work_queue.attach_cleanup(queue, reservation, fn() { Nil })
  |> should.equal(Error(overload.Closed))
  let assert Ok(empty) = work_queue.snapshot(queue)
  empty.items |> should.equal(0)
  empty.cancelled |> should.equal(1)
}
