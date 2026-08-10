#!/usr/bin/env bash
# run-review-tests.sh — /carbon-review markdown report: deterministic totals,
# familiar-scale equivalences computed from data/equivalence-constants.json
# (never model arithmetic), the pure-dollar ledger (negative owed allowed),
# byte-identical reruns, and graceful output when the equivalence file is
# missing (public checkouts before the constants land, or a moved file).
#
# Sandbox DB via CARBON_LEDGER_DB, same harness as run-offset-tests.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
REVIEW="${REPO_DIR}/scripts/carbon-review.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/carbon-ledger-review.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
cleanup() {
  case "$TMPROOT" in
  */carbon-ledger-review.*) rm -rf "$TMPROOT" ;;
  *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

STATE="${TMPROOT}/state"
mkdir -p "$STATE"
DB="${STATE}/carbon.db"
export CARBON_LEDGER_DB="$DB"

PASSED=0
FAILED=0
ok() {
  PASSED=$((PASSED + 1))
  echo "PASS $1"
}
ko() {
  FAILED=$((FAILED + 1))
  echo "FAIL $1" >&2
}

has() { # has <file> <needle> <label>
  if grep -qF -- "$2" "$1"; then ok "$3"; else ko "$3 (missing: $2)"; fi
}
lacks() { # lacks <file> <needle> <label>
  if grep -qF -- "$2" "$1"; then ko "$3 (unexpected: $2)"; else ok "$3"; fi
}

# --- seed: schema + two counted sessions + one excluded ---------------------
# Chosen so every derived figure is hand-checkable:
#   600.00 kg CO2e, 1200.00 kWh, 6000.0 L, 24.00 kg embodied, $2.00 cost
#   days    = 1200 * 365 / 10791 = 40.6
#   showers = 6000 / 63.6        = 94
#   miles   = 600 / 0.393        = 1527   (embodied: 24 / 0.393 = 61)
#   overall = 600 kg * $227/t    = $136.20
# shellcheck source=../scripts/lib/schema.sh
source "${REPO_DIR}/scripts/lib/schema.sh"
ensure_schema "$DB"
sqlite3 "$DB" "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens,
  cost_usd, co2_grams, energy_wh, water_ml, embodied_gco2e, started_at, ended_at,
  source, methodology_version, excluded)
  VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'p1', 'claude-opus-5', 1, 1, 1.0,
   500000.0, 1000000.0, 5000000.0, 20000.0,
   '2026-01-01T00:00:00Z', '2026-01-01T01:00:00Z', 'backfill', 2, 0),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'p2', 'claude-sonnet-5', 1, 1, 1.0,
   100000.0, 200000.0, 1000000.0, 4000.0,
   '2026-02-01T00:00:00Z', '2026-02-01T01:00:00Z', 'backfill', 2, 0),
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'p3', 'qwen-local', 1, 1, 0, 0, 0, 0, 0,
   '2026-03-01T00:00:00Z', '2026-03-01T01:00:00Z', 'backfill', 2, 1);"

OUT1="${TMPROOT}/review-1.md"

# --- 1. runs clean and shows every lifetime figure --------------------------
if bash "$REVIEW" >"$OUT1" 2>"${TMPROOT}/err-1"; then
  ok "review exits 0"
else
  ko "review exits 0 ($(cat "${TMPROOT}/err-1"))"
fi
has "$OUT1" "2 sessions since 2026-01-01" "session count and start date"
has "$OUT1" "1200.00 kWh" "lifetime energy"
has "$OUT1" "6000.0 L" "lifetime water"
has "$OUT1" "600.00 kg" "lifetime operational CO2e"
has "$OUT1" "24.00 kg" "lifetime embodied CO2e"
has "$OUT1" "\$2.00" "lifetime API value"

# --- 2. equivalences come from the constants file, formulas included --------
has "$OUT1" "≈ 40.6 days" "energy equivalence (kWh -> home-days)"
has "$OUT1" "≈ 94 showers" "water equivalence (L -> showers)"
has "$OUT1" "≈ 1527 miles" "CO2e equivalence (kg -> miles)"
has "$OUT1" "≈ 61 miles" "embodied equivalence (kg -> miles)"
has "$OUT1" "10,791 kWh in 2022" "EIA citation carried through"
has "$OUT1" "EPA WaterSense" "EPA water citation carried through"
has "$OUT1" "3.93e-4" "EPA vehicle citation carried through"

# --- 3. it is styled markdown with the explainer and caveat -----------------
has "$OUT1" "| ⚡ Energy" "markdown table row"
has "$OUT1" "What these numbers mean" "explainer section"
has "$OUT1" "±50%" "uncertainty caveat"
has "$OUT1" "not scope-matched" "equivalence scope caveat"

# --- 4. by-model breakdown --------------------------------------------------
has "$OUT1" "opus" "model family: opus"
has "$OUT1" "sonnet" "model family: sonnet"

# --- 5. dollar ledger: pristine, then offset, then past-neutral -------------
has "$OUT1" "\$136.20 owed of \$136.20" "dollar ledger with no contributions"

sqlite3 "$DB" "INSERT INTO offsets (purchase_date, vendor, pathway, kg_co2e, usd,
  category, payer, verified) VALUES
  ('2026-06-01', 'Puro reseller', 'biochar', 25.0, 16.0, 'removal', 'Acme Research LLC', 1);"
OUT2="${TMPROOT}/review-2.md"
bash "$REVIEW" >"$OUT2" 2>/dev/null
has "$OUT2" "\$120.20 owed of \$136.20" "offset dollars net 1:1 from owed"
has "$OUT2" "575.00" "tonnes balance nets verified removal only"

sqlite3 "$DB" "INSERT INTO donations (donation_date, org, usd, payer) VALUES
  ('2026-07-01', 'Tradewater', 150.0, 'Acme Research LLC');"
OUT3="${TMPROOT}/review-3.md"
bash "$REVIEW" >"$OUT3" 2>/dev/null
has "$OUT3" "\$-29.80 owed of \$136.20" "owed goes negative past carbon-neutral"
has "$OUT3" "575.00" "donation dollars never move the tonnes balance"

# --- 6. deterministic: same DB, byte-identical output -----------------------
OUT3B="${TMPROOT}/review-3b.md"
bash "$REVIEW" >"$OUT3B" 2>/dev/null
if diff -q "$OUT3" "$OUT3B" >/dev/null; then
  ok "reruns are byte-identical"
else
  ko "reruns are byte-identical"
fi

# --- 7. missing equivalence file degrades, never fails ----------------------
OUT4="${TMPROOT}/review-4.md"
if CARBON_LEDGER_EQUIV="${TMPROOT}/nope.json" bash "$REVIEW" >"$OUT4" 2>/dev/null; then
  ok "missing equivalence file still exits 0"
else
  ko "missing equivalence file still exits 0"
fi
has "$OUT4" "1200.00 kWh" "totals survive without equivalences"
lacks "$OUT4" "days of an average" "no fabricated equivalence without the file"
has "$OUT4" "equivalence constants unavailable" "absence is stated, not papered over"

echo ""
echo "review tests: ${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
