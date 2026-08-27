function value(env, name, fallback = "unknown") {
  const result = String(env[name] ?? fallback).trim();
  return result || fallback;
}

export function resultMetadata(
  profile,
  effective = {},
  env = globalThis.__ENV ?? {},
) {
  return Object.freeze({
    schema_version: 1,
    profile,
    git: value(env, "GIT_SHA"),
    transport: value(env, "TRANSPORT"),
    runtime: value(env, "RUNTIME"),
    hardware: value(env, "HARDWARE"),
    source_ip: value(env, "SOURCE_IP"),
    cluster: value(env, "CLUSTER", "single-node"),
    load_generator: value(env, "LOAD_GENERATOR", "local"),
    load_generator_index: value(env, "LOAD_GENERATOR_INDEX", "0"),
    segmentation: {
      execution_segment: value(env, "EXECUTION_SEGMENT", "0:1"),
      execution_segment_sequence: value(
        env,
        "EXECUTION_SEGMENT_SEQUENCE",
        "0,1",
      ),
      load_generator_index: value(env, "LOAD_GENERATOR_INDEX", "0"),
      load_generator_count: value(env, "LOAD_GENERATOR_COUNT", "1"),
    },
    target_label: value(env, "TARGET_LABEL"),
    run_id: value(env, "RUN_ID", "unassigned"),
    target_count: effective.targetCount ?? 0,
    executor: effective.executor ?? {},
    workload: effective.workload ?? {},
    session: effective.session ?? {},
  });
}

export function summaryPath(profile, env = globalThis.__ENV ?? {}) {
  return value(env, "SUMMARY_PATH", `load/results/${profile}-summary.json`);
}

export function buildSummary(
  data,
  profile,
  effective = {},
  env = globalThis.__ENV ?? {},
) {
  return {
    metadata: resultMetadata(profile, effective, env),
    result: data,
  };
}
