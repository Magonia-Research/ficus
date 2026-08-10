#!/usr/bin/env bash
# offset-export.sh — accountant-ready CSV export of offset purchases.
#
#   offset-export.sh --tax-year YYYY [--payer NAME]
#
# One CSV per payer under <state>/exports/tax-YYYY-<payer-slug>.csv with a
# totals row. The export records; it does not give tax advice — the header says
# to classify donation-vs-expense with a CPA.

set -euo pipefail
export LC_ALL=C

DB_PATH="${CARBON_LEDGER_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/carbon-ledger/carbon.db}"
STATE_DIR="$(dirname "$DB_PATH")"

die() {
  echo "ERROR: $1" >&2
  exit 1
}

YEAR="" PAYER_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
  --tax-year)
    YEAR="${2:-}"
    shift 2
    ;;
  --payer)
    PAYER_FILTER="${2:-}"
    shift 2
    ;;
  *) die "unknown flag: $1" ;;
  esac
done

case "$YEAR" in
[0-9][0-9][0-9][0-9]) ;;
*) die "--tax-year YYYY is required" ;;
esac
if [ -n "$PAYER_FILTER" ]; then
  case "$PAYER_FILTER" in
  *[!A-Za-z0-9._\ -]*) die "--payer may only contain [A-Za-z0-9._ -]" ;;
  esac
fi

[ -f "$DB_PATH" ] || die "no ledger DB at $DB_PATH"

WHERE="purchase_date >= '${YEAR}-01-01' AND purchase_date <= '${YEAR}-12-31'"
if [ -n "$PAYER_FILTER" ]; then
  WHERE="${WHERE} AND payer = '$(printf '%s' "$PAYER_FILTER" | sed "s/'/''/g")'"
fi

PAYERS="$(sqlite3 "$DB_PATH" "SELECT DISTINCT payer FROM offsets WHERE ${WHERE} ORDER BY payer;")"
[ -n "$PAYERS" ] || {
  echo "No offsets recorded for ${YEAR}${PAYER_FILTER:+ (payer: $PAYER_FILTER)}."
  exit 0
}

EXPORT_DIR="${STATE_DIR}/exports"
mkdir -p "$EXPORT_DIR"

while IFS= read -r PAYER; do
  SLUG="$(printf '%s' "$PAYER" | tr '[:upper:]' '[:lower:]' | tr ' ._' '---')"
  OUT="${EXPORT_DIR}/tax-${YEAR}-${SLUG}.csv"
  PAYER_SQL="$(printf '%s' "$PAYER" | sed "s/'/''/g")"

  {
    echo "# carbon-ledger offset export — tax year ${YEAR}, payer: ${PAYER}"
    echo "# Records only. Classify donation-vs-expense with your CPA."
    echo "# Receipt integrity: sha256 of the receipt file at recording time."
    sqlite3 -header -csv "$DB_PATH" "SELECT id, purchase_date, vendor, pathway,
        kg_co2e, usd, category, verified, retirement_id, receipt_path,
        receipt_sha256, notes
      FROM offsets
      WHERE ${WHERE} AND payer = '${PAYER_SQL}'
      ORDER BY purchase_date, id;"
    sqlite3 -csv "$DB_PATH" "SELECT 'TOTAL', '', '', '',
        printf('%.2f', SUM(kg_co2e)), printf('%.2f', SUM(usd)), '', '', '', '', '', ''
      FROM offsets WHERE ${WHERE} AND payer = '${PAYER_SQL}';"
  } >"$OUT"

  ROWS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM offsets WHERE ${WHERE} AND payer = '${PAYER_SQL}';")"
  echo "Wrote ${OUT} (${ROWS} purchase(s))"
done <<EOF
$PAYERS
EOF
