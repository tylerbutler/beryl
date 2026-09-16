#!/usr/bin/env bash

set -euo pipefail

checked=false

for src_dir in packages/*/src; do
  if [[ -z "$(find "$src_dir" -type f -name '*.erl' -print -quit)" ]]; then
    continue
  fi

  checked=true
  package_dir="$(dirname "$src_dir")"
  package="$(basename "$package_dir")"
  build_root="$package_dir/build/dev/erlang"
  package_ebin="$build_root/$package/ebin"
  path_args=()

  while IFS= read -r ebin; do
    path_args+=("-pa" "$ebin")
  done < <(find "$build_root" -mindepth 2 -maxdepth 2 -type d -name ebin -print | sort)

  echo "Xref: $package"
  PACKAGE_EBIN="$package_ebin" erl -noshell "${path_args[@]}" -eval '
    Name = beryl_ffi_xref,
    {ok, _} = xref:start(Name),
    ok = xref:set_default(Name, [{verbose, false}, {warnings, false}]),
    ok = xref:set_library_path(Name, code_path),
    {ok, _} = xref:add_directory(Name, os:getenv("PACKAGE_EBIN")),
    Result = xref:analyze(Name, undefined_function_calls),
    xref:stop(Name),
    case Result of
      {ok, []} -> halt(0);
      {ok, Calls} ->
        io:format("Undefined function calls:~n~tp~n", [Calls]),
        halt(1);
      Error ->
        io:format("Xref failed: ~tp~n", [Error]),
        halt(1)
    end.
  '
done

if [[ "$checked" == false ]]; then
  echo "No Erlang FFI source files found." >&2
  exit 1
fi
