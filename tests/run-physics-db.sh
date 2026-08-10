#!/usr/bin/env bash
# run-physics-db.sh — proves the ledger's physics columns (energy_wh, water_ml,
# embodied_gco2e) exist and follow the documented derivation on every write path:
# backfill, recompute, and the persist-session Stop hook.
#
# Derivation (constants read from data/factors.json .physics):
#   energy_wh      = co2_grams / grid_cif_g_per_wh      (CIF identity, exact)
#   water_ml       = energy_wh * (wue_onsite/pue + wue_offsite)
#   embodied_gco2e = energy_wh * embodied_gco2e_per_kwh / 1000
# Constants themselves are locked by tests/methodology-vectors.json expectations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURES="${SCRIPT_DIR}/fixtures/reconciliation"
FACTORS="${REPO_DIR}/data/factors.json"

CIF="$(jq -er '.physics.grid_cif_g_per_wh.value' "$FACTORS")"
PUE="$(jq -er '.physics.pue.value' "$FACTORS")"
WUE_ON="$(jq -er '.physics.wue_onsite_l_per_kwh.value' "$FACTORS")"
WUE_OFF="$(jq -er '.physics.wue_offsite_l_per_kwh.value' "$FACTORS")"
EMB="$(jq -er '.physics.embodied_gco2e_per_kwh.value' "$FACTORS")"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/carbon-ledger-physdb.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

cleanup() {
  case "$TMPROOT" in
  */carbon-ledger-physdb.*) rm -rf "$TMPROOT" ;;
  *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

mkdir -p "${TMPROOT}/config"
cp -R "${FIXTURES}/projects" "${TMPROOT}/config/projects"
DB="${TMPROOT}/carbon.db"

fail=0

# Rows violating the derivation (tolerances absorb the 4-decimal storage rounding).
check_db() {
  local label="$1" bad zeros
  bad="$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE COALESCE(excluded,0)=0 AND (
    energy_wh IS NULL OR water_ml IS NULL OR embodied_gco2e IS NULL
    OR ABS(energy_wh - co2_grams/${CIF}) > 0.001
    OR ABS(water_ml - energy_wh*(${WUE_ON}/${PUE} + ${WUE_OFF})) > 0.005
    OR ABS(embodied_gco2e - energy_wh*${EMB}/1000.0) > 0.001);")"
  zeros="$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE COALESCE(excluded,0)=1 AND (
    COALESCE(energy_wh,0) != 0 OR COALESCE(water_ml,0) != 0 OR COALESCE(embodied_gco2e,0) != 0);")"
  if [ "$bad" != "0" ] || [ "$zeros" != "0" ]; then
    echo "FAIL physics-db (${label}): ${bad} row(s) violate the derivation, ${zeros} excluded row(s) non-zero" >&2
    fail=1
  else
    echo "PASS physics-db (${label})"
  fi
}

# --- path 1: backfill --------------------------------------------------------
CLAUDE_CONFIG_DIR="${TMPROOT}/config" CARBON_LEDGER_DB="$DB" \
  bash "${REPO_DIR}/scripts/backfill.sh" >/dev/null
check_db "backfill"

# --- path 2: persist-session Stop hook ---------------------------------------
HOOK_SESSION="99999999-9999-4999-8999-999999999999"
printf '{"session_id":"%s","transcript_path":"%s","cwd":"/Users/test/projects/fixture-alpha"}\n' \
  "$HOOK_SESSION" "${TMPROOT}/config/projects/fixture-alpha/11111111-1111-4111-8111-111111111111.jsonl" |
  CLAUDE_CONFIG_DIR="${TMPROOT}/config" CARBON_LEDGER_DB="$DB" \
    bash "${REPO_DIR}/scripts/persist-session.sh"

hook_rows="$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='${HOOK_SESSION}';")"
if [ "$hook_rows" != "1" ]; then
  echo "FAIL physics-db: persist-session hook row missing" >&2
  fail=1
fi
check_db "persist-session"

# --- path 3: recompute (overwrites derived columns from raw tokens) ----------
CARBON_LEDGER_DB="$DB" bash "${REPO_DIR}/scripts/recompute.sh" --with-cost >/dev/null
check_db "recompute"

exit "$fail"
