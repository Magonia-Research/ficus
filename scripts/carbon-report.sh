#!/usr/bin/env bash
# carbon-report.sh — the /carbon report: session footprint totals (co2, energy,
# water, embodied, cost), per-model-family breakdown, and offset state.
#
# Headline balance = lifetime emitted − VERIFIED REMOVAL only. Prevention
# (avoidance leverage) and unverified rows are reported on their own lines and
# never offset the headline. Cost-to-clear uses data/offset-constants.json
# (cited there to the offset-landscape research).
#
# --raw prints key<TAB>value lines for tests and the statusline cache.

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_PATH="${CARBON_LEDGER_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/carbon-ledger/carbon.db}"
CONSTANTS="${SCRIPT_DIR}/../data/offset-constants.json"

RAW=0
case "${1:-}" in
--raw) RAW=1 ;;
--dashboard) exec bash "${SCRIPT_DIR}/generate-dashboard.sh" ;;
esac

[ -f "$DB_PATH" ] || {
  echo "No ledger DB at ${DB_PATH}. Run scripts/setup.sh first." >&2
  exit 1
}

REMOVAL_PER_T="$(jq -er '.removal_usd_per_tonne' "$CONSTANTS")"
PREVENT_PER_T="$(jq -er '.prevention_usd_per_tonne' "$CONSTANTS")"
LINK_REMOVAL="$(jq -er '.links.removal' "$CONSTANTS")"
LINK_PREVENT="$(jq -er '.links.prevention' "$CONSTANTS")"

Q() { sqlite3 "$DB_PATH" "$1"; }

# Sessions (excluded rows carry no estimate and are left out)
read -r EMITTED_G ENERGY_WH WATER_ML EMBODIED_G COST SESSIONS <<EOF
$(Q "SELECT printf('%.4f', COALESCE(SUM(co2_grams),0)),
      printf('%.4f', COALESCE(SUM(energy_wh),0)),
      printf('%.4f', COALESCE(SUM(water_ml),0)),
      printf('%.4f', COALESCE(SUM(embodied_gco2e),0)),
      printf('%.2f', COALESCE(SUM(cost_usd),0)),
      COUNT(*)
    FROM sessions WHERE COALESCE(excluded,0)=0;" | tr '|' ' ')
EOF

# Offsets
read -r REMOVAL_V PREVENT_V UNVERIFIED OFFSET_USD <<EOF
$(Q "SELECT printf('%.2f', COALESCE(SUM(CASE WHEN category='removal' AND verified=1 THEN kg_co2e END),0)),
      printf('%.2f', COALESCE(SUM(CASE WHEN category='prevention' AND verified=1 THEN kg_co2e END),0)),
      printf('%.2f', COALESCE(SUM(CASE WHEN verified=0 THEN kg_co2e END),0)),
      printf('%.2f', COALESCE(SUM(usd),0))
    FROM offsets;" | tr '|' ' ')
EOF

EMITTED_KG="$(echo "$EMITTED_G" | awk '{printf "%.2f", $1 / 1000}')"
BALANCE_KG="$(echo "$EMITTED_KG $REMOVAL_V" | awk '{printf "%.2f", $1 - $2}')"
CLEAR_KG="$(echo "$BALANCE_KG" | awk '{printf "%.2f", ($1 > 0) ? $1 : 0}')"
COST_CLEAR_REM="$(echo "$CLEAR_KG $REMOVAL_PER_T" | awk '{printf "%.2f", $1 * $2 / 1000}')"
COST_CLEAR_PRE="$(echo "$CLEAR_KG $PREVENT_PER_T" | awk '{printf "%.2f", $1 * $2 / 1000}')"

if [ "$RAW" = "1" ]; then
  printf 'emitted_kg\t%s\n' "$EMITTED_KG"
  printf 'removal_verified_kg\t%s\n' "$REMOVAL_V"
  printf 'prevention_verified_kg\t%s\n' "$PREVENT_V"
  printf 'unverified_kg\t%s\n' "$UNVERIFIED"
  printf 'balance_kg\t%s\n' "$BALANCE_KG"
  printf 'cost_to_clear_removal_usd\t%s\n' "$COST_CLEAR_REM"
  printf 'cost_to_clear_prevention_usd\t%s\n' "$COST_CLEAR_PRE"
  printf 'energy_wh\t%s\n' "$ENERGY_WH"
  printf 'water_ml\t%s\n' "$WATER_ML"
  printf 'embodied_gco2e\t%s\n' "$EMBODIED_G"
  printf 'cost_usd\t%s\n' "$COST"
  printf 'sessions\t%s\n' "$SESSIONS"
  printf 'offset_spent_usd\t%s\n' "$OFFSET_USD"
  exit 0
fi

ENERGY_KWH="$(echo "$ENERGY_WH" | awk '{printf "%.2f", $1 / 1000}')"
WATER_L="$(echo "$WATER_ML" | awk '{printf "%.1f", $1 / 1000}')"
EMBODIED_KG="$(echo "$EMBODIED_G" | awk '{printf "%.2f", $1 / 1000}')"

echo "carbon-ledger report"
echo "════════════════════════════════════════"
echo ""
echo "Lifetime footprint (${SESSIONS} sessions)"
echo "  CO2 (operational) : ${EMITTED_KG} kg"
echo "  CO2 (embodied HW) : ${EMBODIED_KG} kg"
echo "  Energy            : ${ENERGY_KWH} kWh"
echo "  Water             : ${WATER_L} L"
echo "  API-value cost    : \$${COST}"
echo ""
echo "By model family"
Q "SELECT '  ' || fam || ' : ' ||
      printf('%9.1f g CO2  %8.1f Wh  (%d sessions)',
        SUM(co2_grams), COALESCE(SUM(energy_wh),0), COUNT(*))
    FROM (SELECT CASE
        WHEN model LIKE '%fable%' OR model LIKE '%mythos%' THEN 'fable '
        WHEN model LIKE '%opus%' THEN 'opus  '
        WHEN model LIKE '%haiku%' THEN 'haiku '
        ELSE 'sonnet' END AS fam, co2_grams, energy_wh
      FROM sessions WHERE COALESCE(excluded,0)=0)
    GROUP BY fam ORDER BY SUM(co2_grams) DESC;"
echo ""
echo "Offset state (removal counts; prevention & unverified never offset the headline)"
echo "  Emitted            : ${EMITTED_KG} kg"
echo "  Removed (verified) : ${REMOVAL_V} kg"
echo "  Prevention (own line, not removal) : ${PREVENT_V} kg"
echo "  Unverified rows (no receipt)       : ${UNVERIFIED} kg"
echo "  ─────────────────────────────"
echo "  UNOFFSET BALANCE   : ${BALANCE_KG} kg"
echo "  Offset spend to date: \$${OFFSET_USD}"
echo ""
echo "Cost to clear the balance (ex-post only)"
echo "  Removal   (biochar CORCs ~\$${REMOVAL_PER_T}/t) : \$${COST_CLEAR_REM}  -> ${LINK_REMOVAL}"
echo "  Prevention (Tradewater ~\$${PREVENT_PER_T}/t)    : \$${COST_CLEAR_PRE}  -> ${LINK_PREVENT}"
echo ""
echo "Caveat: no vendor publishes per-query energy; every figure here is an"
echo "order-of-magnitude estimate (±50%). Trends are meaningful; absolutes are indicative."
