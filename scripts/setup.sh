#!/usr/bin/env bash
set -euo pipefail

# setup.sh — Initialize carbon-ledger: check deps, create DB, backfill history, show summary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
DB_DIR="${CONFIG_DIR}/carbon-ledger"
DB_PATH="${DB_DIR}/carbon.db"

echo "🌿 carbon-ledger setup"
echo "─────────────────────────────"

# 1. Check dependencies
echo "Checking dependencies..."

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is not installed. Install with: brew install jq" >&2
  exit 1
fi

if ! command -v sqlite3 &>/dev/null; then
  echo "ERROR: sqlite3 is not installed. Install with: brew install sqlite3" >&2
  exit 1
fi

echo "  jq: OK"
echo "  sqlite3: OK"

# 2. Create directory
echo ""
echo "Creating database directory at ${DB_DIR}..."
mkdir -p "$DB_DIR"

# 3. Create SQLite database with schema (shared DDL + idempotent migrations)
echo "Initializing database at ${DB_PATH}..."
# shellcheck source=lib/schema.sh
source "${SCRIPT_DIR}/lib/schema.sh"
ensure_schema "$DB_PATH"

echo "  Schema created."

# Emit factors.env so the statusline render path never runs jq
# shellcheck source=lib/factors-env.sh
source "${SCRIPT_DIR}/lib/factors-env.sh"
emit_factors_env "${PLUGIN_DIR}/data/factors.json" "$DB_DIR"
echo "  factors.env written."

# 4. Run backfill
echo ""
echo "Running backfill of historical sessions..."
bash "${SCRIPT_DIR}/backfill.sh"

# 5. Show summary
echo ""
echo "─────────────────────────────"
echo "Summary:"

TOTAL_SESSIONS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions;")"
TOTAL_CO2_G="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM sessions;" | LC_ALL=C awk '{printf "%.0f", $1}')"
CURRENT_YEAR="$(date +%Y)"
YEAR_CO2_G="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM sessions WHERE started_at LIKE '${CURRENT_YEAR}%';" | LC_ALL=C awk '{printf "%.0f", $1}')"

# Adaptive CO2 units for total
if [ "$TOTAL_CO2_G" -ge 1000 ] 2>/dev/null; then
  TOTAL_CO2_DISPLAY="$(echo "$TOTAL_CO2_G" | LC_ALL=C awk '{printf "%.1fkg", $1/1000}')"
else
  TOTAL_CO2_DISPLAY="${TOTAL_CO2_G}g"
fi

# Adaptive CO2 units for year
if [ "$YEAR_CO2_G" -ge 1000 ] 2>/dev/null; then
  YEAR_CO2_DISPLAY="$(echo "$YEAR_CO2_G" | LC_ALL=C awk '{printf "%.1fkg", $1/1000}')"
else
  YEAR_CO2_DISPLAY="${YEAR_CO2_G}g"
fi

echo "  Total sessions    : ${TOTAL_SESSIONS}"
echo "  Total CO2         : ${TOTAL_CO2_DISPLAY} CO2"
echo "  CO2 (${CURRENT_YEAR})       : ${YEAR_CO2_DISPLAY} CO2"

# 6. Next steps
echo ""
echo "─────────────────────────────"
echo "Next steps:"
echo ""
echo "1. Add to ${CONFIG_DIR}/settings.json:"
echo ""
cat <<EOF
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "${PLUGIN_DIR}/scripts/persist-session.sh"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "${PLUGIN_DIR}/scripts/safety-rescan.sh"
          }
        ]
      }
    ]
  }
}
EOF
echo ""
echo "2. Reload Claude Code to activate the hooks."
echo ""
echo "Setup complete."
