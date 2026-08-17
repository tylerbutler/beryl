import { readFile, readdir } from "node:fs/promises";
import path from "node:path";

const combinations = [
  ["erlang-27", "mist"],
  ["erlang-27", "ewe"],
  ["erlang-28", "mist"],
  ["erlang-28", "ewe"],
];

function metricValue(summary, name, value, fallback = 0) {
  return summary?.result?.metrics?.[name]?.values?.[value] ?? fallback;
}

function milliseconds(value) {
  return `${Number(value).toFixed(1)} ms`;
}

function passed(summary) {
  return Object.values(summary?.result?.metrics ?? {}).every((metric) =>
    Object.values(metric.thresholds ?? {}).every((threshold) => threshold.ok),
  );
}

async function findSummaries(directory) {
  const summaries = new Map();
  const pending = [directory];
  while (pending.length > 0) {
    const current = pending.pop();
    for (const entry of await readdir(current, { withFileTypes: true })) {
      const entryPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        pending.push(entryPath);
      } else if (/^protocol-smoke-\d+-(mist|ewe)\.json$/.test(entry.name)) {
        const summary = JSON.parse(await readFile(entryPath, "utf8"));
        summaries.set(
          `${summary.metadata.runtime}:${summary.metadata.transport}`,
          summary,
        );
      }
    }
  }
  return summaries;
}

export async function renderSmokeComment(directory, runUrl = "") {
  const summaries = await findSummaries(directory);
  const rows = combinations.map(([runtime, transport]) => {
    const summary = summaries.get(`${runtime}:${transport}`);
    if (!summary) {
      return `| ${runtime} | ${transport} | ⚠️ Missing | — | — | — | — | — |`;
    }
    const errorCount = [
      "phoenix_client_errors",
      "phoenix_unexpected_client_errors",
      "phoenix_protocol_errors",
      "phoenix_decode_errors",
    ].reduce(
      (total, name) => total + metricValue(summary, name, "count"),
      0,
    );
    return [
      `| ${runtime} | ${transport} | ${passed(summary) ? "✅ Pass" : "❌ Fail"}`,
      milliseconds(metricValue(summary, "phoenix_ws_establish_duration", "avg")),
      milliseconds(metricValue(summary, "phoenix_join_duration", "avg")),
      milliseconds(metricValue(summary, "phoenix_push_reply_duration", "avg")),
      milliseconds(metricValue(summary, "phoenix_leave_reply_duration", "avg")),
      `${errorCount} |`,
    ].join(" | ");
  });
  const allPassed =
    summaries.size === combinations.length &&
    [...summaries.values()].every(passed);
  const runLink = runUrl ? ` [Workflow run](${runUrl}).` : "";

  return `## Protocol smoke

${allPassed ? "✅ All protocol smoke checks passed." : "❌ One or more protocol smoke checks failed or produced no summary."}${runLink}

| Runtime | Transport | Result | Connect | Join | Echo reply | Leave | Errors |
|---|---|---|---:|---:|---:|---:|---:|
${rows.join("\n")}

This smoke test starts the real load-test application and verifies the Phoenix V2 lifecycle—connect, join, marker echo, leave, and close—across Erlang 27/28 and Mist/Ewe. It gates protocol correctness and unexpected errors; the single-operation timings above are diagnostic, not performance results.

<details>
<summary><strong>How to run a real load test</strong></summary>

1. Run the target and load generator on separate, monitored hosts. Start Mist or Ewe with \`just load-server-mist\` or \`just load-server-ewe\`, then target its reachable \`ws://\` or \`wss://\` URL.
2. Pass \`protocol-smoke\`, warm the complete system without recording the result, then run at least three measured repetitions with unique \`RUN_ID\` and \`SUMMARY_PATH\` values.
3. Choose the workload for the question:
   - Connection throughput: \`RATE=100 DURATION=2m just load-run connection-rate <url> <transport>\`
   - Request latency under concurrency: \`VUS=100 DURATION=2m just load-run push-round-trip <url> <transport>\`
   - Fan-out or presence delivery: use \`broadcast-fanout\` or \`presence-churn\`.
4. Increase one variable at a time. Throughput is the highest sustained successful operation or connection rate before errors, timeouts, dropped iterations, or target saturation increase. Compare repeated-run medians and spread, not the best run.
5. Track p50/p95/p99 latency, operation success and timeout rates, \`dropped_iterations\`, generator CPU/FD/port headroom, and target CPU, BEAM run queue, runtime mailbox, connections, and transport telemetry.

See [the load-testing guide](https://github.com/${process.env.GITHUB_REPOSITORY ?? "tylerbutler/beryl"}/blob/main/load/README.md) for profile contracts, metadata, baseline discipline, and interpretation.
</details>
`;
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const directory = process.argv[2];
  if (!directory) throw new Error("artifact directory is required");
  process.stdout.write(await renderSmokeComment(directory, process.argv[3]));
}
