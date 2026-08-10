#!/usr/bin/env bash
# run-statusline-bench.sh — the statusline segment must be cheap and correct:
#   1. p95 added render cost < 50 ms over 20 runs
#   2. snippet math matches the golden vectors (cache-free mixes)
#   3. the render path never touches the DB (no sqlite3/DB reads in the snippet)
#
# The snippet is measured standalone (its own jq call). In production its jq
# fields merge into the user's existing single call, so this is an upper bound.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SNIPPET="${REPO_DIR}/statusline-snippet.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/carbon-ledger-slbench.XXXXXX")"
cleanup() {
  case "$TMPROOT" in
  */carbon-ledger-slbench.*) rm -rf "$TMPROOT" ;;
  *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

fail=0

[ -f "$SNIPPET" ] || {
  echo "FAIL: missing $SNIPPET" >&2
  exit 1
}

# --- 3 first (cheap): no DB access in the render path ------------------------
if grep -qE 'sqlite3|carbon\.db' "$SNIPPET"; then
  echo "FAIL statusline: snippet touches the DB in the render path" >&2
  fail=1
else
  echo "PASS statusline: no DB access in render path"
fi

# --- sandbox state: factors.env from the shipped factors + a segment cache ---
STATE="${TMPROOT}/state"
mkdir -p "$STATE"
# shellcheck source=../scripts/lib/factors-env.sh
source "${REPO_DIR}/scripts/lib/factors-env.sh"
emit_factors_env "${REPO_DIR}/data/factors.json" "$STATE" || {
  echo "FAIL statusline: emit_factors_env failed" >&2
  exit 1
}
printf '∑ ⚡ 2173.2kWh 💧 11448L 💨 0.62t\n99.79/99.79\n💨 0.00t/0.62t' >"${STATE}/segment-cache"

# --- factors.env is a cache, and a cache needs invalidating ------------------
# This is a regression test for a bug that shipped: the removal price moved from
# $160 to $227 a tonne in data/offset-constants.json, every path reading that
# file picked it up, and the statusline — which reads only factors.env — went on
# pricing sessions at the old rate. Nothing failed and no test went red; the two
# figures on screen just disagreed by thirty percent. So the mtimes decide.
STALE_DATA="${TMPROOT}/data"
STALE_STATE="${TMPROOT}/stale-state"
mkdir -p "$STALE_DATA" "$STALE_STATE"
cp "${REPO_DIR}/data/factors.json" "$STALE_DATA/"
jq '.removal_usd_per_tonne = 160' "${REPO_DIR}/data/offset-constants.json" >"${STALE_DATA}/offset-constants.json"
emit_factors_env "${STALE_DATA}/factors.json" "$STALE_STATE" >/dev/null
stale_rate() { sed -n 's/^CL_REMOVAL_USD_PER_T=//p' "${STALE_STATE}/factors.env"; }
if [ "$(stale_rate)" = "160" ]; then
  echo "PASS statusline: the cache starts at the old price"
else
  echo "FAIL statusline: expected a 160 cache to start from, got '$(stale_rate)'" >&2
  fail=1
fi
# The price changes in data/, and nothing has rebuilt the cache yet.
jq '.removal_usd_per_tonne = 227' "${REPO_DIR}/data/offset-constants.json" >"${STALE_DATA}/offset-constants.json"
touch "${STALE_DATA}/offset-constants.json"
refresh_factors_env_if_stale "${STALE_DATA}/factors.json" "$STALE_STATE"
if [ "$(stale_rate)" = "227" ]; then
  echo "PASS statusline: a changed constant invalidates the cache"
else
  echo "FAIL statusline: constant changed but the cache still reads '$(stale_rate)'" >&2
  fail=1
fi
# And once it has settled, an unchanged tree must NOT rewrite it — the guard
# runs on every Stop hook, so rebuilding every time would be a write amplifier
# for nothing. "Settled" needs a second to pass first: a rebuild landing in the
# same second as the edit that triggered it is not strictly newer than its
# source, which costs exactly one more rebuild by design.
sleep 1
refresh_factors_env_if_stale "${STALE_DATA}/factors.json" "$STALE_STATE"
before="$(stat -f %m "${STALE_STATE}/factors.env" 2>/dev/null || stat -c %Y "${STALE_STATE}/factors.env")"
sleep 1
refresh_factors_env_if_stale "${STALE_DATA}/factors.json" "$STALE_STATE"
after="$(stat -f %m "${STALE_STATE}/factors.env" 2>/dev/null || stat -c %Y "${STALE_STATE}/factors.env")"
if [ "$before" = "$after" ]; then
  echo "PASS statusline: an unchanged tree leaves the cache alone"
else
  echo "FAIL statusline: the cache was rewritten with nothing to rebuild from" >&2
  fail=1
fi
REMOVAL_RATE="$(jq -er '.removal_usd_per_tonne' "${REPO_DIR}/data/offset-constants.json")"
SEP_LINE="────────────────────────────────"

run_snippet() {
  printf '{"model":{"id":"%s"},"context_window":{"total_input_tokens":%s,"total_output_tokens":%s}}' \
    "$1" "$2" "$3" | CARBON_LEDGER_STATE="$STATE" bash "$SNIPPET"
}

# --- 2. math matches the vectors (cache-free mixes) --------------------------
# opus-no-cache and family-precedence-fable-over-opus have zero cache tokens, so
# the statusline's in/out-only model must reproduce their expected co2/energy.
check_vector() {
  local vid="$1" model="$2"
  local in out exp_co2 exp_e got
  in="$(jq -r --arg v "$vid" '.vectors[] | select(.id == $v) | .input_tokens' "${SCRIPT_DIR}/methodology-vectors.json")"
  out="$(jq -r --arg v "$vid" '.vectors[] | select(.id == $v) | .output_tokens' "${SCRIPT_DIR}/methodology-vectors.json")"
  exp_co2="$(jq -r --arg v "$vid" '.vectors[] | select(.id == $v) | .expected_co2_grams' "${SCRIPT_DIR}/methodology-vectors.json")"
  exp_e="$(jq -r --arg v "$vid" '.vectors[] | select(.id == $v) | .expected_energy_wh' "${SCRIPT_DIR}/methodology-vectors.json")"
  got="$(run_snippet "$model" "$in" "$out")"
  exp_fmt="$(echo "$exp_e $exp_co2" | LC_ALL=C awk '{printf "⚡ %.2fWh 💧 %.1fmL 💨 %.2fg", $1, $1 * 5.2678947368, $2}')"
  # Cents below a dollar, dollars above — the same branch the snippet takes, so
  # the expectation is derived rather than transcribed.
  exp_cost="$(echo "$exp_co2 $REMOVAL_RATE" | LC_ALL=C awk \
    '{c = $1 * $2 / 1000000; printf (c < 1) ? "%.2f¢" : "$%.2f", (c < 1) ? c * 100 : c}')"
  # SESSION FIGURES ABOVE THE RULE, TOTALS BELOW IT. The session cost sits with
  # the session readings it was computed from; the totals line carries only
  # all-time figures.
  want="$(printf '%s · ▲ %s session\n%s\n∑ ⚡ 2173.2kWh 💧 11448L 💨 0.62t · 💨 0.00t/0.62t · $99.79/99.79 total' \
    "$exp_fmt" "$exp_cost" "$SEP_LINE")"
  if [ "$got" = "$want" ]; then
    echo "PASS statusline math: ${vid}"
  else
    echo "FAIL statusline math ${vid}: got '${got}', want '${want}'" >&2
    fail=1
  fi
}
check_vector "opus-no-cache" "claude-opus-5"
check_vector "family-precedence-fable-over-opus" "claude-fable-opus-hybrid-test"

# non-Claude model renders zeros, never a made-up estimate
GOT_EXCL="$(run_snippet "qwen-local-7b" 100000 100000)"
case "$GOT_EXCL" in
"⚡ 0.00Wh"*) echo "PASS statusline: non-Claude model shows zero estimate" ;;
*)
  echo "FAIL statusline: non-Claude model rendered '${GOT_EXCL}'" >&2
  fail=1
  ;;
esac

# --- 1. p95 < 50 ms over 20 runs --------------------------------------------
JSON='{"model":{"id":"claude-opus-5"},"context_window":{"total_input_tokens":50000,"total_output_tokens":8000}}'
TIMES="${TMPROOT}/times"
: >"$TIMES"
i=0
while [ "$i" -lt 20 ]; do
  T0="$(perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000')"
  printf '%s' "$JSON" | CARBON_LEDGER_STATE="$STATE" bash "$SNIPPET" >/dev/null
  T1="$(perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000')"
  echo "$((T1 - T0))" >>"$TIMES"
  i=$((i + 1))
done
P95="$(sort -n "$TIMES" | sed -n '19p')"
if [ "$P95" -lt 50 ] 2>/dev/null; then
  echo "PASS statusline bench: p95 ${P95} ms (< 50 ms over 20 runs)"
else
  echo "FAIL statusline bench: p95 ${P95} ms exceeds 50 ms" >&2
  fail=1
fi

exit "$fail"
