#!/usr/bin/env bash
# carbon-review.sh — the /carbon-review report: every lifetime figure rendered
# as markdown for the agent context window, each translated into a familiar
# scale using data/equivalence-constants.json (published figures with citations;
# the formulas live in that file and are computed HERE, never by the model),
# plus a plain-language explainer of what each metric means and where it comes
# from. Output is deterministic: same DB, byte-identical markdown.
#
# CARBON_LEDGER_EQUIV overrides the equivalence-constants path (tests). If the
# file is missing the familiar-scale column is omitted and its absence stated —
# a public checkout must degrade, not invent numbers.

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_PATH="${CARBON_LEDGER_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/carbon-ledger/carbon.db}"
EQUIV="${CARBON_LEDGER_EQUIV:-${SCRIPT_DIR}/../data/equivalence-constants.json}"
CONSTANTS="${SCRIPT_DIR}/../data/offset-constants.json"

[ -f "$DB_PATH" ] || {
  echo "No ledger DB at ${DB_PATH}. Run scripts/setup.sh first." >&2
  exit 1
}

# Core figures come from the already-tested report, one source of truth for
# excluded-session handling and removal-only balance math.
RAW="$(bash "${SCRIPT_DIR}/carbon-report.sh" --raw)"
raw() { echo "$RAW" | awk -F'\t' -v k="$1" '$1 == k { print $2 }'; }

EMITTED_KG="$(raw emitted_kg)"
REMOVAL_V="$(raw removal_verified_kg)"
PREVENT_V="$(raw prevention_verified_kg)"
UNVERIFIED="$(raw unverified_kg)"
BALANCE_KG="$(raw balance_kg)"
ENERGY_WH="$(raw energy_wh)"
WATER_ML="$(raw water_ml)"
EMBODIED_G="$(raw embodied_gco2e)"
COST="$(raw cost_usd)"
SESSIONS="$(raw sessions)"
OFFSET_USD="$(raw offset_spent_usd)"

Q() { sqlite3 "$DB_PATH" "$1"; }
DONATION_USD="$(Q "SELECT printf('%.2f', COALESCE(SUM(usd),0)) FROM donations;")"
SINCE="$(Q "SELECT COALESCE(substr(MIN(started_at),1,10),'—')
    FROM sessions WHERE COALESCE(excluded,0)=0;")"

ENERGY_KWH="$(echo "$ENERGY_WH" | awk '{printf "%.2f", $1 / 1000}')"
WATER_L="$(echo "$WATER_ML" | awk '{printf "%.1f", $1 / 1000}')"
EMBODIED_KG="$(echo "$EMBODIED_G" | awk '{printf "%.2f", $1 / 1000}')"

RATE="$(jq -er '.removal_usd_per_tonne' "$CONSTANTS")"
OVERALL="$(echo "$EMITTED_KG $RATE" | awk '{printf "%.2f", $1 * $2 / 1000}')"
OWED="$(echo "$OVERALL $OFFSET_USD $DONATION_USD" | awk '{printf "%.2f", $1 - $2 - $3}')"

# Familiar-scale equivalences: value/noun/cite straight from the constants
# file, arithmetic per its _formula fields.
HAVE_EQ=0
if [ -f "$EQUIV" ]; then
  HAVE_EQ=1
  eq() { jq -er "$1" "$EQUIV"; }
  HOME_KWH_YR="$(eq '.energy.value')"
  ENERGY_NOUN="$(eq '.energy.noun')"
  ENERGY_CITE="$(eq '.energy.cite')"
  ENERGY_URL="$(eq '.energy.cite_url')"
  SHOWER_L="$(eq '.water.value')"
  WATER_NOUN="$(eq '.water.noun')"
  WATER_CITE="$(eq '.water.cite')"
  WATER_URL="$(eq '.water.cite_url')"
  MILE_KG="$(eq '.co2.value')"
  CO2_NOUN="$(eq '.co2.noun')"
  CO2_CITE="$(eq '.co2.cite')"
  CO2_URL="$(eq '.co2.cite_url')"

  HOME_DAYS="$(echo "$ENERGY_KWH $HOME_KWH_YR" | awk '{printf "%.1f", $1 * 365 / $2}')"
  SHOWERS="$(echo "$WATER_L $SHOWER_L" | awk '{printf "%.0f", $1 / $2}')"
  MILES="$(echo "$EMITTED_KG $MILE_KG" | awk '{printf "%.0f", $1 / $2}')"
  EMB_MILES="$(echo "$EMBODIED_KG $MILE_KG" | awk '{printf "%.0f", $1 / $2}')"
fi

BY_MODEL="$(Q "SELECT group_concat(line, ' · ') FROM (
    SELECT fam || ' ' || printf('%.2f kg', SUM(co2_grams)/1000.0) ||
      ' (' || COUNT(*) || CASE WHEN COUNT(*)=1 THEN ' session)' ELSE ' sessions)' END AS line
    FROM (SELECT CASE
        WHEN model LIKE '%fable%' OR model LIKE '%mythos%' THEN 'fable'
        WHEN model LIKE '%opus%' THEN 'opus'
        WHEN model LIKE '%haiku%' THEN 'haiku'
        ELSE 'sonnet' END AS fam, co2_grams
      FROM sessions WHERE COALESCE(excluded,0)=0)
    GROUP BY fam ORDER BY SUM(co2_grams) DESC);")"

echo "## Carbon-ledger review — ${SESSIONS} sessions since ${SINCE}"
echo ""
if [ "$HAVE_EQ" = "1" ]; then
  echo "| | Lifetime | ≈ Familiar scale |"
  echo "|---|---|---|"
  echo "| ⚡ Energy | **${ENERGY_KWH} kWh** | ≈ ${HOME_DAYS} ${ENERGY_NOUN} |"
  echo "| 💧 Water | **${WATER_L} L** | ≈ ${SHOWERS} ${WATER_NOUN} |"
  echo "| 💨 CO₂e (operational) | **${EMITTED_KG} kg** | ≈ ${MILES} ${CO2_NOUN} |"
  echo "| 🏭 CO₂e (embodied hardware) | **${EMBODIED_KG} kg** | ≈ ${EMB_MILES} ${CO2_NOUN} |"
  echo "| 💵 API value | **\$${COST}** | list-price value of the usage, not a bill |"
else
  echo "| | Lifetime |"
  echo "|---|---|"
  echo "| ⚡ Energy | **${ENERGY_KWH} kWh** |"
  echo "| 💧 Water | **${WATER_L} L** |"
  echo "| 💨 CO₂e (operational) | **${EMITTED_KG} kg** |"
  echo "| 🏭 CO₂e (embodied hardware) | **${EMBODIED_KG} kg** |"
  echo "| 💵 API value | **\$${COST}** |"
  echo ""
  echo "*Familiar-scale column omitted: equivalence constants unavailable" \
    "(expected at data/equivalence-constants.json).*"
fi
echo ""
echo "**By model family:** ${BY_MODEL}"
echo ""
echo "### Offset ledger"
echo ""
echo "| | kg CO₂e |"
echo "|---|---|"
echo "| Emitted | ${EMITTED_KG} |"
echo "| Removed (verified removal) | ${REMOVAL_V} |"
echo "| Prevention (own line, never nets the headline) | ${PREVENT_V} |"
echo "| Unverified (no receipt) | ${UNVERIFIED} |"
echo "| **Unoffset balance** | **${BALANCE_KG}** |"
echo ""
echo "**Dollar ledger:** \$${OWED} owed of \$${OVERALL} emitted overall —" \
  "every offset and donation dollar nets 1:1; negative owed means you are" \
  "past carbon-neutral in dollars."
echo ""
echo "### What these numbers mean"
echo ""
echo "- **Energy** — electricity attributed to your tokens. No vendor publishes" \
  "per-query energy, so this is estimated from CO₂e via the fork's" \
  "carbon-intensity identity (0.287 gCO₂e per Wh) and moves in lockstep with it."
echo "- **Water** — cooling and generation water behind that electricity:" \
  "energy × (on-site cooling at PUE 1.14 + 5.11 L/kWh U.S. off-site" \
  "generation water). Constants and sources: data/factors.json."
echo "- **CO₂e (operational)** — tokens × per-model emission factors" \
  "(Ficus methodology, grid-average intensity)."
echo "- **CO₂e (embodied hardware)** — the manufacturing share of the servers:" \
  "energy × 44.1 gCO₂e/kWh (8×H100 lifecycle proxy). Reported separately," \
  "never folded into operational."
echo "- **Offset ledger** — the tonnes balance nets VERIFIED REMOVAL only;" \
  "prevention and unverified purchases stay on their own lines. The dollar" \
  "ledger nets every contributed dollar."
if [ "$HAVE_EQ" = "1" ]; then
  echo "- **Familiar-scale factors** — published figures, scale illustration" \
    "only (not scope-matched to the ledger's usage-only CO₂e):"
  echo "  - ${ENERGY_CITE} (${ENERGY_URL})"
  echo "  - ${WATER_CITE} (${WATER_URL})"
  echo "  - ${CO2_CITE} (${CO2_URL})"
fi
echo ""
echo "*Every figure is an order-of-magnitude estimate (±50%): trends are" \
  "meaningful, absolutes are indicative.*"
