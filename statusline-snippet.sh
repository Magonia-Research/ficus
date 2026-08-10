#!/usr/bin/env bash
# statusline-snippet.sh — REFERENCE implementation of the carbon statusline
# segment: session-live ⚡ energy / 💧 water / 💨 co2 plus the cached 💨
# paid-off/emitted pair. See docs/statusline-segment.md for merging this into an
# existing statusline (fold the jq fields into your existing single jq call).
#
# Render-path budget rules: NO DB access, NO jq against factors.json — only
# `source factors.env`, one awk, and `cat` of the pre-formatted segment cache.
# Both files are written by the fork's scripts (setup/recompute for factors.env;
# persist-session/offset-record for segment-cache).

STATE_DIR="${CARBON_LEDGER_STATE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/carbon-ledger}"

INPUT="$(cat)"
IFS="$(printf '\t')" read -r MODEL_ID IN_TOK OUT_TOK <<EOF
$(echo "$INPUT" | jq -r '[.model.id // "", (.context_window.total_input_tokens // 0), (.context_window.total_output_tokens // 0)] | @tsv' 2>/dev/null)
EOF

[ -f "${STATE_DIR}/factors.env" ] || exit 0
# shellcheck source=/dev/null
. "${STATE_DIR}/factors.env"

# First-match family precedence, mirroring scripts/lib/model-family.sh
# (model ids from Claude Code are lowercase). Non-Claude models get no estimate.
case "$MODEL_ID" in
*fable* | *mythos*) FIN="$CL_F_FAB_IN" FOUT="$CL_F_FAB_OUT" ;;
*opus*) FIN="$CL_F_OPUS_IN" FOUT="$CL_F_OPUS_OUT" ;;
*haiku*) FIN="$CL_F_HAI_IN" FOUT="$CL_F_HAI_OUT" ;;
*claude*) FIN="$CL_F_SON_IN" FOUT="$CL_F_SON_OUT" ;;
*) FIN=0 FOUT=0 ;;
esac

# One awk: session readings + session offset cost (co2 x removal $/t).
#
# THE SESSION COST CARRIES ITS OWN UNIT, and below a dollar that unit is cents.
# At $227 a tonne a whole cent is 44 g of CO2e, so a dollars-and-cents session
# figure reads $0.00 through the opening stretch of every session and then
# jumps — which is indistinguishable from a figure that has stopped updating.
# The same session in cents opens at 0.04¢ and climbs continuously, so a reader
# can see at a glance that it is live.
IFS="$(printf '\t')" read -r SEG SESS_COST <<EOF
$(echo "$IN_TOK $OUT_TOK $FIN $FOUT $CL_CIF $CL_WATER_PER_WH ${CL_REMOVAL_USD_PER_T:-227}" | LC_ALL=C awk \
  '{co2 = ($1 * $3 + $2 * $4) / 1000000
    e = (co2 > 0) ? co2 / $5 : 0
    c = co2 * $7 / 1000000
    printf "⚡ %.2fWh 💧 %.1fmL 💨 %.2fg\t%s", e, e * $6, co2,
      (c < 1) ? sprintf("%.2f¢", c * 100) : sprintf("$%.2f", c)}')
EOF

# Cache: line 1 = all-time ∑ readings; line 2 = owed/overall cost pair (USD
# still owed to clear the balance over the overall emitted cost);
# line 3 = 💨 paid-off/emitted (tonnes)
ALL=""
TOTAL_COST=""
BAL=""
if [ -f "${STATE_DIR}/segment-cache" ]; then
  ALL="$(sed -n 1p "${STATE_DIR}/segment-cache")"
  TOTAL_COST="$(sed -n 2p "${STATE_DIR}/segment-cache")"
  BAL="$(sed -n 3p "${STATE_DIR}/segment-cache")"
fi

# SESSION FIGURES TOGETHER, TOTALS TOGETHER, and the rule between them means
# what it says. The session cost used to sit in the totals cluster beside the
# lifetime dollar pair, which put a figure about the last twenty minutes inside
# a row about every session ever recorded — two different denominators reading
# as one line. It now rides with the ⚡/💧/💨 it was computed from.
printf '%s · ▲ %s session\n' "$SEG" "$SESS_COST"
printf '────────────────────────────────\n'
TOTALS="$ALL"
[ -n "$BAL" ] && TOTALS="${TOTALS:+${TOTALS} · }${BAL}"
[ -n "$TOTAL_COST" ] && TOTALS="${TOTALS:+${TOTALS} · }\$${TOTAL_COST} total"
printf '%s' "$TOTALS"
