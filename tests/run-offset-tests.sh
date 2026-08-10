#!/usr/bin/env bash
# run-offset-tests.sh — offsets ledger: recording (receipt copy + SHA-256,
# validation, no-receipt handling, updates), balance math (headline = verified
# removal only), and tax-year CSV export edges (year boundary, multi-payer).
#
# Everything runs against a sandbox DB via CARBON_LEDGER_DB; receipts/exports
# land next to it (the scripts derive their state dir from the DB path).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
RECORD="${REPO_DIR}/scripts/offset-record.sh"
EXPORT="${REPO_DIR}/scripts/offset-export.sh"
REPORT="${REPO_DIR}/scripts/carbon-report.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/carbon-ledger-offsets.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
cleanup() {
  case "$TMPROOT" in
  */carbon-ledger-offsets.*) rm -rf "$TMPROOT" ;;
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

# --- seed: schema + two sessions (600 kg emitted) + one excluded ------------
# shellcheck source=../scripts/lib/schema.sh
source "${REPO_DIR}/scripts/lib/schema.sh"
ensure_schema "$DB"
sqlite3 "$DB" "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens,
  cost_usd, co2_grams, started_at, ended_at, source, methodology_version, excluded)
  VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'p1', 'claude-opus-5', 1, 1, 1.0, 500000.0,
   '2026-01-01T00:00:00Z', '2026-01-01T01:00:00Z', 'backfill', 2, 0),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'p2', 'claude-sonnet-5', 1, 1, 1.0, 100000.0,
   '2026-02-01T00:00:00Z', '2026-02-01T01:00:00Z', 'backfill', 2, 0),
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'p3', 'qwen-local', 1, 1, 0, 0,
   '2026-03-01T00:00:00Z', '2026-03-01T01:00:00Z', 'backfill', 2, 1);"

# RECEIPT1 is a real (minimal, uncompressed) PDF so text extraction has
# something to parse; RECEIPT2 is junk-with-a-.pdf-name so the unparseable
# path is covered too.
RECEIPT1="${TMPROOT}/receipt-biochar.pdf"
RECEIPT2="${TMPROOT}/receipt-tradewater.pdf"
{
  printf '%%PDF-1.4\n'
  printf '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
  printf '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n'
  printf '3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >> endobj\n'
  printf '4 0 obj << /Length 62 >> stream\n'
  printf 'BT /F1 12 Tf 72 720 Td (CORC-RECEIPT 100 kg biochar) Tj ET\n'
  printf 'endstream endobj\n'
  printf 'trailer << /Root 1 0 R >>\n'
  printf '%%%%EOF\n'
} >"$RECEIPT1"
printf 'fake tradewater receipt %s\n' "two" >"$RECEIPT2"

# --- 1. record removal with receipt -----------------------------------------
if bash "$RECORD" --kg 100 --usd 16.00 --vendor remove-carbon-today --pathway biochar \
  --category removal --payer "Acme Research LLC" --receipt "$RECEIPT1" \
  --date 2026-06-15 --notes "it's a test" >/dev/null 2>&1; then
  ok "record removal exits 0"
else
  ko "record removal exits 0"
fi

ROW="$(sqlite3 -separator '|' "$DB" "SELECT vendor, kg_co2e, category, verified, receipt_sha256, receipt_path, notes FROM offsets WHERE id=1;")"
SHA_EXPECTED="$(shasum -a 256 "$RECEIPT1" | LC_ALL=C awk '{print $1}')"
case "$ROW" in
"remove-carbon-today|100.0|removal|1|${SHA_EXPECTED}|"*) ok "removal row: fields + sha256 match" ;;
*) ko "removal row: fields + sha256 match (got: $ROW)" ;;
esac

COPIED="$(sqlite3 "$DB" "SELECT receipt_path FROM offsets WHERE id=1;")"
if [ -f "$COPIED" ] && [ -f "$RECEIPT1" ]; then
  ok "receipt copied (original untouched)"
else
  ko "receipt copied (original untouched): copied='$COPIED'"
fi
case "$COPIED" in
"${STATE}/receipts/2026/2026-06-15-remove-carbon-today-1.pdf") ok "receipt path layout receipts/YYYY/date-vendor-id.ext" ;;
*) ko "receipt path layout (got: $COPIED)" ;;
esac
if [ "$(shasum -a 256 "$COPIED" | LC_ALL=C awk '{print $1}')" = "$SHA_EXPECTED" ]; then
  ok "copied receipt hash verifies"
else
  ko "copied receipt hash verifies"
fi

# receipt bytes also land in the DB (receipt_blobs), keyed by offset id
BLOB_SHA="$(sqlite3 "$DB" "SELECT sha256 FROM receipt_blobs WHERE offset_id=1;" 2>/dev/null)"
if [ "$BLOB_SHA" = "$SHA_EXPECTED" ]; then
  ok "receipt blob row carries matching sha256"
else
  ko "receipt blob row carries matching sha256 (got: '$BLOB_SHA')"
fi
EXTRACTED="${TMPROOT}/extracted-receipt.pdf"
sqlite3 "$DB" "SELECT writefile('${EXTRACTED}', content) FROM receipt_blobs WHERE offset_id=1;" >/dev/null 2>&1
if [ -f "$EXTRACTED" ] && [ "$(shasum -a 256 "$EXTRACTED" | LC_ALL=C awk '{print $1}')" = "$SHA_EXPECTED" ]; then
  ok "receipt blob round-trips byte-identical"
else
  ko "receipt blob round-trips byte-identical"
fi
TEXT1="$(sqlite3 "$DB" "SELECT COALESCE(extracted_text,'') FROM receipt_blobs WHERE offset_id=1;" 2>/dev/null)"
case "$TEXT1" in
*"CORC-RECEIPT 100 kg biochar"*) ok "receipt text parsed and stored" ;;
*) ko "receipt text parsed and stored (got: '$TEXT1')" ;;
esac

# --- 2. record prevention + unverified removal ------------------------------
bash "$RECORD" --kg 200 --usd 3.00 --vendor tradewater --pathway refrigerant-destruction \
  --category prevention --payer "Example Media Co" --receipt "$RECEIPT2" \
  --date 2025-12-31 >/dev/null 2>&1 || ko "record prevention (year-boundary 2025) exits 0"
TEXT2="$(sqlite3 "$DB" "SELECT COALESCE(extracted_text,'') FROM receipt_blobs WHERE offset_id=2;" 2>/dev/null)"
if [ -z "$TEXT2" ]; then
  ok "unparseable receipt records fine with no extracted text"
else
  ko "unparseable receipt records fine with no extracted text (got: '$TEXT2')"
fi

if bash "$RECORD" --kg 50 --usd 8.00 --vendor other --pathway biochar \
  --category removal --payer "Acme Research LLC" --no-receipt \
  --date 2026-07-01 >/dev/null 2>&1; then
  ok "no-receipt override exits 0"
else
  ko "no-receipt override exits 0"
fi
V="$(sqlite3 "$DB" "SELECT verified FROM offsets WHERE id=3;")"
[ "$V" = "0" ] && ok "no-receipt row marked unverified" || ko "no-receipt row marked unverified (verified=$V)"
NB="$(sqlite3 "$DB" "SELECT COUNT(*) FROM receipt_blobs WHERE offset_id=3;" 2>/dev/null)"
[ "$NB" = "0" ] && ok "no-receipt row stores no blob" || ko "no-receipt row stores no blob (got: '$NB')"

# --- 3. validation: hard errors, no rows written ----------------------------
BEFORE="$(sqlite3 "$DB" "SELECT COUNT(*) FROM offsets;")"
bash "$RECORD" --kg 10 --usd 2 --vendor v --pathway biochar --category removal \
  --payer p >/dev/null 2>&1 && ko "missing receipt rejected" || ok "missing receipt rejected"
bash "$RECORD" --kg 0 --usd 2 --vendor v --pathway biochar --category removal \
  --payer p --no-receipt >/dev/null 2>&1 && ko "kg=0 rejected" || ok "kg=0 rejected"
bash "$RECORD" --kg 10 --usd -1 --vendor v --pathway biochar --category removal \
  --payer p --no-receipt >/dev/null 2>&1 && ko "negative usd rejected" || ok "negative usd rejected"
bash "$RECORD" --kg 10 --usd 2 --vendor v --pathway biochar --category avoidance \
  --payer p --no-receipt >/dev/null 2>&1 && ko "bad category rejected" || ok "bad category rejected"
bash "$RECORD" --kg 10 --usd 2 --vendor v --pathway hopes-and-dreams --category removal \
  --payer p --no-receipt >/dev/null 2>&1 && ko "bad pathway rejected" || ok "bad pathway rejected"
bash "$RECORD" --kg 10 --usd 2 --vendor "x'; DROP TABLE offsets;--" --pathway biochar \
  --category removal --payer p --no-receipt >/dev/null 2>&1 && ko "vendor charset rejected" || ok "vendor charset rejected"
bash "$RECORD" --kg 10 --usd 2 --vendor v --pathway biochar --category removal \
  --payer p --no-receipt --date "junk" >/dev/null 2>&1 && ko "bad date rejected" || ok "bad date rejected"
AFTER="$(sqlite3 "$DB" "SELECT COUNT(*) FROM offsets;")"
[ "$BEFORE" = "$AFTER" ] && ok "rejected attempts wrote no rows" || ko "rejected attempts wrote no rows (${BEFORE} -> ${AFTER})"

# --- 4. update: retirement id arrives later ---------------------------------
bash "$RECORD" --update 1 --retirement-id "PURO-2026-00042" >/dev/null 2>&1 ||
  ko "update exits 0"
RID="$(sqlite3 "$DB" "SELECT retirement_id FROM offsets WHERE id=1;")"
[ "$RID" = "PURO-2026-00042" ] && ok "retirement id updated" || ko "retirement id updated (got: $RID)"

# --- 4b. donations: dollars subtract from the owed total --------------------
DONATE="${REPO_DIR}/scripts/donation-record.sh"
if bash "$DONATE" --usd 10.00 --org "American Rivers" --payer "Acme Research LLC" \
  --date 2026-07-01 >/dev/null 2>&1; then
  ok "donation record exits 0"
else
  ko "donation record exits 0"
fi
DROW="$(sqlite3 -separator '|' "$DB" "SELECT org, usd, payer FROM donations WHERE id=1;" 2>/dev/null)"
[ "$DROW" = "American Rivers|10.0|Acme Research LLC" ] && ok "donation row recorded" ||
  ko "donation row recorded (got: '$DROW')"
bash "$DONATE" --usd 0 --org x --payer p >/dev/null 2>&1 && ko "donation usd=0 rejected" ||
  ok "donation usd=0 rejected"
bash "$DONATE" --usd 5 --org "x'; DROP TABLE donations;--" --payer p >/dev/null 2>&1 &&
  ko "donation org charset rejected" || ok "donation org charset rejected"

# --- 5. balance math (report --raw) -----------------------------------------
# emitted 600 kg; verified removal 100 kg; prevention 200 kg; unverified removal 50 kg
RAW="$(bash "$REPORT" --raw 2>/dev/null)"
get() { echo "$RAW" | LC_ALL=C awk -F'\t' -v k="$1" '$1 == k {print $2}'; }
[ "$(get emitted_kg)" = "600.00" ] && ok "raw emitted_kg 600.00" || ko "raw emitted_kg (got: $(get emitted_kg))"
[ "$(get removal_verified_kg)" = "100.00" ] && ok "raw removal_verified_kg 100.00" || ko "raw removal_verified_kg (got: $(get removal_verified_kg))"
[ "$(get prevention_verified_kg)" = "200.00" ] && ok "raw prevention_verified_kg 200.00" || ko "raw prevention_verified_kg (got: $(get prevention_verified_kg))"
[ "$(get unverified_kg)" = "50.00" ] && ok "raw unverified_kg 50.00" || ko "raw unverified_kg (got: $(get unverified_kg))"
[ "$(get balance_kg)" = "500.00" ] && ok "raw balance = emitted - verified removal only" || ko "raw balance_kg (got: $(get balance_kg))"
# cost to clear: 500 kg at $227/t = $113.50 removal; at $15/t = $7.50 prevention
[ "$(get cost_to_clear_removal_usd)" = "113.50" ] && ok "cost-to-clear removal \$113.50" || ko "cost_to_clear_removal_usd (got: $(get cost_to_clear_removal_usd))"
[ "$(get cost_to_clear_prevention_usd)" = "7.50" ] && ok "cost-to-clear prevention \$7.50" || ko "cost_to_clear_prevention_usd (got: $(get cost_to_clear_prevention_usd))"

# segment cache line 1: all-time readings (kWh / L / tonnes; balance moved to
# line 3). Seeded sessions have NULL energy/water -> 0.0kWh / 0L; 600 kg = 0.60 t.
# Line 2: owed/overall cost pair, PURE DOLLAR ledger: overall = 600 kg x $227/t
# = 136.20; owed = 136.20 minus every dollar contributed (offsets $16 + $3 + $8
# and the $10.00 donation = $37.00) = 99.20. No kg translation, no clamp —
# owed goes NEGATIVE past carbon-neutral. Only verified removal settles tonnes.
# Line 3: paid-off vs emitted in tonnes (100 kg verified removal / 600 kg).
CACHE_L1="$(sed -n 1p "${STATE}/segment-cache" 2>/dev/null)"
CACHE_L2="$(sed -n 2p "${STATE}/segment-cache" 2>/dev/null)"
CACHE_L3="$(sed -n 3p "${STATE}/segment-cache" 2>/dev/null)"
if [ "$CACHE_L1" = "∑ ⚡ 0.0kWh 💧 0L 💨 0.60t" ]; then
  ok "segment cache carries all-time readings"
else
  ko "segment cache carries all-time readings (got: '$CACHE_L1')"
fi
if [ "$CACHE_L2" = "99.20/136.20" ]; then
  ok "segment cache owed/overall pair nets out all contributed dollars (99.20 owed / 136.20 overall)"
else
  ko "segment cache owed/overall pair nets out all contributed dollars (got: '$CACHE_L2')"
fi
if [ "$CACHE_L3" = "💨 0.10t/0.60t" ]; then
  ok "segment cache carries paid-off/emitted on its own line"
else
  ko "segment cache carries paid-off/emitted on its own line (got: '$CACHE_L3')"
fi

# going past carbon-neutral in dollars leaves owed NEGATIVE, not clamped at 0:
# 136.20 - (37.00 + 120.00) = -20.80. The donation is larger than it was at the
# old $160/t rate for a reason: at $227/t the previous $80.00 no longer crosses
# zero, and a test for "owed goes negative" that stops going negative is a test
# that passes while proving nothing.
bash "$DONATE" --usd 120.00 --org "Tradewater" --payer "Acme Research LLC" \
  --date 2026-07-02 >/dev/null 2>&1 || ko "over-contributing donation exits 0"
CACHE_L2_NEG="$(sed -n 2p "${STATE}/segment-cache" 2>/dev/null)"
if [ "$CACHE_L2_NEG" = "-20.80/136.20" ]; then
  ok "owed goes negative past carbon-neutral (-20.80/136.20)"
else
  ko "owed goes negative past carbon-neutral (got: '$CACHE_L2_NEG')"
fi

# human report must keep the caveat and the separation visible
HUMAN="$(bash "$REPORT" 2>/dev/null)"
echo "$HUMAN" | grep -q "±50%" && ok "report carries ±50% caveat" || ko "report carries ±50% caveat"
echo "$HUMAN" | grep -qi "prevention" && ok "report shows prevention line" || ko "report shows prevention line"
echo "$HUMAN" | grep -qi "unverified" && ok "report shows unverified line" || ko "report shows unverified line"

# --- 6. export: tax year + payer separation + year boundary ------------------
bash "$EXPORT" --tax-year 2026 >/dev/null 2>&1 || ko "export 2026 exits 0"
CSV_ACME="${STATE}/exports/tax-2026-acme-research-llc.csv"
CSV_EXMEDIA="${STATE}/exports/tax-2026-example-media-co.csv"
if [ -f "$CSV_ACME" ]; then
  ok "export creates per-payer CSV (Acme Research LLC)"
else
  ko "export creates per-payer CSV (Acme Research LLC)"
fi
[ -f "$CSV_EXMEDIA" ] && ko "2025 purchase leaks into 2026 export" || ok "year boundary respected (2025-12-31 not in 2026)"
grep -qi "classify.*CPA" "$CSV_ACME" && ok "export carries classify-with-CPA header" || ko "export carries classify-with-CPA header"
grep -q "$SHA_EXPECTED" "$CSV_ACME" && ok "export includes receipt sha256" || ko "export includes receipt sha256"
grep -q "PURO-2026-00042" "$CSV_ACME" && ok "export includes retirement id" || ko "export includes retirement id"
# rows for this payer in 2026: id 1 (100 kg, verified) + id 3 (50 kg, unverified)
grep -c '^[0-9]' "$CSV_ACME" | grep -qx "2" && ok "export row count (2 rows for payer)" || ko "export row count"

bash "$EXPORT" --tax-year 2025 >/dev/null 2>&1 || ko "export 2025 exits 0"
[ -f "${STATE}/exports/tax-2025-example-media-co.csv" ] && ok "2025 export has the year-boundary row" || ko "2025 export has the year-boundary row"

echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "${FAILED} offset assertion(s) FAILED (${PASSED} passed)."
  exit 1
fi
echo "All ${PASSED} offset assertions passed."
