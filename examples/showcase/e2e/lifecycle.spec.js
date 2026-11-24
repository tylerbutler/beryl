import { expect, test } from "@playwright/test";
import { spawnSync } from "node:child_process";

// Run the shipment's entrypoint in a separate VM so each test can stop the
// service without stopping the shared Playwright server.
function runDeployment(afterStart) {
  const script = `
    ok = code:add_pathsa(filelib:wildcard("build/dev/erlang/*/ebin")),
    spawn(fun() ->
      Wait = fun Poll(Read) ->
        case catch Read() of
          P when is_pid(P) -> P;
          _ -> timer:sleep(10), Poll(Read)
        end
      end,
      Service = Wait(fun() ->
        [{_, P, supervisor, _}] = supervisor:which_children(showcase), P
      end),
      ${afterStart}
    end),
    'showcase@@main':run(showcase).
  `;
  const run = spawnSync("erl", ["+S", "2", "-noshell", "-eval", script], {
    cwd: new URL("..", import.meta.url),
    env: { ...process.env, BIND_ADDRESS: "127.0.0.1", PORT: "0" },
    encoding: "utf8",
    timeout: 15_000,
    killSignal: "SIGKILL",
  });
  expect(run.error, run.stderr).toBeUndefined();
  return run;
}

test("the deployment exits when its service exhausts its restarts", () => {
  const run = runDeployment(`
    lists:foldl(fun(_, Previous) ->
      Owner = Wait(fun() ->
        [P] = [Pid || {_, Pid, worker, _} <- supervisor:which_children(Service),
                       is_pid(Pid), Pid =/= Previous], P
      end),
      exit(Owner, kill), Owner
    end, undefined, lists:seq(1, 4))
  `);
  expect(run.stdout + run.stderr).toContain("reached_max_restart_intensity");
  expect(run.status).toBe(1);
});

test("stopping the showcase application exits the deployment successfully", () => {
  const run = runDeployment("ok = application:stop(showcase)");
  expect(run.status, run.stderr).toBe(0);
});
