#!/usr/bin/env bash
# run-day-split-tests.sh — per-day attribution, and the calendar the day ruler
# is drawn from.
#
# Two claims are under test and both are load-bearing.
#
# THE SPLIT IS A GROUPING, NOT AN APPORTIONMENT. Every assistant message carries
# its own timestamp beside its own token usage, so a session that ran past
# midnight can be divided by measurement instead of by assumption. The proof is
# that the per-day rows sum to exactly the session row: if they ever stop tying
# out, something is being modelled rather than counted.
#
# THE CALENDAR IS REAL. The day axis is drawn one tick per row of the daily
# series, so "accurate for the months in question" is a property of that series:
# February must produce 28 rows, or 29 in a leap year, because February did.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/carbon-ledger-daysplit.XXXXXX")"
cleanup() {
  case "$TMPROOT" in
  */carbon-ledger-daysplit.*) rm -rf "$TMPROOT" ;;
  *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

fail=0
ok() { echo "PASS day-split: $1"; }
no() {
  echo "FAIL day-split: $1" >&2
  fail=1
}
eq() { # eq DESCRIPTION GOT WANT
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '${2}', want '${3}')"; fi
}

# shellcheck source=../scripts/lib/schema.sh
source "${REPO_DIR}/scripts/lib/schema.sh"
# shellcheck source=../scripts/lib/day-split.sh
source "${REPO_DIR}/scripts/lib/day-split.sh"

# --- 1. the splitter groups by the message's own date ------------------------
# Two days, and a duplicate (same message.id + requestId) that must be counted
# once — the same dedup the session total applies, or the two would not tie out.
T1="${TMPROOT}/two-days.jsonl"
cat >"$T1" <<'JSONL'
{"type":"assistant","timestamp":"2026-03-14T22:10:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}},"requestId":"r1"}
{"type":"assistant","timestamp":"2026-03-14T22:10:09.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}},"requestId":"r1"}
{"type":"assistant","timestamp":"2026-03-14T23:55:00.000Z","message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":200,"output_tokens":20,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0}},"requestId":"r2"}
{"type":"assistant","timestamp":"2026-03-15T00:20:00.000Z","message":{"id":"m3","model":"claude-opus-5","usage":{"input_tokens":300,"output_tokens":30,"cache_read_input_tokens":3000,"cache_creation_input_tokens":0}},"requestId":"r3"}
{"type":"user","timestamp":"2026-03-15T00:21:00.000Z","message":{"content":"ignored"}}
JSONL
SPLIT="$(day_split_jsonl "$T1")"
eq "the split finds both days" "$(printf '%s\n' "$SPLIT" | wc -l | tr -d ' ')" "2"
eq "day one carries its own tokens" \
  "$(printf '%s\n' "$SPLIT" | awk -F'\t' '$1=="2026-03-14"{print $2"/"$3"/"$4"/"$5}')" "300/50/3000/30"
eq "day two carries its own tokens" \
  "$(printf '%s\n' "$SPLIT" | awk -F'\t' '$1=="2026-03-15"{print $2"/"$3"/"$4"/"$5}')" "300/0/3000/30"
# The duplicate would show as 400 input on day one if dedup were skipped.
if printf '%s\n' "$SPLIT" | awk -F'\t' '$1=="2026-03-14" && $2==400' | grep -q .; then
  no "the duplicate message was counted twice"
else
  ok "a duplicated message is counted once, as in the session total"
fi
# A transcript with no timestamps must yield nothing rather than a guess.
printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":5,"output_tokens":5}}}' >"${TMPROOT}/no-ts.jsonl"
eq "a message with no timestamp is not placed on a day" \
  "$(day_split_jsonl "${TMPROOT}/no-ts.jsonl" | wc -l | tr -d ' ')" "0"

# --- 2. the Stop hook writes days that sum to the session --------------------
DB="${TMPROOT}/carbon.db"
export CARBON_LEDGER_DB="$DB"
ensure_schema "$DB"
printf '{"session_id":"11111111-1111-4111-8111-111111111111","transcript_path":"%s","cwd":"%s"}' \
  "$T1" "$TMPROOT" | bash "${REPO_DIR}/scripts/persist-session.sh" >/dev/null 2>&1

eq "the hook wrote one row per day the session touched" \
  "$(sqlite3 "$DB" "SELECT COUNT(*) FROM session_days;")" "2"
# The tie-out. Tokens first, because a mismatch there means the two paths
# disagree about what was in the transcript at all.
eq "per-day input tokens sum to the session row" \
  "$(sqlite3 "$DB" "SELECT (SELECT SUM(input_tokens + cache_creation_tokens) FROM session_days)
     = (SELECT input_tokens FROM sessions);")" "1"
eq "per-day output tokens sum to the session row" \
  "$(sqlite3 "$DB" "SELECT (SELECT SUM(output_tokens) FROM session_days)
     = (SELECT output_tokens FROM sessions);")" "1"
# Then carbon, to a tenth of a milligram — the two are computed by the same
# linear formula with the same factors, so anything larger is a real divergence.
eq "per-day carbon sums to the session row" \
  "$(sqlite3 "$DB" "SELECT ABS((SELECT SUM(co2_grams) FROM session_days)
     - (SELECT co2_grams FROM sessions)) < 0.0001;")" "1"
eq "the derived columns follow the same CIF identity" \
  "$(sqlite3 "$DB" "SELECT ABS((SELECT SUM(energy_wh) FROM session_days)
     - (SELECT energy_wh FROM sessions)) < 0.01;")" "1"
# Re-running must not double anything: the rows are rebuilt, not merged.
printf '{"session_id":"11111111-1111-4111-8111-111111111111","transcript_path":"%s","cwd":"%s"}' \
  "$T1" "$TMPROOT" | bash "${REPO_DIR}/scripts/persist-session.sh" >/dev/null 2>&1
eq "a second run rebuilds the days rather than doubling them" \
  "$(sqlite3 "$DB" "SELECT COUNT(*) FROM session_days;")" "2"
eq "and the carbon still ties out after the rerun" \
  "$(sqlite3 "$DB" "SELECT ABS((SELECT SUM(co2_grams) FROM session_days)
     - (SELECT co2_grams FROM sessions)) < 0.0001;")" "1"

# --- 3. the chart reads the split, and counts the session once ---------------
export CARBON_LEDGER_DASHBOARD_DIR="${TMPROOT}/dash"
export CARBON_LEDGER_DASHBOARD_TS="2026-08-06T12:00:00Z"
DASH="${CARBON_LEDGER_DASHBOARD_DIR}/carbon-2026-08-06T12-00-00Z.html"
bash "${REPO_DIR}/scripts/generate-dashboard.sh" --no-open >/dev/null 2>&1
sed -n 's/^const DATA = \(.*\);$/\1/p' "$DASH" >"${TMPROOT}/data.json"
dq() { jq -r "$1" "${TMPROOT}/data.json" 2>/dev/null; }

eq "the daily series shows carbon on BOTH days, not just the first" \
  "$(dq '[.series.day.rows[] | select(.co2_g > 0)] | length')" "2"
# The whole point: without the split the second day would read zero and the
# first would carry everything.
eq "the second day is not empty" "$(dq '[.series.day.rows[] | select(.b == "2026-03-15")][0].co2_g > 0')" "true"
# One session, split across two days, must still count as one session.
eq "a split session is counted once, on the day it began" \
  "$(dq '[.series.day.rows[].sessions] | add')" "1"
eq "and it is counted on the first day it actually spent tokens" \
  "$(dq '[.series.day.rows[] | select(.b == "2026-03-14")][0].sessions')" "1"
eq "the page reports how much of the ledger carries a measured split" \
  "$(dq '.day_basis.split')" "1"

# --- 4. history without a split still lands on its start day -----------------
# The fallback has to work, because a pruned transcript can never be split.
OLD_DB="${TMPROOT}/old.db"
ensure_schema "$OLD_DB"
sqlite3 "$OLD_DB" "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens,
    cost_usd, co2_grams, energy_wh, water_ml, embodied_gco2e, started_at, ended_at, source,
    methodology_version, excluded) VALUES
  ('22222222-2222-4222-8222-222222222222','p','claude-opus-5',10,10,1.0,500.0,1742.2,9177.0,76.8,
   '2026-05-10T23:00:00Z','2026-05-11T02:00:00Z','backfill',2,0),
  ('33333333-3333-4333-8333-333333333333','p','claude-opus-5',10,10,1.0,100.0,348.4,1835.0,15.4,
   '2026-05-14T09:00:00Z','2026-05-14T10:00:00Z','backfill',2,0);"
CARBON_LEDGER_DB="$OLD_DB" CARBON_LEDGER_DASHBOARD_DIR="${TMPROOT}/dash2" \
  bash "${REPO_DIR}/scripts/generate-dashboard.sh" --no-open >/dev/null 2>&1
sed -n 's/^const DATA = \(.*\);$/\1/p' "${TMPROOT}/dash2/carbon-2026-08-06T12-00-00Z.html" >"${TMPROOT}/old.json"
oq() { jq -r "$1" "${TMPROOT}/old.json" 2>/dev/null; }
eq "an unsplit session lands whole on the day it began" \
  "$(oq '[.series.day.rows[] | select(.b == "2026-05-10")][0].co2_g')" "500.0"
eq "and nothing is invented on the day it ended" \
  "$(oq '[.series.day.rows[] | select(.b == "2026-05-11")][0].co2_g')" "0"
eq "the page counts the unsplit sessions it knows crossed midnight" \
  "$(oq '.day_basis.unsplit_crossing')" "1"
eq "the totals are untouched by any of this" \
  "$(oq '.totals.co2_g')" "600.0"

# --- 5. the calendar the ruler is drawn from ---------------------------------
# One tick per row, so the row count IS the tick count. 2028 is a leap year:
# February must produce 29 rows, and the two months after it 31 and 30. This is
# what "accurate for the months in question" means in practice — nothing in the
# renderer knows how long a month is, and it does not need to.
LEAP_DB="${TMPROOT}/leap.db"
ensure_schema "$LEAP_DB"
sqlite3 "$LEAP_DB" "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens,
    cost_usd, co2_grams, energy_wh, water_ml, embodied_gco2e, started_at, ended_at, source,
    methodology_version, excluded) VALUES
  ('44444444-4444-4444-8444-444444444444','p','claude-opus-5',10,10,1.0,100.0,348.4,1835.0,15.4,
   '2028-02-01T09:00:00Z','2028-02-01T10:00:00Z','backfill',2,0),
  ('55555555-5555-4555-8555-555555555555','p','claude-opus-5',10,10,1.0,100.0,348.4,1835.0,15.4,
   '2028-04-30T09:00:00Z','2028-04-30T10:00:00Z','backfill',2,0);"
CARBON_LEDGER_DB="$LEAP_DB" CARBON_LEDGER_DASHBOARD_DIR="${TMPROOT}/dash3" \
  bash "${REPO_DIR}/scripts/generate-dashboard.sh" --no-open >/dev/null 2>&1
sed -n 's/^const DATA = \(.*\);$/\1/p' "${TMPROOT}/dash3/carbon-2026-08-06T12-00-00Z.html" >"${TMPROOT}/leap.json"
lq() { jq -r "$1" "${TMPROOT}/leap.json" 2>/dev/null; }
eq "leap February gets 29 day rows, not 28 and not a generic 30" \
  "$(lq '[.series.day.rows[] | select(.b | startswith("2028-02"))] | length')" "29"
eq "March gets 31" "$(lq '[.series.day.rows[] | select(.b | startswith("2028-03"))] | length')" "31"
eq "April gets 30" "$(lq '[.series.day.rows[] | select(.b | startswith("2028-04"))] | length')" "30"
eq "the span is every day between the two sessions, inclusive" \
  "$(lq '.series.day.n')" "90"
# And a non-leap February, so 29 is not simply hardcoded somewhere.
NL_DB="${TMPROOT}/nonleap.db"
ensure_schema "$NL_DB"
sqlite3 "$NL_DB" "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens,
    cost_usd, co2_grams, energy_wh, water_ml, embodied_gco2e, started_at, ended_at, source,
    methodology_version, excluded) VALUES
  ('66666666-6666-4666-8666-666666666666','p','claude-opus-5',10,10,1.0,100.0,348.4,1835.0,15.4,
   '2026-02-01T09:00:00Z','2026-02-01T10:00:00Z','backfill',2,0),
  ('77777777-7777-4777-8777-777777777777','p','claude-opus-5',10,10,1.0,100.0,348.4,1835.0,15.4,
   '2026-04-30T09:00:00Z','2026-04-30T10:00:00Z','backfill',2,0);"
CARBON_LEDGER_DB="$NL_DB" CARBON_LEDGER_DASHBOARD_DIR="${TMPROOT}/dash4" \
  bash "${REPO_DIR}/scripts/generate-dashboard.sh" --no-open >/dev/null 2>&1
eq "a non-leap February gets 28" \
  "$(sed -n 's/^const DATA = \(.*\);$/\1/p' "${TMPROOT}/dash4/carbon-2026-08-06T12-00-00Z.html" |
    jq -r '[.series.day.rows[] | select(.b | startswith("2026-02"))] | length')" "28"

# --- 6. the renderer draws the ruler from those rows -------------------------
want() { # want DESCRIPTION PATTERN
  if grep -q -e "$2" "$DASH"; then ok "$1"; else no "$1 (missing: $2)"; fi
}
want "there is a day ruler" 'the day ruler'
want "ticks are classed so they can be styled apart from the grid" 'class: weekly ? "tick tick--w" : "tick"'
want "the tall marks come from the date, not from counting rows" 'var dom = +String(rows\[di\].b).slice(8, 10)'
want "the ruler thins rather than hatching the axis" 'var perDay = step >= 3.5'
want "the page says which sessions predate the split" 'function dayBasisNote'

[ "$fail" = "0" ] || exit 1
echo "All day-split assertions passed."
