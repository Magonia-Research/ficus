#!/usr/bin/env bash
# offset-record.sh — record a carbon-offset purchase in the offsets table, with a
# mandatory receipt for tax-grade records.
#
#   offset-record.sh --kg N --usd N --vendor NAME --pathway P --category C
#                    --payer NAME --receipt PATH [--date YYYY-MM-DD]
#                    [--retirement-id ID] [--notes TEXT] [--no-receipt]
#   offset-record.sh --update ID [--retirement-id ID] [--notes TEXT]
#
# The receipt file is COPIED (never moved, never deleted) to
# <state>/receipts/YYYY/<date>-<vendor>-<rowid>.<ext>, its SHA-256 recorded, and
# its bytes stored in the receipt_blobs table so the DB alone is a complete
# tax record (extract with sqlite3's writefile()).
# No receipt without an explicit --no-receipt is a hard error; --no-receipt rows
# are stored verified=0 and loudly labeled everywhere they appear.
#
# Injection discipline mirrors recompute.sh: numbers pass a numeric case-guard,
# category/pathway are whitelisted, the date is regex-checked, vendor/payer are
# charset-limited, and free-text notes are single-quote escaped.

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

KG="" USD="" VENDOR="" PATHWAY="" CATEGORY="" PAYER="" RECEIPT="" DATE=""
RETIREMENT_ID="" NOTES="" NO_RECEIPT=0 UPDATE_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
  --kg)
    KG="${2:-}"
    shift 2
    ;;
  --usd)
    USD="${2:-}"
    shift 2
    ;;
  --vendor)
    VENDOR="${2:-}"
    shift 2
    ;;
  --pathway)
    PATHWAY="${2:-}"
    shift 2
    ;;
  --category)
    CATEGORY="${2:-}"
    shift 2
    ;;
  --payer)
    PAYER="${2:-}"
    shift 2
    ;;
  --receipt)
    RECEIPT="${2:-}"
    shift 2
    ;;
  --date)
    DATE="${2:-}"
    shift 2
    ;;
  --retirement-id)
    RETIREMENT_ID="${2:-}"
    shift 2
    ;;
  --notes)
    NOTES="${2:-}"
    shift 2
    ;;
  --no-receipt)
    NO_RECEIPT=1
    shift
    ;;
  --update)
    UPDATE_ID="${2:-}"
    shift 2
    ;;
  *) die "unknown flag: $1" ;;
  esac
done

command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required"
command -v shasum >/dev/null 2>&1 || die "shasum is required"

# Shared validators
check_numeric() {
  case "$1" in
  '' | *[!0-9.]*) die "$2 must be a plain non-negative number (got: '$1')" ;;
  esac
}
check_charset() {
  case "$1" in
  '' | *[!A-Za-z0-9._\ -]*) die "$2 may only contain [A-Za-z0-9._ -] (got: '$1')" ;;
  esac
}

esc() { printf '%s' "$1" | sed "s/'/''/g"; }

# --- update mode -------------------------------------------------------------
if [ -n "$UPDATE_ID" ]; then
  case "$UPDATE_ID" in
  '' | *[!0-9]*) die "--update takes a numeric offset id" ;;
  esac
  [ -f "$DB_PATH" ] || die "no ledger DB at $DB_PATH"
  EXISTS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM offsets WHERE id=${UPDATE_ID};")"
  [ "$EXISTS" = "1" ] || die "offset id ${UPDATE_ID} not found"

  SETS=""
  if [ -n "$RETIREMENT_ID" ]; then
    case "$RETIREMENT_ID" in
    *[!A-Za-z0-9._:/\ -]*) die "--retirement-id may only contain [A-Za-z0-9._:/ -]" ;;
    esac
    SETS="retirement_id='$(esc "$RETIREMENT_ID")'"
  fi
  if [ -n "$NOTES" ]; then
    [ -n "$SETS" ] && SETS="${SETS}, "
    SETS="${SETS}notes='$(esc "$NOTES")'"
  fi
  [ -n "$SETS" ] || die "--update needs --retirement-id and/or --notes"

  sqlite3 "$DB_PATH" "UPDATE offsets SET ${SETS} WHERE id=${UPDATE_ID};"
  refresh_segment_cache "$DB_PATH"
  echo "Updated offset #${UPDATE_ID}."
  sqlite3 -header -column "$DB_PATH" "SELECT id, purchase_date, vendor, kg_co2e, category, verified, retirement_id FROM offsets WHERE id=${UPDATE_ID};"
  exit 0
fi

# --- record mode -------------------------------------------------------------
[ -n "$KG" ] && [ -n "$USD" ] && [ -n "$VENDOR" ] && [ -n "$PATHWAY" ] &&
  [ -n "$CATEGORY" ] && [ -n "$PAYER" ] ||
  die "required: --kg --usd --vendor --pathway --category --payer (plus --receipt PATH or --no-receipt)"

check_numeric "$KG" "--kg"
check_numeric "$USD" "--usd"
echo "$KG" | LC_ALL=C awk '{exit ($1 > 0) ? 0 : 1}' || die "--kg must be > 0"

case "$CATEGORY" in
removal | prevention) ;;
*) die "--category must be 'removal' or 'prevention' (avoidance is prevention; it never counts as removal)" ;;
esac

case "$PATHWAY" in
biochar | refrigerant-destruction | methane | dac | other) ;;
*) die "--pathway must be one of: biochar, refrigerant-destruction, methane, dac, other" ;;
esac

check_charset "$VENDOR" "--vendor"
check_charset "$PAYER" "--payer"

if [ -z "$DATE" ]; then
  DATE="$(date +%Y-%m-%d)"
fi
case "$DATE" in
[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
*) die "--date must be YYYY-MM-DD (got: '$DATE')" ;;
esac

if [ -n "$RETIREMENT_ID" ]; then
  case "$RETIREMENT_ID" in
  *[!A-Za-z0-9._:/\ -]*) die "--retirement-id may only contain [A-Za-z0-9._:/ -]" ;;
  esac
fi

VERIFIED=1
SHA256=""
if [ -n "$RECEIPT" ]; then
  [ -f "$RECEIPT" ] || die "receipt file not found: $RECEIPT"
  SHA256="$(shasum -a 256 "$RECEIPT" | LC_ALL=C awk '{print $1}')"
elif [ "$NO_RECEIPT" = "1" ]; then
  VERIFIED=0
else
  die "a receipt is mandatory for tax records (--receipt PATH). If you truly have none, pass --no-receipt: the row will be stored UNVERIFIED and excluded from the verified balance."
fi

mkdir -p "$STATE_DIR"
ensure_schema "$DB_PATH"

ROW_ID="$(sqlite3 "$DB_PATH" "INSERT INTO offsets
  (purchase_date, vendor, pathway, kg_co2e, usd, category, payer,
   receipt_sha256, verified, retirement_id, notes)
  VALUES ('${DATE}', '$(esc "$VENDOR")', '${PATHWAY}', ${KG}, ${USD}, '${CATEGORY}',
   '$(esc "$PAYER")', '${SHA256}', ${VERIFIED},
   '$(esc "$RETIREMENT_ID")', '$(esc "$NOTES")');
  SELECT last_insert_rowid();")"

refresh_segment_cache "$DB_PATH"

if [ -n "$RECEIPT" ]; then
  YEAR="${DATE%%-*}"
  EXT="${RECEIPT##*.}"
  case "$EXT" in
  "$RECEIPT" | '') EXT="bin" ;; # no extension
  esac
  VENDOR_SLUG="$(printf '%s' "$VENDOR" | tr ' ' '-')"
  DEST_DIR="${STATE_DIR}/receipts/${YEAR}"
  DEST="${DEST_DIR}/${DATE}-${VENDOR_SLUG}-${ROW_ID}.${EXT}"
  mkdir -p "$DEST_DIR"
  cp "$RECEIPT" "$DEST" # copy only; this script never moves or deletes
  sqlite3 "$DB_PATH" "UPDATE offsets SET receipt_path='$(esc "$DEST")' WHERE id=${ROW_ID};
    INSERT OR REPLACE INTO receipt_blobs (offset_id, filename, sha256, content)
    VALUES (${ROW_ID}, '$(esc "$(basename "$DEST")")', '${SHA256}', readfile('$(esc "$DEST")'));"
  echo "Recorded offset #${ROW_ID}: ${KG} kg ${CATEGORY} (${VENDOR}), receipt -> ${DEST}"
  echo "Receipt bytes stored in the ledger DB (receipt_blobs, offset ${ROW_ID})."
  # Best-effort text extraction so receipts are searchable; empty output means
  # "no text" (scanned/odd PDF) and must never block the record.
  PARSED=""
  if command -v python3 >/dev/null 2>&1; then
    PARSED="$(python3 "${SCRIPT_DIR}/lib/pdf-text.py" "$DEST" 2>/dev/null)" || PARSED=""
  fi
  if [ -n "$PARSED" ]; then
    sqlite3 "$DB_PATH" "UPDATE receipt_blobs SET extracted_text='$(esc "$PARSED")'
      WHERE offset_id=${ROW_ID};"
    echo "Receipt text parsed (${#PARSED} chars) and stored for search."
  else
    echo "Receipt text not extractable (scanned or image-only PDF?); stored bytes only."
  fi
else
  echo "Recorded offset #${ROW_ID}: ${KG} kg ${CATEGORY} (${VENDOR}) — UNVERIFIED (no receipt)."
  echo "It will NOT count toward the verified balance until a receipt is attached."
fi
