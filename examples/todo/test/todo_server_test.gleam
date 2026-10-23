import beryl
import beryl/socket
import beryl/transport
import gleam/erlang/process
import gleam/option.{None}
import gleeunit
import gleeunit/should
import todo_server
import todo_server/store

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn store_restart_replaces_runtime_before_reusing_ids_test() -> Nil {
  let #(sockets, store) = todo_server.start_system()
  let assert Ok(_) = store.add(store, "Old state")
  let assert Ok(owner) = transport.runtime_pid(sockets)
  transport.admit_socket(
    sockets: sockets,
    owner: owner,
    socket_id: "restart-test",
    send: fn(_) { Ok(Nil) },
    send_binary: fn(_) { Ok(Nil) },
    codec: None,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
  |> should.equal(Ok(Nil))

  let monitor = process.monitor(owner)
  let assert Ok(store_pid) = store.process_id(store)
  process.kill(store_pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  await_empty_store(store, 100)
  await_runtime(sockets, owner, 100)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

fn await_runtime(
  sockets: beryl.Sockets,
  previous: process.Pid,
  attempts: Int,
) -> Nil {
  case transport.runtime_pid(sockets), attempts {
    Ok(current), _ if current != previous -> Nil
    _, 0 -> should.fail()
    _, _ -> {
      process.sleep(10)
      await_runtime(sockets, previous, attempts - 1)
    }
  }
}

fn await_empty_store(store: store.Store, attempts: Int) -> Nil {
  case store.all(store), attempts {
    Ok([]), _ -> Nil
    _, 0 -> should.fail()
    _, _ -> {
      process.sleep(10)
      await_empty_store(store, attempts - 1)
    }
  }
}
