#!/usr/bin/env bash
# check-crosscheck.sh — blended methodology gate between the Jegham-derived co2
# factors (the ledger's primary methodology) and an independent EcoLogits-derived
# estimate (factors.json .ecologits, cross-check ONLY).
#
# The comparison is BLENDED per-session co2 over the golden-vector token mixes,
# never per-factor: EcoLogits models input/cache-token energy as ~0 while Jegham
# amortizes it into per-token factors, so per-factor comparison diverges by
# construction. Gate: blended totals must agree within 3x either way.
#
# Run on every factors.json change (wired into tests/run-crosscheck.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORS="${CARBON_LEDGER_FACTORS:-${SCRIPT_DIR}/../data/factors.json}"
VECTORS="${SCRIPT_DIR}/../tests/methodology-vectors.json"

# shellcheck source=lib/model-family.sh
source "${SCRIPT_DIR}/lib/model-family.sh"

command -v jq >/dev/null 2>&1 || {
  echo "FAIL: jq is required" >&2
  exit 1
}

# Jegham factors + cache-read energy fraction
F_FAB_IN="$(jq -er '.models.fable.input' "$FACTORS")"
F_FAB_OUT="$(jq -er '.models.fable.output' "$FACTORS")"
F_OPUS_IN="$(jq -er '.models.opus.input' "$FACTORS")"
F_OPUS_OUT="$(jq -er '.models.opus.output' "$FACTORS")"
F_SON_IN="$(jq -er '.models.sonnet.input' "$FACTORS")"
F_SON_OUT="$(jq -er '.models.sonnet.output' "$FACTORS")"
F_HAI_IN="$(jq -er '.models.haiku.input' "$FACTORS")"
F_HAI_OUT="$(jq -er '.models.haiku.output' "$FACTORS")"
CRF="$(jq -r '.cache_read_factor // 0.08' "$FACTORS")"

# Physics + EcoLogits constants
CIF="$(jq -er '.physics.grid_cif_g_per_wh.value' "$FACTORS")"
PUE="$(jq -er '.physics.pue.value' "$FACTORS")"
ALPHA="$(jq -er '.ecologits.alpha_wh_per_token_per_b' "$FACTORS")"
BETA="$(jq -er '.ecologits.beta_per_batch' "$FACTORS")"
GAMMA="$(jq -er '.ecologits.gamma_wh_per_token' "$FACTORS")"
BATCH="$(jq -er '.ecologits.batch_size' "$FACTORS")"
GPU_MEM="$(jq -er '.ecologits.gpu_mem_gb' "$FACTORS")"
GPUS_SRV="$(jq -er '.ecologits.gpus_per_server' "$FACTORS")"
SRV_KW="$(jq -er '.ecologits.server_non_gpu_kw' "$FACTORS")"

# EcoLogits co2 per OUTPUT token for one family (g/token):
#   f_E = alpha*e^(beta*B)*P_active + gamma            (Wh/token per GPU)
#   gpus = next power of two of ceil(1.2 * P_total * 2 bytes / gpu_mem)
#   e_srv = (1/tps/3600) * srv_kw*1000 * (gpus/gpus_per_server) / B
#   co2_tok = PUE * (gpus*f_E + e_srv) * CIF
eco_co2_per_token() {
  local family="$1" p_active p_total tps
  p_active="$(jq -er --arg f "$family" '.ecologits.models[$f].p_active_b' "$FACTORS")"
  p_total="$(jq -er --arg f "$family" '.ecologits.models[$f].p_total_b' "$FACTORS")"
  tps="$(jq -er --arg f "$family" '.ecologits.models[$f].tps' "$FACTORS")"
  echo "$p_active $p_total $tps $ALPHA $BETA $GAMMA $BATCH $GPU_MEM $GPUS_SRV $SRV_KW $PUE $CIF" |
    LC_ALL=C awk '{
      pa=$1; pt=$2; tps=$3; a=$4; b=$5; g=$6; B=$7; mem=$8; gsrv=$9; skw=$10; pue=$11; cif=$12
      fe = a * exp(b * B) * pa + g
      raw = 1.2 * pt * 2 / mem; ngpu = int(raw); if (raw > ngpu) ngpu++
      p = 1; while (p < ngpu) p *= 2
      esrv = (1.0 / tps / 3600.0) * skw * 1000.0 * (p / gsrv) / B
      printf "%.12g", pue * (p * fe + esrv) * cif
    }'
}

ECO_FAB="$(eco_co2_per_token fable)"
ECO_OPUS="$(eco_co2_per_token opus)"
ECO_SON="$(eco_co2_per_token sonnet)"
ECO_HAI="$(eco_co2_per_token haiku)"

JEG_SUM=0
ECO_SUM=0
N="$(jq '.vectors | length' "$VECTORS")"
i=0
while [ "$i" -lt "$N" ]; do
  ROW="$(jq -r --argjson i "$i" '.vectors[$i] | [
    .model, (.input_tokens // 0), (.cache_creation_tokens // 0),
    (.cache_read_tokens // 0), (.output_tokens // 0)
  ] | @tsv' "$VECTORS")"
  IFS="$(printf '\t')" read -r MODEL IN CW CR OUT <<EOF
$ROW
EOF
  i=$((i + 1))

  # Same exclusion rule as the parsers: non-Claude models carry no estimate.
  echo "$MODEL" | grep -qi "claude" || continue

  FAMILY="$(resolve_family "$MODEL")"
  case "$FAMILY" in
  fable) FIN="$F_FAB_IN" FOUT="$F_FAB_OUT" ECO_TOK="$ECO_FAB" ;;
  opus) FIN="$F_OPUS_IN" FOUT="$F_OPUS_OUT" ECO_TOK="$ECO_OPUS" ;;
  haiku) FIN="$F_HAI_IN" FOUT="$F_HAI_OUT" ECO_TOK="$ECO_HAI" ;;
  *) FIN="$F_SON_IN" FOUT="$F_SON_OUT" ECO_TOK="$ECO_SON" ;;
  esac

  JEG="$(echo "$IN $CW $CR $OUT $FIN $FOUT $CRF" | LC_ALL=C awk \
    '{printf "%.6f", (($1 + $2) * $5 + $3 * ($5 * $7) + $4 * $6) / 1000000}')"
  ECO="$(echo "$OUT $ECO_TOK" | LC_ALL=C awk '{printf "%.6f", $1 * $2}')"
  JEG_SUM="$(echo "$JEG_SUM $JEG" | LC_ALL=C awk '{printf "%.6f", $1 + $2}')"
  ECO_SUM="$(echo "$ECO_SUM $ECO" | LC_ALL=C awk '{printf "%.6f", $1 + $2}')"
done

echo "Blended over golden-vector mixes: Jegham ${JEG_SUM} g, EcoLogits ${ECO_SUM} g"
echo "Per-token EcoLogits (g/output token): fable ${ECO_FAB}, opus ${ECO_OPUS}, sonnet ${ECO_SON}, haiku ${ECO_HAI}"

RATIO_OK="$(echo "$JEG_SUM $ECO_SUM" | LC_ALL=C awk '{
  if ($1 <= 0 || $2 <= 0) { print "0"; exit }
  r = $1 / $2; if (r < 1) r = 1 / r
  print (r <= 3) ? "1" : "0"
  printf "" # ratio printed below
}')"
RATIO="$(echo "$JEG_SUM $ECO_SUM" | LC_ALL=C awk '{r = $1 / $2; if (r < 1) r = 1/r; printf "%.2f", r}')"

if [ "$RATIO_OK" != "1" ]; then
  echo "FAIL cross-check: blended divergence ${RATIO}x exceeds the 3x gate — investigate before shipping this factors.json" >&2
  exit 1
fi
echo "PASS cross-check: blended divergence ${RATIO}x (gate: 3x)"
