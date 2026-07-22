#!/usr/bin/env bash
# Portable temporary-file helper. BSD mktemp requires Xs at the end of its
# template, so create a randomized directory first and put the fixed suffix in
# the filename inside it. Callers must use lv2_rmtemp_file so both are removed.
lv2_mktemp_file() {
  local label="${1:?label required}" ext="${2:?extension required}" dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/leadv2.XXXXXX")" || return 1
  printf '%s/%s.%s\n' "$dir" "$label" "$ext"
}

# Remove a file returned by lv2_mktemp_file and its helper-owned parent.
lv2_rmtemp_file() {
  local file="${1:?temporary file required}" dir base
  dir="$(dirname -- "$file")"
  base="$(basename -- "$dir")"
  [[ "$base" == leadv2.* && "$dir" == "${TMPDIR:-/tmp}"/* ]] || return 1
  rm -rf -- "$dir"
}

lv2_mktemp_dir() {
  local label="${1:?label required}"
  mktemp -d "${TMPDIR:-/tmp}/${label}.XXXXXX"
}
