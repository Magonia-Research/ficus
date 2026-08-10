#!/usr/bin/env bash
# segment-cache.sh — refresh_segment_cache DB_PATH
#
# Atomically rewrites <state>/segment-cache with the pre-formatted all-time
# statusline segment, three lines:
#   1: "∑ ⚡ <kWh> 💧 <L> 💨 <tonnes>"  — all-time readings
#   2: "<owed>/<overall>"  — PURE DOLLAR ledger. Overall = everything emitted
#      priced at the removal rate from data/offset-constants.json; owed =
#      overall minus every dollar contributed (all offset purchases + all
#      donations, 1:1, no kg translation). Unclamped: owed goes NEGATIVE once
#      contributions pass carbon-neutral
#   3: "💨 <paid>t/<emitted>t" — verified removal purchased vs total emitted,
#      rendered on the totals line beneath the separator
# The statusline render path only ever reads this file; all DB work happens
# here, at write time (Stop hook, backfill, recompute, offset recording).
#
# Never fails the caller — persist-session.sh runs without set -e in a hook
# that must exit 0.

refresh_segment_cache() {
  local db="$1" dir seg rate cost tmp
  local lib_dir constants
  dir="$(dirname "$db")"
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  constants="${lib_dir}/../../data/offset-constants.json"

  rate="$(jq -r '.removal_usd_per_tonne // 227' "$constants" 2>/dev/null)" || rate=227
  case "$rate" in
  '' | *[!0-9.]*) rate=227 ;;
  esac

  seg="$(sqlite3 "$db" "SELECT printf('∑ ⚡ %.1fkWh 💧 %.0fL 💨 %.2ft',
      (SELECT COALESCE(SUM(energy_wh),0)/1000.0 FROM sessions WHERE COALESCE(excluded,0)=0),
      (SELECT COALESCE(SUM(water_ml),0)/1000.0 FROM sessions WHERE COALESCE(excluded,0)=0),
      (SELECT COALESCE(SUM(co2_grams),0)/1000000.0 FROM sessions WHERE COALESCE(excluded,0)=0)
    );" 2>/dev/null)" || return 0
  [ -n "$seg" ] || return 0

  cost="$(sqlite3 "$db" "SELECT printf('%.2f/%.2f',
      (SELECT COALESCE(SUM(co2_grams),0)/1000.0 FROM sessions WHERE COALESCE(excluded,0)=0)
      * ${rate} / 1000.0
      - (SELECT COALESCE(SUM(usd),0) FROM offsets)
      - (SELECT COALESCE(SUM(usd),0) FROM donations),
      (SELECT COALESCE(SUM(co2_grams),0)/1000.0 FROM sessions WHERE COALESCE(excluded,0)=0)
      * ${rate} / 1000.0);" 2>/dev/null)" || cost=""

  local bal
  bal="$(sqlite3 "$db" "SELECT printf('💨 %.2ft/%.2ft',
      (SELECT COALESCE(SUM(kg_co2e),0) FROM offsets WHERE category='removal' AND verified=1) / 1000.0,
      (SELECT COALESCE(SUM(co2_grams),0)/1000000.0 FROM sessions WHERE COALESCE(excluded,0)=0)
    );" 2>/dev/null)" || bal=""

  tmp="${dir}/.segment-cache.$$"
  printf '%s\n%s\n%s' "$seg" "$cost" "$bal" >"$tmp" 2>/dev/null && mv -f "$tmp" "${dir}/segment-cache" 2>/dev/null
  return 0
}
