import beryl/overload
import beryl/work_queue
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import unitest

@external(erlang, "beryl_work_queue_race_test_ffi", "registry_races")
fn target_registry_cas_races() -> Nil

@external(erlang, "beryl_test_process_ffi", "queue_ledger_bytes")
fn queue_ledger_bytes(queue: work_queue.Queue(message)) -> Int

/// Force stale-row and FIFO CAS races against an isolated copy of the queue.
pub fn target_registry_cas_races_test() -> Nil {
  use <- unitest.tag("serial")
  target_registry_cas_races()
}

/// Idle target rows must not increase the data CAS ledger's serialized size.
pub fn registered_targets_do_not_grow_the_data_ledger_test() -> Nil {
  let router =
    work_queue.new(overload.worker_limits(), overload.RouterQueue, False, fn() {
      Nil
    })
  let target =
    work_queue.new(overload.worker_limits(), overload.SocketQueue, False, fn() {
      Nil
    })
  let before = queue_ledger_bytes(router)
  int.range(from: 1, to: 1001, with: Nil, run: fn(_, key) {
    work_queue.register_target(router, int.to_string(key), target)
  })
  queue_ledger_bytes(router) |> should.equal(before)
  let assert Ok(reservation) = work_queue.publish(router, "data", 4)
  work_queue.take(router) |> should.equal(Ok(#(reservation, "data")))
  work_queue.release(router, reservation)
  work_queue.take(router) |> should.equal(Error(work_queue.Empty))
  int.range(from: 1, to: 1001, with: Nil, run: fn(_, key) {
    work_queue.remove_target(router, int.to_string(key))
  })
}

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
  work_queue.take(queue) |> should.equal(Error(work_queue.Empty))
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
  let assert Error(work_queue.Empty) = work_queue.take(queue)
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

pub fn normal_close_ignores_late_closed_then_records_overload_once_test() -> Nil {
  let assert Ok(limits) = overload.limits(items: 1, bytes: 8)
  let queue = work_queue.new(limits, overload.SocketQueue, False, fn() { Nil })
  let router = work_queue.new(limits, overload.RouterQueue, False, fn() { Nil })
  let assert Ok(pending) = work_queue.publish(queue, "pending", 8)
  let assert Ok(router_work) = work_queue.publish(router, "busy", 8)
  work_queue.close(queue)
  let assert Error(late_error) = work_queue.publish(queue, "late", 4)
  late_error |> should.equal(overload.Closed)
  work_queue.close_with_error(queue, late_error) |> should.be_false()
  work_queue.close_reason(queue) |> should.equal(None)
  let assert Ok(normal) = work_queue.snapshot(queue)
  normal.items |> should.equal(1)
  normal.bytes |> should.equal(8)

  let assert Error(fatal) = work_queue.publish(router, "index", 1)
  fatal |> should.equal(overload.Overloaded(overload.RouterQueue))
  work_queue.close_with_error(queue, fatal) |> should.be_true()
  list.each(
    [
      fatal,
      overload.Closed,
      overload.Unavailable,
      overload.ItemTooLarge(overload.CallbackBatch),
    ],
    fn(error) {
      work_queue.close_with_error(queue, error) |> should.be_false()
      work_queue.close_reason(queue) |> should.equal(Some(fatal))
    },
  )
  work_queue.close(queue)
  work_queue.is_open(queue) |> should.be_false()
  let assert Ok(aborted) = work_queue.snapshot(queue)
  aborted.items |> should.equal(1)
  aborted.bytes |> should.equal(8)
  work_queue.take(queue) |> should.equal(Ok(#(pending, "pending")))
  let assert Ok(running) = work_queue.snapshot(queue)
  running.items |> should.equal(1)
  running.bytes |> should.equal(8)
  work_queue.release(queue, pending)
  let assert Ok(empty) = work_queue.snapshot(queue)
  empty.items |> should.equal(0)
  empty.bytes |> should.equal(0)
  work_queue.take(queue) |> should.equal(Error(work_queue.Empty))
  work_queue.release(router, router_work)
}

pub fn admission_close_preserves_first_error_for_all_variants_test() -> Nil {
  list.each(
    [
      overload.Closed,
      overload.Unavailable,
      overload.Overloaded(overload.RouterQueue),
      overload.ItemTooLarge(overload.CallbackBatch),
    ],
    fn(error) {
      let queue =
        work_queue.new(
          overload.worker_limits(),
          overload.SocketQueue,
          False,
          fn() { Nil },
        )
      work_queue.close_with_error(queue, error) |> should.be_true()
      work_queue.close_with_error(queue, overload.Unavailable)
      |> should.be_false()
      work_queue.close_reason(queue) |> should.equal(Some(error))
      work_queue.is_open(queue) |> should.be_false()
    },
  )
}

pub fn normal_close_can_record_unavailable_or_item_too_large_test() -> Nil {
  list.each(
    [overload.Unavailable, overload.ItemTooLarge(overload.CallbackBatch)],
    fn(error) {
      let queue =
        work_queue.new(
          overload.worker_limits(),
          overload.SocketQueue,
          False,
          fn() { Nil },
        )
      let assert Ok(pending) = work_queue.publish(queue, "pending", 8)
      work_queue.close(queue)
      work_queue.close_with_error(queue, overload.Closed) |> should.be_false()
      work_queue.close_with_error(queue, error) |> should.be_true()
      work_queue.close_with_error(queue, error) |> should.be_false()
      work_queue.close_reason(queue) |> should.equal(Some(error))
      let assert Ok(charged) = work_queue.snapshot(queue)
      charged.items |> should.equal(1)
      charged.bytes |> should.equal(8)
      work_queue.release(queue, pending)
      work_queue.take(queue) |> should.equal(Error(work_queue.Empty))
      let assert Ok(empty) = work_queue.snapshot(queue)
      empty.items |> should.equal(0)
      empty.bytes |> should.equal(0)
    },
  )
}

pub fn target_close_waits_for_router_fifo_without_using_data_capacity_test() -> Nil {
  let assert Ok(limits) = overload.limits(items: 1, bytes: 8)
  let router = work_queue.new(limits, overload.RouterQueue, False, fn() { Nil })
  let target = work_queue.new(limits, overload.SocketQueue, False, fn() { Nil })
  work_queue.register_target(router, "socket", target)
  let assert Ok(first) = work_queue.publish(router, "first", 8)
  work_queue.close_target(router, "socket")
  let assert Ok(full) = work_queue.snapshot(router)
  full.items |> should.equal(1)
  full.bytes |> should.equal(8)
  full.high_items |> should.equal(1)
  work_queue.is_open(target) |> should.be_true()
  work_queue.take(router) |> should.equal(Ok(#(first, "first")))
  work_queue.is_open(target) |> should.be_true()
  work_queue.release(router, first)
  let assert Ok(second) = work_queue.publish(router, "second", 8)
  work_queue.take(router) |> should.equal(Ok(#(second, "second")))
  work_queue.is_open(target) |> should.be_false()
  work_queue.release(router, second)
  work_queue.take(router) |> should.equal(Error(work_queue.Empty))
  let assert Ok(empty) = work_queue.snapshot(router)
  empty.items |> should.equal(0)
  empty.bytes |> should.equal(0)
}

pub fn concurrent_target_closes_coalesce_until_removal_test() -> Nil {
  let wakes = process.new_subject()
  let closed = process.new_subject()
  let completed = process.new_subject()
  let router =
    work_queue.new(overload.worker_limits(), overload.RouterQueue, False, fn() {
      process.send(wakes, Nil)
    })
  let target =
    work_queue.new(overload.worker_limits(), overload.SocketQueue, False, fn() {
      process.send(closed, Nil)
    })
  work_queue.register_target(router, "socket", target)
  list.repeat(Nil, 32)
  |> list.each(fn(_) {
    let _producer =
      process.spawn_unlinked(fn() {
        work_queue.close_target(router, "socket")
        process.send(completed, Nil)
      })
  })
  list.repeat(Nil, 32)
  |> list.each(fn(_) {
    process.receive(completed, 1000) |> should.equal(Ok(Nil))
  })
  process.receive(wakes, 0) |> should.equal(Ok(Nil))
  process.receive(wakes, 0) |> should.equal(Error(Nil))
  work_queue.is_open(target) |> should.be_true()
  work_queue.take(router) |> should.equal(Error(work_queue.Empty))
  process.receive(closed, 0) |> should.equal(Ok(Nil))
  work_queue.close_target(router, "socket")
  work_queue.take(router) |> should.equal(Error(work_queue.Empty))
  process.receive(wakes, 0) |> should.equal(Error(Nil))
  process.receive(closed, 0) |> should.equal(Error(Nil))
  work_queue.remove_target(router, "socket")
}

pub fn removing_or_replacing_target_cancels_its_queued_close_test() -> Nil {
  let router =
    work_queue.new(overload.worker_limits(), overload.RouterQueue, False, fn() {
      Nil
    })
  let previous =
    work_queue.new(overload.worker_limits(), overload.SocketQueue, False, fn() {
      Nil
    })
  let current =
    work_queue.new(overload.worker_limits(), overload.SocketQueue, False, fn() {
      Nil
    })
  work_queue.register_target(router, "socket", previous)
  work_queue.close_target(router, "socket")
  work_queue.remove_target(router, "socket")
  work_queue.register_target(router, "socket", current)
  work_queue.take(router) |> should.equal(Error(work_queue.Empty))
  work_queue.is_open(previous) |> should.be_true()
  work_queue.is_open(current) |> should.be_true()
  work_queue.close_target(router, "socket")
  work_queue.register_target(router, "socket", previous)
  work_queue.take(router) |> should.equal(Error(work_queue.Empty))
  work_queue.is_open(current) |> should.be_true()
  work_queue.close_target(router, "socket")
  work_queue.take(router) |> should.equal(Error(work_queue.Empty))
  work_queue.is_open(previous) |> should.be_false()
  work_queue.is_open(current) |> should.be_true()
}

pub fn selective_take_leaves_target_close_for_fifo_drain_test() -> Nil {
  let router =
    work_queue.new(overload.worker_limits(), overload.RouterQueue, False, fn() {
      Nil
    })
  let target =
    work_queue.new(overload.worker_limits(), overload.SocketQueue, False, fn() {
      Nil
    })
  work_queue.register_target(router, "socket", target)
  let assert Ok(first) = work_queue.publish(router, 1, 0)
  work_queue.close_target(router, "socket")
  let assert Ok(second) = work_queue.publish(router, 2, 0)
  work_queue.take_matching(router, fn(value) { value == 2 })
  |> should.equal(Ok(#(second, 2)))
  work_queue.release(router, second)
  work_queue.is_open(target) |> should.be_true()
  work_queue.take(router) |> should.equal(Ok(#(first, 1)))
  work_queue.release(router, first)
  work_queue.take(router) |> should.equal(Error(work_queue.Empty))
  work_queue.is_open(target) |> should.be_false()
}

pub fn target_close_survives_publisher_exit_before_wake_test() -> Nil {
  let entered = process.new_subject()
  let router =
    work_queue.new(overload.worker_limits(), overload.RouterQueue, False, fn() {
      process.send(entered, Nil)
      process.receive_forever(process.new_subject())
    })
  let target =
    work_queue.new(overload.worker_limits(), overload.SocketQueue, False, fn() {
      Nil
    })
  work_queue.register_target(router, "socket", target)
  let producer =
    process.spawn_unlinked(fn() { work_queue.close_target(router, "socket") })
  process.receive(entered, 1000) |> should.equal(Ok(Nil))
  let monitor = process.monitor(producer)
  process.kill(producer)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  work_queue.is_open(target) |> should.be_true()
  work_queue.take(router) |> should.equal(Error(work_queue.Empty))
  work_queue.is_open(target) |> should.be_false()
}

pub fn dead_router_control_cannot_reach_replacement_router_test() -> Nil {
  let ready = process.new_subject()
  let target =
    work_queue.new(overload.worker_limits(), overload.SocketQueue, False, fn() {
      Nil
    })
  let owner =
    process.spawn_unlinked(fn() {
      let router =
        work_queue.new(
          overload.worker_limits(),
          overload.RouterQueue,
          False,
          fn() { Nil },
        )
      work_queue.register_target(router, "socket", target)
      work_queue.close_target(router, "socket")
      process.send(ready, router)
      process.receive_forever(process.new_subject())
    })
  let assert Ok(previous) = process.receive(ready, 1000)
  let monitor = process.monitor(owner)
  process.kill(owner)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  let current =
    work_queue.new(overload.worker_limits(), overload.RouterQueue, False, fn() {
      Nil
    })
  work_queue.register_target(current, "socket", target)
  work_queue.close_target(previous, "socket")
  work_queue.take(current) |> should.equal(Error(work_queue.Empty))
  work_queue.is_open(target) |> should.be_true()
  work_queue.close_target(current, "socket")
  work_queue.take(current) |> should.equal(Error(work_queue.Empty))
  work_queue.is_open(target) |> should.be_false()
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
  work_queue.close_target(queue, "socket")
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
  work_queue.take(queue) |> should.equal(Error(work_queue.Empty))
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
