#!/usr/bin/env bash
# 100 concurrent calls must yield unique portable temporary file paths.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../leadv2-temp.sh"

ROOT="$(lv2_mktemp_dir temp-stress)"
trap 'rm -rf "$ROOT"' EXIT
export -f lv2_mktemp_file
export -f lv2_rmtemp_file

for _ in $(seq 1 100); do
  bash -c 'path="$(lv2_mktemp_file stress json)"; printf "%s\\n" "$path"; lv2_rmtemp_file "$path"' >> "${ROOT}/paths" &
done
wait

count="$(wc -l < "${ROOT}/paths" | tr -d ' ')"
unique="$(sort -u "${ROOT}/paths" | wc -l | tr -d ' ')"
[[ "$count" == "100" && "$unique" == "100" ]] || {
  printf '[TEMP-STRESS] FAIL: paths=%s unique=%s\n' "$count" "$unique" >&2
  exit 1
}
printf '[TEMP-STRESS] PASS: 100 invocations, 0 collisions\n'
