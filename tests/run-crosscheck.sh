#!/usr/bin/env bash
# run-crosscheck.sh — the blended Jegham-vs-EcoLogits gate must pass on the
# shipped factors, and a mutation must bite: with a perturbed factor in a temp
# copy, BOTH the gate and the golden vectors must fail. A gate that cannot fail
# proves nothing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/carbon-ledger-xchk.XXXXXX")"
cleanup() {
  case "$TMPROOT" in
  */carbon-ledger-xchk.*) rm -rf "$TMPROOT" ;;
  *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

fail=0

# --- 1. gate passes on shipped factors --------------------------------------
if bash "${REPO_DIR}/scripts/check-crosscheck.sh" >"${TMPROOT}/gate.out" 2>&1; then
  grep '^PASS' "${TMPROOT}/gate.out"
else
  echo "FAIL crosscheck: gate rejects the shipped factors.json:" >&2
  cat "${TMPROOT}/gate.out" >&2
  fail=1
fi

# --- 2. mutation bites: perturbed factor fails gate AND vectors --------------
jq '.models.opus.output *= 100' "${REPO_DIR}/data/factors.json" >"${TMPROOT}/mutated-factors.json"

if CARBON_LEDGER_FACTORS="${TMPROOT}/mutated-factors.json" \
  bash "${REPO_DIR}/scripts/check-crosscheck.sh" >/dev/null 2>&1; then
  echo "FAIL crosscheck-mutation: gate accepted opus.output x100" >&2
  fail=1
else
  echo "PASS crosscheck-mutation: gate rejects opus.output x100"
fi

if CARBON_LEDGER_FACTORS="${TMPROOT}/mutated-factors.json" \
  bash "${SCRIPT_DIR}/run-vectors.sh" >/dev/null 2>&1; then
  echo "FAIL vectors-mutation: golden vectors accepted opus.output x100" >&2
  fail=1
else
  echo "PASS vectors-mutation: golden vectors reject opus.output x100"
fi

exit "$fail"
