#!/usr/bin/env bash
# run-tests.sh — umbrella runner: executes every tests/run-*.sh suite (sorted),
# excluding itself. New suites are picked up automatically; no edits needed here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

suites=()
while IFS= read -r s; do
  [ "$(basename "$s")" = "run-tests.sh" ] && continue
  suites+=("$s")
done < <(find "$SCRIPT_DIR" -maxdepth 1 -name 'run-*.sh' | sort)

if [ "${#suites[@]}" -eq 0 ]; then
  echo "FAIL: no test suites found in $SCRIPT_DIR" >&2
  exit 1
fi

failed=0
for s in "${suites[@]}"; do
  name="$(basename "$s")"
  echo "=== $name ==="
  if bash "$s"; then
    echo "=== $name OK ==="
  else
    echo "=== $name FAILED ===" >&2
    failed=1
  fi
  echo
done

if [ "$failed" -ne 0 ]; then
  echo "RESULT: FAILED" >&2
  exit 1
fi
echo "RESULT: all suites passed"
