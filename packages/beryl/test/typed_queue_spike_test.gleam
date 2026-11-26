//// Expanded test-only queue spike, including real generated actor code.

import beryl/app_supervisor
import beryl/overload
import beryl/typed_work_queue as typed
import beryl/work_queue
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should
import test_helper
import unitest

type Request {
  Request(reply: fn(Int) -> Nil)
}

@external(erlang, "beryl_typed_queue_spike_ffi", "with_fixtures")
fn with_fixtures(action: fn() -> Nil) -> Nil

@external(erlang, "beryl_typed_queue_spike_ffi", "run_contracts")
fn existing_data_contracts() -> Nil

@external(erlang, "beryl_typed_queue_spike_ffi", "arm_cas_hook")
fn arm_cas_hook(action: fn() -> Nil) -> Nil

@external(erlang, "beryl_typed_queue_spike_ffi", "start_app_supervisor")
fn start_app_supervisor(
  name: process.Name(app_supervisor.Message),
  stop_runtime: fn(process.Subject(app_supervisor.StopCompletion)) ->
    Result(process.Monitor, Nil),
  start_supervisor: fn() ->
    Result(actor.Started(static_supervisor.Supervisor), actor.StartError),
) -> Result(actor.Started(static_supervisor.Supervisor), actor.StartError)

@external(erlang, "beryl_typed_queue_spike_ffi", "request_app_stop")
fn request_app_stop(
  name: process.Name(app_supervisor.Message),
  finished: process.Subject(app_supervisor.StopCompletion),
) -> Result(#(app_supervisor.StopAcceptance, process.Pid), overload.CallError)

@external(erlang, "beryl_typed_queue_spike_ffi", "measure")
fn measure(action: fn() -> Nil, repetitions: Int) -> #(Int, Int)

@external(erlang, "beryl_typed_queue_spike_ffi", "legacy_words")
fn legacy_words(queue: work_queue.Queue(message)) -> Int

// nolint: unused_exports -- discovered by unitest
/// Run existing contracts against the typed ledger, then forced races and actors.
pub fn typed_ledger_feasibility_test() -> Nil {
  use <- unitest.tag("serial")
  use <- with_fixtures()
  use <- test_helper.with_isolated_caller(30_000)
  existing_data_contracts()
  publication_retry_after_close()
  reservation_retry_after_reclamation()
  release_retry_runs_cleanup_once()
  running_timeout_drops_late_alias_replies()
  owner_death_rejects()
  owner_death_finishes_waiting_call()
  generic_callback_payload()
  selective_take_preserves_order()
  reservation_identity_can_be_a_cleanup_key()
  actor_stop_rejection_releases_credit()
  actor_stop_acceptance_keeps_credit()
}

fn publication_retry_after_close() -> Nil {
  let entered = process.new_subject()
  let finished = process.new_subject()
  let wakes = process.new_subject()
  let queue =
    typed.new(overload.worker_limits(), overload.WorkerQueue, False, fn() {
      process.send(wakes, Nil)
    })
  let _producer =
    process.spawn(fn() {
      let resume = process.new_subject()
      arm_cas_hook(fn() {
        process.send(entered, resume)
        process.receive(resume, 2000) |> should.equal(Ok(Nil))
      })
      process.send(finished, typed.publish(queue, "stale", 1))
    })
  let assert Ok(resume) = process.receive(entered, 2000)
  typed.close(queue)
  process.send(resume, Nil)
  process.receive(finished, 2000) |> should.equal(Ok(Error(overload.Closed)))
  process.receive(wakes, 0) |> should.equal(Error(Nil))
  let assert Ok(empty) = typed.snapshot(queue)
  #(empty.items, empty.bytes, empty.rejected) |> should.equal(#(0, 0, 1))
}

fn reservation_retry_after_reclamation() -> Nil {
  let entered = process.new_subject()
  let finished = process.new_subject()
  let cleaned = process.new_subject()
  let queue =
    typed.new(overload.worker_limits(), overload.WorkerQueue, False, fn() {
      Nil
    })
  let assert Ok(reservation) = typed.retain(queue, Nil)
  typed.attach_cleanup(queue, reservation, fn() {
    let assert Ok(snapshot) = typed.snapshot(queue)
    #(snapshot.items, snapshot.bytes) |> should.equal(#(0, 0))
    process.send(cleaned, Nil)
  })
  |> should.equal(Ok(Nil))
  let _producer =
    process.spawn(fn() {
      let resume = process.new_subject()
      arm_cas_hook(fn() {
        process.send(entered, resume)
        process.receive(resume, 2000) |> should.equal(Ok(Nil))
      })
      process.send(
        finished,
        typed.publish_reserved(queue, reservation, "stale"),
      )
    })
  let assert Ok(resume) = process.receive(entered, 2000)
  typed.release_producer(queue, process.self())
  process.receive(cleaned, 0) |> should.equal(Ok(Nil))
  process.send(resume, Nil)
  process.receive(finished, 2000) |> should.equal(Ok(Error(overload.Closed)))
  typed.release(queue, reservation)
  process.receive(cleaned, 0) |> should.equal(Error(Nil))
  let assert Ok(empty) = typed.snapshot(queue)
  #(empty.items, empty.bytes, empty.cancelled, empty.rejected)
  |> should.equal(#(0, 0, 1, 1))
}

fn release_retry_runs_cleanup_once() -> Nil {
  let entered = process.new_subject()
  let finished = process.new_subject()
  let cleaned = process.new_subject()
  let queue =
    typed.new(overload.worker_limits(), overload.WorkerQueue, False, fn() {
      Nil
    })
  let assert Ok(reservation) = typed.retain(queue, Nil)
  typed.attach_cleanup(queue, reservation, fn() { process.send(cleaned, Nil) })
  |> should.equal(Ok(Nil))
  let _releaser =
    process.spawn(fn() {
      let resume = process.new_subject()
      arm_cas_hook(fn() {
        process.send(entered, resume)
        process.receive(resume, 2000) |> should.equal(Ok(Nil))
      })
      typed.release(queue, reservation)
      process.send(finished, Nil)
    })
  let assert Ok(resume) = process.receive(entered, 2000)
  process.receive(cleaned, 0) |> should.equal(Error(Nil))
  typed.release(queue, reservation)
  process.receive(cleaned, 0) |> should.equal(Ok(Nil))
  process.send(resume, Nil)
  process.receive(finished, 2000) |> should.equal(Ok(Nil))
  process.receive(cleaned, 0) |> should.equal(Error(Nil))
}

fn running_timeout_drops_late_alias_replies() -> Nil {
  let ready = process.new_subject()
  let finished = process.new_subject()
  let wakes = process.new_subject()
  let queue =
    typed.new(overload.worker_limits(), overload.WorkerQueue, False, fn() {
      let published = process.new_subject()
      process.send(wakes, published)
      process.receive(published, 2000) |> should.equal(Ok(Nil))
    })
  let caller =
    process.spawn(fn() {
      let resume = process.new_subject()
      process.send(ready, resume)
      process.send(finished, typed.call(queue, 100, Request))
      process.receive(resume, 2000) |> should.equal(Ok(Nil))
    })
  let monitor = process.monitor(caller)
  let assert Ok(resume) = process.receive(ready, 2000)
  let assert Ok(published) = process.receive(wakes, 2000)
  let delayed = process.new_subject()
  let _timer = process.send_after(delayed, 150, Nil)
  process.receive(delayed, 2000) |> should.equal(Ok(Nil))
  let assert Ok(#(reservation, Request(reply))) = typed.take(queue)
  process.send(published, Nil)
  process.receive(finished, 2000)
  |> should.equal(Ok(Error(overload.RequestTimedOut)))
  let assert Ok(running) = typed.snapshot(queue)
  running.items |> should.equal(1)
  reply(7)
  reply(8)
  test_helper.mailbox_length(caller) |> should.equal(0)
  typed.release(queue, reservation)
  process.send(resume, Nil)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(down) { down })
  |> process.selector_receive(2000)
  |> should.be_ok()
  Nil
}

fn owner_death_rejects() -> Nil {
  let ready = process.new_subject()
  let owner =
    process.spawn(fn() {
      let queue =
        typed.new(overload.worker_limits(), overload.WorkerQueue, False, fn() {
          Nil
        })
      process.send(ready, queue)
      process.sleep_forever()
    })
  let assert Ok(queue) = process.receive(ready, 2000)
  let assert Ok(reservation) = typed.retain(queue, Nil)
  let monitor = process.monitor(owner)
  process.unlink(owner)
  process.kill(owner)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(down) { down })
  |> process.selector_receive(2000)
  |> should.be_ok()
  typed.publish(queue, "late", 4) |> should.equal(Error(overload.Unavailable))
  typed.publish_reserved(queue, reservation, "late")
  |> should.equal(Error(overload.Unavailable))
  typed.snapshot(queue) |> should.equal(Error(overload.Unavailable))
  typed.release(queue, reservation)
}

fn owner_death_finishes_waiting_call() -> Nil {
  let ready = process.new_subject()
  let finished = process.new_subject()
  let owner =
    process.spawn(fn() {
      let queue =
        typed.new(overload.worker_limits(), overload.WorkerQueue, False, fn() {
          Nil
        })
      process.send(ready, queue)
      process.sleep_forever()
    })
  let assert Ok(queue) = process.receive(ready, 2000)
  let _caller =
    process.spawn(fn() {
      process.send(finished, typed.call(queue, 2000, Request))
    })
  test_helper.wait_until(
    fn() {
      let assert Ok(snapshot) = typed.snapshot(queue)
      snapshot.items == 1
    },
    2000,
    1,
  )
  let monitor = process.monitor(owner)
  process.unlink(owner)
  process.kill(owner)
  process.receive(finished, 2000)
  |> should.equal(Ok(Error(overload.OwnerUnavailable)))
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(down) { down })
  |> process.selector_receive(2000)
  |> should.be_ok()
  Nil
}

fn generic_callback_payload() -> Nil {
  let captured = list.repeat(1, 10_000)
  let callback = fn(value: Int) { value + list.length(captured) }
  let assert Ok(limits) = overload.limits(items: 1, bytes: 8)
  let queue = typed.new(limits, overload.WorkerQueue, False, fn() { Nil })
  let assert Ok(reservation) = typed.retain(queue, Nil)
  typed.publish_reserved(queue, reservation, callback)
  |> should.equal(Ok(reservation))
  let assert Ok(#(taken, update)) = typed.take(queue)
  taken |> should.equal(reservation)
  update(3) |> should.equal(10_003)
  let assert Ok(charged) = typed.snapshot(queue)
  charged.bytes |> should.equal(8)
  typed.release(queue, taken)
}

fn selective_take_preserves_order() -> Nil {
  let queue =
    typed.new(overload.worker_limits(), overload.WorkerQueue, False, fn() {
      Nil
    })
  let assert Ok(first) = typed.publish(queue, 1, 8)
  let assert Ok(second) = typed.publish(queue, 2, 8)
  let assert Ok(third) = typed.publish(queue, 3, 8)
  typed.take_matching(queue, fn(value) { value == 2 })
  |> should.equal(Ok(#(second, 2)))
  typed.cancel_pending(queue, second)
  let assert Ok(running) = typed.snapshot(queue)
  running.items |> should.equal(3)
  typed.take(queue) |> should.equal(Ok(#(first, 1)))
  typed.take(queue) |> should.equal(Ok(#(third, 3)))
  list.each([first, second, third], typed.release(queue, _))
  typed.take(queue) |> should.equal(Error(work_queue.Empty))
}

fn reservation_identity_can_be_a_cleanup_key() -> Nil {
  let queue =
    typed.new(overload.worker_limits(), overload.WorkerQueue, False, fn() {
      Nil
    })
  let assert Ok(key) = typed.publish(queue, "first", 8)
  let assert Ok(mutation) =
    typed.publish_with_cleanup(queue, key, "mutation", "cleanup")
  typed.release(queue, key)
  typed.activate_cleanup(queue, key) |> should.equal(Ok(Nil))
  typed.take(queue) |> should.equal(Ok(#(mutation, "mutation")))
  typed.release(queue, mutation)
  let assert Ok(#(cleanup, "cleanup")) = typed.take(queue)
  typed.release(queue, cleanup)
  let assert Ok(empty) = typed.snapshot(queue)
  #(empty.items, empty.bytes) |> should.equal(#(0, 0))
  let assert Ok(reused) =
    typed.publish_with_cleanup(queue, key, "again", "cleanup")
  typed.release(queue, reused)
  typed.activate_cleanup(queue, key) |> should.equal(Ok(Nil))
  let assert Ok(#(cleanup, "cleanup")) = typed.take(queue)
  typed.release(queue, cleanup)
  let assert Ok(empty) = typed.snapshot(queue)
  #(empty.items, empty.bytes) |> should.equal(#(0, 0))
}

fn actor_stop_rejection_releases_credit() -> Nil {
  let nested = process.new_subject()
  let name = process.new_name("typed_rejected_stop")
  let finished = process.new_subject()
  let assert Ok(started) =
    start_app_supervisor(name, fn(_) { Error(Nil) }, fn() {
      let assert Ok(supervisor) =
        static_supervisor.new(static_supervisor.OneForOne)
        |> static_supervisor.start()
      process.send(nested, supervisor.pid)
      Ok(supervisor)
    })
  let assert Ok(supervisor) = process.receive(nested, 2000)
  let assert Ok(queue) = typed.lookup(name)
  list.repeat(Nil, 3)
  |> list.each(fn(_) {
    request_app_stop(name, finished)
    |> should.equal(Ok(#(app_supervisor.StopRejected, started.pid)))
    test_helper.wait_until(
      fn() {
        let assert Ok(snapshot) = typed.snapshot(queue)
        snapshot.items == 0 && snapshot.bytes == 0
      },
      2000,
      1,
    )
  })
  let monitor = process.monitor(started.pid)
  process.unlink(started.pid)
  process.kill(supervisor)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(down) { down })
  |> process.selector_receive(2000)
  |> should.be_ok()
  typed.snapshot(queue) |> should.equal(Error(overload.Unavailable))
}

fn actor_stop_acceptance_keeps_credit() -> Nil {
  let caller = process.self()
  let nested = process.new_subject()
  let runtime = process.new_subject()
  let finished = process.new_subject()
  let name = process.new_name("typed_accepted_stop")
  let assert Ok(started) =
    start_app_supervisor(
      name,
      fn(completed) {
        process.send(runtime, completed)
        Ok(process.monitor(caller))
      },
      fn() {
        let assert Ok(supervisor) =
          static_supervisor.new(static_supervisor.OneForOne)
          |> static_supervisor.start()
        process.send(nested, supervisor.pid)
        Ok(supervisor)
      },
    )
  let assert Ok(supervisor) = process.receive(nested, 2000)
  let assert Ok(queue) = typed.lookup(name)
  request_app_stop(name, finished)
  |> should.equal(Ok(#(app_supervisor.StopAccepted, started.pid)))
  let assert Ok(completed) = process.receive(runtime, 2000)
  let assert Ok(running) = typed.snapshot(queue)
  running.items |> should.equal(1)
  request_app_stop(name, finished)
  |> should.equal(
    Error(overload.AdmissionRejected(overload.Overloaded(overload.RouterQueue))),
  )
  let monitor = process.monitor(started.pid)
  process.unlink(started.pid)
  process.send(completed, app_supervisor.StopCompleted)
  process.kill(supervisor)
  process.receive(finished, 2000)
  |> should.equal(Ok(app_supervisor.StopCompleted))
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(down) { down })
  |> process.selector_receive(2000)
  |> should.be_ok()
  typed.snapshot(queue) |> should.equal(Error(overload.Unavailable))
}

// nolint: unused_exports -- discovered by unitest
/// Measure bounded publish/take/release cycles, not task execution or network I/O.
pub fn typed_ledger_measurement_test() -> Nil {
  use <- unitest.tag("serial")
  use <- test_helper.with_isolated_caller(30_000)
  io.println("backend,occupancy,sample,cycles,elapsed_us,reductions,ets_words")
  list.each([0, 32, 128], fn(occupancy) {
    list.each([1, 2, 3], fn(sample) {
      case sample {
        2 -> {
          typed_measurement(occupancy, sample)
          native_measurement(occupancy, sample)
        }
        _ -> {
          native_measurement(occupancy, sample)
          typed_measurement(occupancy, sample)
        }
      }
    })
  })
}

fn native_measurement(occupancy: Int, sample: Int) -> Nil {
  use <- test_helper.with_isolated_caller(5000)
  let assert Ok(limits) =
    overload.limits(items: occupancy + 1, bytes: 1_048_576)
  let queue = work_queue.new(limits, overload.WorkerQueue, False, fn() { Nil })
  list.repeat(Nil, occupancy)
  |> list.each(fn(_) {
    let assert Ok(_) = work_queue.publish(queue, 42, 8)
  })
  let cycle = fn() {
    let assert Ok(_) = work_queue.publish(queue, 42, 8)
    let assert Ok(#(reservation, 42)) = work_queue.take(queue)
    work_queue.release(queue, reservation)
  }
  cycle()
  let #(elapsed, reductions) = measure(cycle, 1000)
  let assert Ok(snapshot) = work_queue.snapshot(queue)
  snapshot.items |> should.equal(occupancy)
  print_measurement(
    "native",
    occupancy,
    sample,
    elapsed,
    reductions,
    legacy_words(queue),
  )
}

fn typed_measurement(occupancy: Int, sample: Int) -> Nil {
  use <- test_helper.with_isolated_caller(5000)
  let assert Ok(limits) =
    overload.limits(items: occupancy + 1, bytes: 1_048_576)
  let queue = typed.new(limits, overload.WorkerQueue, False, fn() { Nil })
  list.repeat(Nil, occupancy)
  |> list.each(fn(_) {
    let assert Ok(_) = typed.publish(queue, 42, 8)
  })
  let cycle = fn() {
    let assert Ok(_) = typed.publish(queue, 42, 8)
    let assert Ok(#(reservation, 42)) = typed.take(queue)
    typed.release(queue, reservation)
  }
  cycle()
  let #(elapsed, reductions) = measure(cycle, 1000)
  let assert Ok(snapshot) = typed.snapshot(queue)
  snapshot.items |> should.equal(occupancy)
  print_measurement(
    "typed",
    occupancy,
    sample,
    elapsed,
    reductions,
    typed.debug_storage_words(queue),
  )
}

fn print_measurement(
  backend: String,
  occupancy: Int,
  sample: Int,
  elapsed: Int,
  reductions: Int,
  words: Int,
) -> Nil {
  io.println(string.join(
    [
      backend,
      ..list.map(
        [occupancy, sample, 1000, elapsed, reductions, words],
        int.to_string,
      )
    ],
    ",",
  ))
}
