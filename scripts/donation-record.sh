#!/usr/bin/env bash
# donation-record.sh — record a charitable donation (giving-shortlist orgs).
#
#   donation-record.sh --usd N --org NAME --payer NAME
#                      [--date YYYY-MM-DD] [--notes TEXT] [--receipt PATH]
#
# Donation dollars subtract 1:1 from the OWED side of the statusline cost pair
# (the user's chosen short-term accounting). They never touch the tonnes
# balance: only verified removal settles kg CO2e. A receipt is optional here
# (unlike offsets) — when given it is COPIED to <state>/receipts/YYYY/ and its
# SHA-256 recorded, same discipline as offset receipts.
#
# Validation mirrors offset-record.sh: numeric guard, charset-limited org and
# payer, regex-checked date, single-quote-escaped notes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_PATH="${CARBON_LEDGER_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/carbon-ledger/carbon.db}"
STATE_DIR="$(dirname "$DB_PATH")"

# shellcheck source=lib/schema.sh
source "${SCRIPT_DIR}/lib/schema.sh"
# shellcheck source=lib/segment-cache.sh
source "${SCRIPT_DIR}/lib/segment-cache.sh"

die() {
  echo "ERROR: $1" >&2
  exit 1
}

USD="" ORG="" PAYER="" DATE="" NOTES="" RECEIPT=""

while [ $# -gt 0 ]; do
  case "$1" in
  --usd)
    USD="${2:-}"
    shift 2
    ;;
  --org)
    ORG="${2:-}"
    shift 2
    ;;
  --payer)
    PAYER="${2:-}"
    shift 2
    ;;
  --date)
    DATE="${2:-}"
    shift 2
    ;;
  --notes)
    NOTES="${2:-}"
    shift 2
    ;;
  --receipt)
    RECEIPT="${2:-}"
    shift 2
    ;;
  *) die "unknown flag: $1" ;;
  esac
done

command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required"

[ -n "$USD" ] && [ -n "$ORG" ] && [ -n "$PAYER" ] ||
  die "required: --usd --org --payer (optionally --date --notes --receipt)"

case "$USD" in
'' | *[!0-9.]*) die "--usd must be a plain non-negative number (got: '$USD')" ;;
esac
echo "$USD" | LC_ALL=C awk '{exit ($1 > 0) ? 0 : 1}' || die "--usd must be > 0"

check_charset() {
  case "$1" in
  '' | *[!A-Za-z0-9._\ -]*) die "$2 may only contain [A-Za-z0-9._ -] (got: '$1')" ;;
  esac
}
check_charset "$ORG" "--org"
check_charset "$PAYER" "--payer"

if [ -z "$DATE" ]; then
  DATE="$(date +%Y-%m-%d)"
fi
case "$DATE" in
[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
*) die "--date must be YYYY-MM-DD (got: '$DATE')" ;;
esac

SHA256=""
if [ -n "$RECEIPT" ]; then
  command -v shasum >/dev/null 2>&1 || die "shasum is required for --receipt"
  [ -f "$RECEIPT" ] || die "receipt file not found: $RECEIPT"
  SHA256="$(shasum -a 256 "$RECEIPT" | LC_ALL=C awk '{print $1}')"
fi

esc() { printf '%s' "$1" | sed "s/'/''/g"; }

mkdir -p "$STATE_DIR"
ensure_schema "$DB_PATH"

ROW_ID="$(sqlite3 "$DB_PATH" "INSERT INTO donations
  (donation_date, org, usd, payer, receipt_sha256, notes)
  VALUES ('${DATE}', '$(esc "$ORG")', ${USD}, '$(esc "$PAYER")',
   '${SHA256}', '$(esc "$NOTES")');
  SELECT last_insert_rowid();")"

if [ -n "$RECEIPT" ]; then
  YEAR="${DATE%%-*}"
  EXT="${RECEIPT##*.}"
  case "$EXT" in
  "$RECEIPT" | '') EXT="bin" ;; # no extension
  esac
  ORG_SLUG="$(printf '%s' "$ORG" | tr ' ' '-')"
  DEST_DIR="${STATE_DIR}/receipts/${YEAR}"
  DEST="${DEST_DIR}/${DATE}-donation-${ORG_SLUG}-${ROW_ID}.${EXT}"
  mkdir -p "$DEST_DIR"
  cp "$RECEIPT" "$DEST" # copy only; this script never moves or deletes
  sqlite3 "$DB_PATH" "UPDATE donations SET receipt_path='$(esc "$DEST")' WHERE id=${ROW_ID};"
fi

refresh_segment_cache "$DB_PATH"

echo "Recorded donation #${ROW_ID}: \$${USD} to ${ORG} (${PAYER}, ${DATE})."
echo "Subtracted from the owed total; the tonnes balance settles only with verified removal."
