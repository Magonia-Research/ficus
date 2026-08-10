#!/usr/bin/env bash
# run-reconciliation.sh — proves the fork's backfill produces the same ledger rows as
# pristine upstream (tag upstream-43fb883) on committed fixture transcripts.
#
# Fixtures cover: dedup replay (streaming snapshots, last-wins), subagent transcripts,
# mixed-model dominance, a corrupted JSONL line (slow path), and an excluded non-Claude
# model. Expected rows were recorded ONCE from the upstream tag with:
#
#   bash tests/run-reconciliation.sh --record
#
# and committed as expected.json. Comparison: exact equality on tokens/strings/flags,
# 1e-6 tolerance on cost_usd and co2_grams.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURES="${SCRIPT_DIR}/fixtures/reconciliation"
EXPECTED="${FIXTURES}/expected.json"

command -v jq >/dev/null 2>&1 || {
  echo "FAIL: jq is required" >&2
  exit 1
}
command -v sqlite3 >/dev/null 2>&1 || {
  echo "FAIL: sqlite3 is required" >&2
  exit 1
}
[ -d "$FIXTURES/projects" ] || {
  echo "FAIL: missing fixtures at $FIXTURES/projects" >&2
  exit 1
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/carbon-ledger-recon.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
WORKTREE=""

# Only ever delete the temp root this run created, never an arbitrary variable.
cleanup() {
  if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
    git -C "$REPO_DIR" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  fi
  case "$TMPROOT" in
  */carbon-ledger-recon.*) rm -rf "$TMPROOT" ;;
  *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

# Run a backfill from a given repo tree against the fixtures in a fresh sandbox;
# prints the resulting rows as a JSON array. Second arg names the DB env var
# (CARBON_LEDGER_DB for the fork, CLAUDE_CARBON_DB for the upstream tag), so a
# missed rename in the fork falls back to the sandboxed default path and fails
# both the row comparison and the legacy-path assertion below.
run_backfill() {
  local tree="$1"
  local db_var="$2"
  local sandbox db rows
  sandbox="$(mktemp -d "${TMPROOT}/sandbox.XXXXXX")"
  mkdir -p "${sandbox}/config"
  cp -R "${FIXTURES}/projects" "${sandbox}/config/projects"
  db="${sandbox}/carbon.db"

  CLAUDE_CONFIG_DIR="${sandbox}/config" \
    env "${db_var}=${db}" bash "${tree}/scripts/backfill.sh" >/dev/null

  if [ -e "${sandbox}/config/claude-carbon" ]; then
    echo "FAIL: sandbox created a legacy claude-carbon/ path" >&2
    return 1
  fi

  rows="$(sqlite3 -json "$db" "SELECT session_id, project, model, input_tokens,
    output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, co2_grams,
    started_at, ended_at, source, methodology_version, excluded
    FROM sessions ORDER BY session_id;")"
  echo "${rows:-[]}"
}

# --- record mode: regenerate expected.json from the pristine upstream tag ----
if [ "${1:-}" = "--record" ]; then
  WORKTREE="${TMPROOT}/upstream"
  git -C "$REPO_DIR" worktree add --detach "$WORKTREE" upstream-43fb883 >/dev/null
  rows="$(run_backfill "$WORKTREE" CLAUDE_CARBON_DB)"
  jq -n --argjson rows "$rows" '{
    _provenance: {
      source: "upstream tag upstream-43fb883 (43fb883ac1989d962c8699afb0be37fbe69c4476)",
      command: "bash tests/run-reconciliation.sh --record",
      note: "regenerate ONLY if fixtures change; factor changes must never change these rows"
    },
    rows: $rows
  }' >"$EXPECTED"
  echo "Recorded $(jq '.rows | length' "$EXPECTED") expected rows to $EXPECTED"
  exit 0
fi

# --- compare mode ------------------------------------------------------------
[ -f "$EXPECTED" ] || {
  echo "FAIL: missing $EXPECTED — record it once with: bash tests/run-reconciliation.sh --record" >&2
  exit 1
}

actual="$(run_backfill "$REPO_DIR" CARBON_LEDGER_DB)"
echo "$actual" >"${TMPROOT}/actual.json"

diffs="$(jq -r --slurpfile act "${TMPROOT}/actual.json" '
  def abs: if . < 0 then -. else . end;
  (.rows | sort_by(.session_id)) as $e |
  ($act[0] | sort_by(.session_id)) as $a |
  if ($e | length) != ($a | length) then
    "row count: expected \($e | length), got \($a | length)"
  else
    [ range($e | length) as $i |
      $e[$i] as $x | $a[$i] as $y |
      ( ["session_id", "project", "model", "input_tokens", "output_tokens",
         "cache_read_tokens", "cache_creation_tokens", "started_at", "ended_at",
         "source", "methodology_version", "excluded"] |
        map(select($x[.] != $y[.]) |
          "\($x.session_id) \(.): expected \($x[.]), got \($y[.])") ) +
      ( ["cost_usd", "co2_grams"] |
        map(select((($x[.] - $y[.]) | abs) > 0.000001) |
          "\($x.session_id) \(.): expected \($x[.]), got \($y[.])") )
    ] | flatten | .[]
  end
' "$EXPECTED")"

count="$(jq '.rows | length' "$EXPECTED")"
if [ -n "$diffs" ]; then
  echo "FAIL reconciliation vs upstream-43fb883:" >&2
  printf '%s\n' "$diffs" >&2
  exit 1
fi
echo "PASS reconciliation: ${count}/${count} rows match upstream-43fb883 (tokens exact, cost/co2 within 1e-6)"
