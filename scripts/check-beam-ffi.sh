#!/usr/bin/env bash

set -euo pipefail

mode="${1:-all}"

case "$mode" in
  all | dialyzer | xref) ;;
  *)
    echo "usage: $0 [all|dialyzer|xref]" >&2
    exit 2
    ;;
esac

checked=false

while IFS= read -r src_dir; do
  if [[ -z "$(find "$src_dir" -type f -name '*.erl' -print -quit)" ]]; then
    continue
  fi

  checked=true
  package_dir="$(dirname "$src_dir")"
  package="$(basename "$package_dir")"
  build_root="$package_dir/build/dev/erlang"
  package_ebin="$build_root/$package/ebin"
  state_dir="build/beam-check/$package"
  sources_file="$state_dir/erlang-sources.txt"
  targets_file="$state_dir/erlang-beams.txt"
  context_file="$state_dir/context-beams.txt"
  plt_file="$state_dir/ffi.plt"

  mkdir -p "$state_dir"
  find "$src_dir" -type f -name '*.erl' -print | sort >"$sources_file"
  : >"$targets_file"
  : >"$context_file"

  while IFS= read -r source; do
    beam="$package_ebin/$(basename "${source%.erl}").beam"
    if [[ ! -f "$beam" ]]; then
      echo "Missing compiled FFI module: $beam" >&2
      exit 1
    fi
    printf '%s\n' "$beam" >>"$targets_file"
  done <"$sources_file"

  find "$build_root" -mindepth 3 -maxdepth 3 -type f \
    -path '*/ebin/*.beam' ! -path "$package_ebin/*" -print \
    >>"$context_file"

  while IFS= read -r source; do
    relative="${source#"$src_dir"/}"
    module="${relative%.gleam}"
    beam="$package_ebin/${module//\//@}.beam"
    if [[ ! -f "$beam" ]]; then
      echo "Missing compiled Gleam module: $beam" >&2
      exit 1
    fi
    printf '%s\n' "$beam" >>"$context_file"
  done < <(find "$src_dir" -type f -name '*.gleam' -print | sort)

  cat "$targets_file" >>"$context_file"
  sort -u -o "$context_file" "$context_file"

  path_args=()
  while IFS= read -r ebin; do
    path_args+=("-pa" "$ebin")
  done < <(find "$build_root" -mindepth 2 -maxdepth 2 -type d -name ebin -print | sort)

  if [[ "$mode" == "all" || "$mode" == "dialyzer" ]]; then
    echo "Dialyzer: $package"
    dialyzer -Wno_unknown --quiet --build_plt \
      --output_plt "$plt_file" \
      --apps erts kernel stdlib compiler crypto eunit parsetools \
      --input_list_file "$context_file"
    dialyzer --quiet --src --plt "$plt_file" \
      "${path_args[@]}" \
      -I "$build_root/$package/include" \
      --input_list_file "$sources_file"
  fi

  if [[ "$mode" == "all" || "$mode" == "xref" ]]; then
    echo "Xref: $package"
    TARGET_FILE="$targets_file" erl -noshell "${path_args[@]}" -eval '
      Name = beryl_ffi_xref,
      {ok, _} = xref:start(Name),
      ok = xref:set_default(Name, [{verbose, false}, {warnings, false}]),
      ok = xref:set_library_path(Name, code_path),
      {ok, Bin} = file:read_file(os:getenv("TARGET_FILE")),
      Files = string:lexemes(binary_to_list(Bin), "\n"),
      lists:foreach(
        fun(File) ->
          {ok, _} = xref:add_module(Name, File)
        end,
        Files
      ),
      Result = xref:analyze(Name, undefined_function_calls),
      xref:stop(Name),
      case Result of
        {ok, []} ->
          halt(0);
        {ok, Calls} ->
          io:format("Undefined function calls:~n~tp~n", [Calls]),
          halt(1);
        Error ->
          io:format("Xref failed: ~tp~n", [Error]),
          halt(1)
      end.
    '
  fi
done < <(find packages -mindepth 2 -maxdepth 2 -type d -name src -print | sort)

if [[ "$checked" == false ]]; then
  echo "No Erlang FFI source files found." >&2
  exit 1
fi
