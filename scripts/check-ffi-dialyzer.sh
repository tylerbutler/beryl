#!/usr/bin/env bash

set -euo pipefail

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
  context_file="$state_dir/context-beams.txt"
  plt_file="$state_dir/ffi.plt"

  mkdir -p "$state_dir"
  find "$src_dir" -type f -name '*.erl' -print | sort >"$sources_file"
  : >"$context_file"

  while IFS= read -r source; do
    beam="$package_ebin/$(basename "${source%.erl}").beam"
    if [[ ! -f "$beam" ]]; then
      echo "Missing compiled FFI module: $beam" >&2
      exit 1
    fi
    printf '%s\n' "$beam" >>"$context_file"
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

  sort -u -o "$context_file" "$context_file"

  path_args=()
  while IFS= read -r ebin; do
    path_args+=("-pa" "$ebin")
  done < <(find "$build_root" -mindepth 2 -maxdepth 2 -type d -name ebin -print | sort)

  echo "Dialyzer: $package"
  dialyzer -Wno_unknown --quiet --build_plt \
    --output_plt "$plt_file" \
    --apps erts kernel stdlib compiler crypto eunit parsetools \
    --input_list_file "$context_file"
  dialyzer --quiet --src --plt "$plt_file" \
    "${path_args[@]}" \
    -I "$build_root/$package/include" \
    --input_list_file "$sources_file"
done < <(find packages -mindepth 2 -maxdepth 2 -type d -name src -print | sort)

if [[ "$checked" == false ]]; then
  echo "No Erlang FFI source files found." >&2
  exit 1
fi
