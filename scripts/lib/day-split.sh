#!/usr/bin/env bash
# day-split.sh — day_split_jsonl FILE
#
# Emits one TSV row per CALENDAR DAY the transcript actually touched:
#
#   YYYY-MM-DD <TAB> input <TAB> cache_creation <TAB> cache_read <TAB> output
#
# WHY THIS EXISTS. The ledger stores one row per session with a single
# started_at, so every figure derived from it charges a whole session to the day
# it began. That was defensible while the chart bucketed by month. It is not
# defensible now that the chart draws days: measured on a real 1,470-session
# ledger, only 80 sessions cross midnight — but those 80 carry 88.7% of the
# carbon, because the long sessions are the heavy ones and the long sessions are
# exactly the ones that run past midnight. The distortion is not in the tail, it
# is the main body of the data.
#
# Nothing here is apportioned or assumed. Every assistant message in a transcript
# carries its own timestamp next to its own token usage, so the split is a
# GROUPING of measurements, not a model of them: a session that ran from 22:00 to
# 02:00 puts the tokens it actually spent before midnight on one day and the rest
# on the next.
#
# Dates are UTC, taken from the timestamp's own date part, which matches the
# started_at the rest of the ledger records with `date -u`.
#
# The dedup mirrors aggregate_jsonl's exactly — last write wins on
# (message.id, requestId), unkeyed messages pass through — so the per-day rows
# sum to the same token counts the session row holds. It is a separate function
# rather than an extension of that one because aggregate_jsonl is deliberately
# kept byte-close to upstream for cherry-picks (see MAINTENANCE.md).
#
# Never fails its caller: it runs inside the Stop hook, which must exit 0.

day_split_jsonl() {
  jq -rs '
    [.[] | select(.type == "assistant" and .message.usage != null
                  and ((.timestamp // "") | length) >= 10)] as $all
    | (
        ($all | map(select(.message.id != null and .requestId != null))
              | reduce .[] as $m ({}; .[($m.message.id|tostring) + "|" + ($m.requestId|tostring)] = $m)
              | [.[]])
        + ($all | map(select(.message.id == null or .requestId == null)))
      )
    | group_by(.timestamp[0:10])
    | map([ .[0].timestamp[0:10],
            (map(.message.usage.input_tokens // 0)                | add // 0),
            (map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
            (map(.message.usage.cache_read_input_tokens // 0)     | add // 0),
            (map(.message.usage.output_tokens // 0)               | add // 0) ]
          | @tsv)
    | .[]
  ' "$1" 2>/dev/null || true
}
