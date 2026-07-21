#!/usr/bin/env bash
# Portable temporary-file helper. BSD mktemp requires Xs at the end of its
# template, so create a randomized directory first and put the fixed suffix in
# the filename inside it. Callers own cleanup of the returned path and parent.
lv2_mktemp_file() {
  local label="${1:?label required}" ext="${2:?extension required}" dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/leadv2.XXXXXX")" || return 1
  printf '%s/%s.%s\n' "$dir" "$label" "$ext"
}

lv2_mktemp_dir() {
  local label="${1:?label required}"
  mktemp -d "${TMPDIR:-/tmp}/${label}.XXXXXX"
}
