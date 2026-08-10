#!/usr/bin/env bash
# generate-dashboard.sh — build the self-contained HTML dashboard:
# five sqlite3 -json queries -> one jq -c DATA object -> concatenate
# templates/dashboard-head.html + "const DATA = {...};" + dashboard-tail.html
# -> <state>/dashboard/carbon-<ts>.html -> open (file://).
#
# Fully offline by construction: the templates carry inline CSS + vanilla-JS SVG
# only (tests/run-dashboard-tests.sh proves zero external references and
# deterministic output under a pinned CARBON_LEDGER_DASHBOARD_TS).
#
# DATA contract (what the templates render):
#   generated_at   ISO timestamp (pinned by CARBON_LEDGER_DASHBOARD_TS)
#   caveat         the ±50% uncertainty sentence — must stay visible
#   totals         {co2_g, energy_wh, water_ml, embodied_g, cost_usd, sessions}
#   monthly        [{month "YYYY-MM", co2_g, energy_wh, sessions}] ascending
#   by_model       [{family, co2_g, energy_wh, sessions}] desc by co2
#   offset_state   {removal_verified_kg, prevention_verified_kg, unverified_kg,
#                   balance_kg, offset_spent_usd}   — balance counts verified
#                   removal ONLY; prevention/unverified never fold in
#   offsets        [{id, purchase_date, vendor, pathway, kg_co2e, usd, category,
#                   payer, verified, retirement_id, receipt_sha256, receipt_path,
#                   receipt_filename, receipt_b64}] desc by date — receipt_b64 is
#                   the stored blob, "" when none
#   donations      [{id, donation_date, org, usd, payer, receipt_sha256}] desc
#   cost           {rate_usd_per_tonne, overall_usd, contributed_usd, owed_usd}
#                  PURE dollar ledger, UNCLAMPED: owed goes negative once
#                  contributions pass the cost of everything emitted
#   equivalences   {home_days, showers, car_miles} plus the factor, unit, noun
#                  and citation each came from (data/equivalence-constants.json)
#   constants      the physics constants the methodology block prints, read from
#                  data/factors.json so the page can never drift from the ledger
#
# No raw URL ever reaches DATA as free text: citation URLs travel in dedicated
# cite_url fields and are rendered as click-only anchors, which is what keeps
# the offline invariant testable (tests strip href="https://…" and then forbid
# every remaining occurrence of http).

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
DB_PATH="${CARBON_LEDGER_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/carbon-ledger/carbon.db}"
OUT_DIR="${CARBON_LEDGER_DASHBOARD_DIR:-$(dirname "$DB_PATH")/dashboard}"
TS="${CARBON_LEDGER_DASHBOARD_TS:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
HEAD="${REPO_DIR}/templates/dashboard-head.html"
TAIL="${REPO_DIR}/templates/dashboard-tail.html"
EQUIV="${REPO_DIR}/data/equivalence-constants.json"
FACTORS="${REPO_DIR}/data/factors.json"
OFFSET_CONSTANTS="${REPO_DIR}/data/offset-constants.json"
GIVING="${REPO_DIR}/data/giving-shortlist.json"

NO_OPEN=0
case "${1:-}" in --no-open) NO_OPEN=1 ;; esac

[ -f "$DB_PATH" ] || {
  echo "No ledger DB at ${DB_PATH}. Run scripts/setup.sh first." >&2
  exit 1
}
[ -f "$HEAD" ] && [ -f "$TAIL" ] || {
  echo "Missing dashboard templates (templates/dashboard-head.html + dashboard-tail.html)." >&2
  exit 1
}
for f in "$EQUIV" "$FACTORS" "$OFFSET_CONSTANTS" "$GIVING"; do
  [ -f "$f" ] || {
    echo "Missing constants file: ${f}" >&2
    exit 1
  }
done

# Migrate before reading. The series now joins session_days, and a ledger that
# has not run a hook since that table was introduced would not have it — which
# on the first upgrade means the dashboard fails outright instead of rendering
# the history it already holds. ensure_schema is idempotent and silent.
# shellcheck source=lib/schema.sh
source "${SCRIPT_DIR}/lib/schema.sh"
ensure_schema "$DB_PATH"

Q() { sqlite3 -json "$DB_PATH" "$1"; }

# --- the per-day basis every time series is built on --------------------------
# One row per (session, day it actually spent tokens on), preferring the measured
# split in session_days and falling back to charging a session to the day it
# began. Both are needed at once: the split only exists for sessions recorded
# since the Stop hook started writing it, and history cannot be recovered from a
# transcript that has been pruned.
#
# The fallback is the thing worth being loud about. On a real 1,470-session
# ledger only 80 sessions crossed midnight, and those 80 carried 88.7% of the
# carbon — long sessions are the heavy ones and the long ones are what run past
# midnight — so for pre-split history a daily figure is "everything this session
# emitted, filed under the day it started", not "what was emitted that day".
#
# A split session is COUNTED ONCE, on the FIRST day it actually spent tokens, so
# the per-bucket session counts still sum to the real number of sessions while
# the physics lands on the right days.
#
# That first day comes from the split itself and NOT from started_at, which is
# the trap here: the Stop hook stamps started_at when it first sees a session, so
# for a session whose transcript predates the hook run — a resumed or re-read one
# — started_at is not any of the days the session actually worked. Keyed on
# started_at, such a session matched no day at all and dropped out of the counts
# entirely while its carbon stayed on the chart.
DAY_ROWS_CTE="day_rows AS (
    SELECT sd.day AS d, COALESCE(sd.co2_grams,0) AS c, COALESCE(sd.energy_wh,0) AS e,
           COALESCE(sd.water_ml,0) AS w,
           CASE WHEN sd.day = (SELECT MIN(m.day) FROM session_days m
                               WHERE m.session_id = sd.session_id) THEN 1 ELSE 0 END AS n
    FROM session_days sd JOIN sessions s ON s.session_id = sd.session_id
    WHERE COALESCE(s.excluded,0)=0
    UNION ALL
    SELECT date(s.started_at), COALESCE(s.co2_grams,0), COALESCE(s.energy_wh,0),
           COALESCE(s.water_ml,0), 1
    FROM sessions s
    WHERE COALESCE(s.excluded,0)=0 AND s.started_at != ''
      AND NOT EXISTS (SELECT 1 FROM session_days x WHERE x.session_id = s.session_id)
  )"
or_empty() {
  local v
  v="$(cat)"
  echo "${v:-[]}"
}

TOTALS="$(Q "SELECT COALESCE(SUM(co2_grams),0) AS co2_g,
    COALESCE(SUM(energy_wh),0) AS energy_wh, COALESCE(SUM(water_ml),0) AS water_ml,
    COALESCE(SUM(embodied_gco2e),0) AS embodied_g, COALESCE(SUM(cost_usd),0) AS cost_usd,
    COUNT(*) AS sessions
  FROM sessions WHERE COALESCE(excluded,0)=0;" | or_empty)"

# The monthly aggregate carries ALL THREE headline metrics, not carbon alone:
# the time-series panel draws one lane per metric off this single series, and a
# lane that had to be back-computed in the browser would be a second physics
# model living in the template.
MONTHLY="$(Q "WITH ${DAY_ROWS_CTE}
  SELECT substr(d,1,7) AS month,
    ROUND(SUM(c),1) AS co2_g, ROUND(SUM(e),1) AS energy_wh,
    ROUND(SUM(w),1) AS water_ml, SUM(n) AS sessions
  FROM day_rows GROUP BY month ORDER BY month;" | or_empty)"

# --- time buckets ------------------------------------------------------------
# One pre-computed series per granularity, so the page can switch without a
# server and without recomputing physics in the browser. Every bucket in the
# span is emitted, including the empty ones: a period with no sessions really
# did emit nothing, so it is a ZERO and not a gap. Dropping empty periods would
# compress the x-axis and change the shape of the curve into something that
# never happened.
#
# HOURLY IS NOT OFFERED, and the reason is a property of the ledger rather than
# a budget: the finest timestamp kept per session is its start, so an hourly
# bucket would charge a five-hour session entirely to the hour it began.
#
# That reasoning used to end "and a negligible one at daily and coarser", which
# was wrong and is now fixed rather than repeated. Measured on a real
# 1,470-session ledger, 80 sessions crossed midnight — 5% — but they carried
# 88.7% of the carbon, because the long sessions are the heavy ones and the long
# ones are what run past midnight. Sessions are therefore split across days at
# write time now (lib/day-split.sh), from the timestamp each message already
# carries. Only history predating that split still lands on its start day.
bucket_series() { # bucket_series START_MODIFIERS STEP LABEL_FORMAT
  Q "WITH RECURSIVE
      ${DAY_ROWS_CTE},
      bounds AS (SELECT date(MIN(d)${1}) AS lo, date(MAX(d)${1}) AS hi FROM day_rows),
      span(x) AS (SELECT lo FROM bounds
                  UNION ALL SELECT date(x, '${2}') FROM span, bounds WHERE date(x, '${2}') <= hi),
      agg AS (SELECT date(d${1}) AS b,
                ROUND(SUM(c),1) AS c, ROUND(SUM(e),1) AS e, ROUND(SUM(w),1) AS w, SUM(n) AS n
              FROM day_rows GROUP BY b)
    SELECT strftime('${3}', span.x) AS b,
           COALESCE(agg.c,0) AS co2_g, COALESCE(agg.e,0) AS energy_wh,
           COALESCE(agg.w,0) AS water_ml, COALESCE(agg.n,0) AS sessions
    FROM span LEFT JOIN agg ON agg.b = span.x ORDER BY span.x;" | or_empty
}
S_DAY="$(bucket_series ", 'start of day'" "+1 day" "%Y-%m-%d")"
S_WEEK="$(bucket_series ", 'weekday 0', '-6 days'" "+7 days" "%Y-%m-%d")"
S_MONTH="$(bucket_series ", 'start of month'" "+1 month" "%Y-%m")"
S_YEAR="$(bucket_series ", 'start of year'" "+1 year" "%Y")"

# How much of the ledger carries a measured per-day split, so the page can say
# what a daily figure means for THIS ledger instead of asserting a general claim
# about day accuracy that is only true of recent sessions.
DAY_BASIS="$(Q "SELECT
    (SELECT COUNT(*) FROM sessions WHERE COALESCE(excluded,0)=0 AND started_at != '') AS total,
    (SELECT COUNT(DISTINCT session_id) FROM session_days) AS split,
    (SELECT COUNT(*) FROM sessions s WHERE COALESCE(s.excluded,0)=0 AND s.ended_at != ''
       AND date(s.started_at) != date(s.ended_at)
       AND NOT EXISTS (SELECT 1 FROM session_days x WHERE x.session_id = s.session_id)) AS unsplit_crossing;" | or_empty)"

BY_MODEL="$(Q "SELECT fam AS family, ROUND(SUM(co2_grams),1) AS co2_g,
    ROUND(COALESCE(SUM(energy_wh),0),1) AS energy_wh, COUNT(*) AS sessions
  FROM (SELECT CASE
      WHEN model LIKE '%fable%' OR model LIKE '%mythos%' THEN 'fable'
      WHEN model LIKE '%opus%' THEN 'opus'
      WHEN model LIKE '%haiku%' THEN 'haiku'
      ELSE 'sonnet' END AS fam, co2_grams, energy_wh
    FROM sessions WHERE COALESCE(excluded,0)=0)
  GROUP BY fam ORDER BY SUM(co2_grams) DESC;" | or_empty)"

OFFSET_STATE="$(Q "SELECT
    ROUND(COALESCE(SUM(CASE WHEN category='removal' AND verified=1 THEN kg_co2e END),0),2) AS removal_verified_kg,
    ROUND(COALESCE(SUM(CASE WHEN category='prevention' AND verified=1 THEN kg_co2e END),0),2) AS prevention_verified_kg,
    ROUND(COALESCE(SUM(CASE WHEN verified=0 THEN kg_co2e END),0),2) AS unverified_kg,
    ROUND(COALESCE(SUM(usd),0),2) AS offset_spent_usd
  FROM offsets;" | or_empty)"

# receipt_b64 rides the DB blob into the page so the dashboard alone can hand
# the PDF back (data: URI download); base64() needs sqlite3 >= 3.41.
# payer and receipt_sha256 ride along too: they are the audit trail a tax-year
# export is reconciled against (scripts/offset-export.sh).
OFFSETS="$(Q "SELECT o.id, o.purchase_date, o.vendor, o.pathway, o.kg_co2e, o.usd,
    o.category, o.payer, o.verified, COALESCE(o.retirement_id,'') AS retirement_id,
    COALESCE(o.receipt_sha256,'') AS receipt_sha256,
    COALESCE(o.receipt_path,'') AS receipt_path,
    COALESCE(rb.filename,'') AS receipt_filename,
    CASE WHEN rb.content IS NULL THEN ''
      ELSE replace(base64(rb.content), char(10), '') END AS receipt_b64
  FROM offsets o LEFT JOIN receipt_blobs rb ON rb.offset_id = o.id
  ORDER BY o.purchase_date DESC, o.id DESC;" | or_empty)"

DONATIONS="$(Q "SELECT id, donation_date, org, usd, payer,
    COALESCE(receipt_sha256,'') AS receipt_sha256
  FROM donations ORDER BY donation_date DESC, id DESC;" | or_empty)"

# The cost pair is a PURE dollar ledger and stays unclamped: overall prices
# everything emitted at the removal rate; owed subtracts every dollar
# contributed (offsets + donations, 1:1, no kg translation). Once contributions
# pass the overall cost, owed goes negative — that is the carbon-negative state,
# not an error, and the page renders it as an achievement.
CONTRIB="$(Q "SELECT ROUND((SELECT COALESCE(SUM(usd),0) FROM offsets)
    + (SELECT COALESCE(SUM(usd),0) FROM donations), 2) AS contributed_usd;" | or_empty)"

# --- the illustration provenance gate ---------------------------------------
# Artwork on this page has to be verifiably public domain or CC0 and not
# machine-generated. A licence recorded only in a commit message is a licence
# nobody can find later, so an image that cannot name its source, its author,
# its licence and where that licence is stated does not ship at all. This is a
# build-stopping error on purpose: a silent skip would let an unattributed
# illustration reach a document the user files with an accountant.
# An image is either GEOMETRY (viewBox + path d strings) or a RASTER whose src
# must already be an inline data: URI — a src pointing anywhere else would break
# the offline invariant, so it stops the build rather than shipping.
BAD_IMG="$(jq -r '[.orgs[] | select(has("image"))
  | select((((.image.paths // []) | length) == 0 or ((.image.viewBox // "") == ""))
           and (((.image.src // "") | startswith("data:")) | not)
        or ((.image.alt // "") == "")
        or ((.image.credit.title // "") == "")
        or ((.image.credit.author // "") == "")
        or ((.image.credit.agency // "") == "")
        or ((.image.credit.source_url // "") == "")
        or ((.image.credit.license // "") == "")
        or ((.image.credit.license_url // "") == ""))
  | .name] | join(", ")' "$GIVING")"
[ -z "$BAD_IMG" ] || {
  echo "Refusing to build: illustration provenance is incomplete for: ${BAD_IMG}" >&2
  echo "Every image in data/giving-shortlist.json needs alt, a credit block with" >&2
  echo "title, author, agency, source_url, license and license_url, and either" >&2
  echo "viewBox+paths or a src that is already an inline data: URI." >&2
  exit 1
}

DATA="$(jq -cn --arg ts "$TS" \
  --argjson totals "$TOTALS" --argjson monthly "$MONTHLY" \
  --argjson by_model "$BY_MODEL" --argjson offset_state "$OFFSET_STATE" \
  --argjson offsets "$OFFSETS" --argjson donations "$DONATIONS" \
  --argjson contrib "$CONTRIB" --argjson day_basis "$DAY_BASIS" \
  --argjson s_day "$S_DAY" --argjson s_week "$S_WEEK" \
  --argjson s_month "$S_MONTH" --argjson s_year "$S_YEAR" \
  --slurpfile equiv "$EQUIV" --slurpfile factors "$FACTORS" \
  --slurpfile oc "$OFFSET_CONSTANTS" --slurpfile giving "$GIVING" '
  def r2: . * 100 | round / 100;
  # Month-on-month change for one metric, computed HERE rather than in the
  # template: the third badge in every trio is a derived figure, and a figure
  # derived in the browser is a figure that can disagree with the tables.
  # pct is null when there is no prior month, or when the prior month was zero
  # (a percentage change from zero is undefined, not infinite).
  def trend($key): ($monthly | length) as $n
    | if $n == 0 then {latest: 0, prev: 0, pct: null}
      else ($monthly[$n-1][$key] // 0) as $l
        | (if $n > 1 then ($monthly[$n-2][$key] // 0) else null end) as $p
        | {latest: $l, prev: ($p // 0),
           pct: (if $p == null or $p == 0 then null else ((($l - $p) / $p) * 100 | r2) end)}
      end;
  ($totals[0] // {co2_g:0,energy_wh:0,water_ml:0,embodied_g:0,cost_usd:0,sessions:0}) as $T
  | ($equiv[0]) as $E | ($factors[0].physics) as $P
  | (($oc[0].removal_usd_per_tonne // 160)) as $rate
  | (($T.co2_g // 0) / 1000) as $kg
  | (($T.energy_wh // 0) / 1000) as $kwh
  | (($T.water_ml // 0) / 1000) as $liters
  | (($kg / 1000) * $rate | r2) as $overall
  | (($contrib[0].contributed_usd // 0) | r2) as $given
  | {
    generated_at: $ts,
    caveat: "No vendor publishes per-query energy: every figure is an order-of-magnitude estimate (±50%). Trends are meaningful; absolutes are indicative.",
    totals: $T,
    monthly: $monthly,
    trend: {
      month:      (if ($monthly | length) > 0 then $monthly[-1].month else "" end),
      prev_month: (if ($monthly | length) > 1 then $monthly[-2].month else "" end),
      carbon: (trend("co2_g")    | {latest_g:  .latest, prev_g:  .prev, pct: .pct}),
      energy: (trend("energy_wh")| {latest_wh: .latest, prev_wh: .prev, pct: .pct}),
      water:  (trend("water_ml") | {latest_ml: .latest, prev_ml: .prev, pct: .pct})
    },
    # A granularity is offered only when the data can honestly carry it: fewer
    # than 3 buckets is not a series (a single yearly point is a dot, not a
    # trend), and more than 400 is a hairline comb nobody can read. The page
    # states the reason for anything it withholds rather than hiding the option.
    # What a DAY on this page actually means, per session, for this ledger.
    # unsplit_crossing is the honest number: sessions with no measured split that
    # are known to have run past midnight, and are therefore filed whole under
    # the day they began.
    day_basis: (($day_basis[0] // {total:0, split:0, unsplit_crossing:0})),
    series: ({day: $s_day, week: $s_week, month: $s_month, year: $s_year}
      | with_entries(.value |= {rows: ., n: (. | length)})
      | with_entries(.value += {ok: (.value.n >= 3 and .value.n <= 400)})),
    by_model: $by_model,
    offset_state: (($offset_state[0] // {removal_verified_kg:0,prevention_verified_kg:0,unverified_kg:0,offset_spent_usd:0})
      + {balance_kg: (($kg - (($offset_state[0].removal_verified_kg) // 0)) | r2),
         offset_spent_usd: ((($offset_state[0].offset_spent_usd) // 0) | r2)}),
    offsets: $offsets,
    donations: $donations,
    cost: {
      rate_usd_per_tonne: $rate,
      overall_usd: $overall,
      contributed_usd: $given,
      owed_usd: (($overall - $given) | r2)
    },
    equivalences: {
      home_days:  (($kwh * 365 / $E.energy.value) | r2),
      showers:    (($liters / $E.water.value) | r2),
      car_miles:  (($kg / $E.co2.value) | r2),
      energy: ($E.energy | {value, unit, noun, cite, cite_url}),
      water:  ($E.water  | {value, unit, noun, cite, cite_url}),
      co2:    ($E.co2    | {value, unit, noun, cite, cite_url})
    },
    # The giving shortlist is DATA, not template prose: every sentence about an
    # organisation is traceable to data/giving-shortlist.json, which records the
    # research documents each claim came from. The underscore-prefixed keys are
    # provenance for a human reading the file and never reach the page.
    giving: ($giving[0] | {tiers, orgs}),
    # The optional water restoration match. A CONTRIBUTION, never a settlement:
    # it is computed here so the page never asks a reader to convert litres to
    # gallons to certificates in their head, and it is kept entirely out of the
    # carbon cost pair so it can never be mistaken for one. 1 WRC = 1,000 US
    # gallons; both ends of the single-issuer price spread ride along so the
    # page can show the spread instead of one tidy number.
    water_match: (((($T.water_ml // 0) / 1000) as $wl
      | ($wl / 3.785411784) as $gal
      | {liters: ($wl | r2), gallons: ($gal | r2),
         wrc: (($gal / 1000) | r2),
         usd: ((($gal / 1000) * ($oc[0].water_usd_per_kgal_restored // 4)) | r2),
         usd_low: ((($gal / 1000) * ($oc[0].water_usd_per_kgal_reseller // 2)) | r2),
         rate: ($oc[0].water_usd_per_kgal_restored // 4),
         rate_low: ($oc[0].water_usd_per_kgal_reseller // 2)})),
    # Flattened so the colophon can print the provenance of every illustration
    # without walking the org list a second time. Empty when nothing is
    # illustrated, and the credits block then does not render at all.
    # (No apostrophes in this comment: the whole jq program is single-quoted.)
    image_credits: [$giving[0].orgs[] | select(has("image"))
      | (.image.credit + {org: .name})],
    constants: {
      grid_cif_g_per_wh: $P.grid_cif_g_per_wh.value,
      pue: $P.pue.value,
      wue_onsite_l_per_kwh: $P.wue_onsite_l_per_kwh.value,
      wue_offsite_l_per_kwh: $P.wue_offsite_l_per_kwh.value,
      embodied_gco2e_per_kwh: $P.embodied_gco2e_per_kwh.value,
      cache_read_factor: ($factors[0].cache_read_factor // 0.08)
    },
    # The recorded provenance for each physics constant, carried alongside the
    # values so a per-metric explainer can print WHERE a number came from next
    # to the number itself, rather than sending the reader to a separate file.
    # Provenance strings are prose, and one of them embeds a methodology URL.
    # No raw URL may reach the page as free text — that is the rule that keeps
    # the offline invariant testable — so bare URLs are stripped here and the
    # citation reads by name. The full string stays in data/factors.json.
    constant_sources: ({
      grid_cif_g_per_wh:      ($P.grid_cif_g_per_wh._source // ""),
      pue:                    ($P.pue._source // ""),
      wue_onsite_l_per_kwh:   ($P.wue_onsite_l_per_kwh._source // ""),
      wue_offsite_l_per_kwh:  ($P.wue_offsite_l_per_kwh._source // ""),
      embodied_gco2e_per_kwh: ($P.embodied_gco2e_per_kwh._source // ""),
      cache_read_factor:      ($factors[0]._cache_read_factor // "")
    } | with_entries(.value |= (gsub("\\s*https?://[^ ,)]*";"") | gsub("\\s+";" ")))),
    # Formulas are composed here, from the same constants the ledger computes
    # with, so the methodology block can never quote a factor the ledger no
    # longer uses. The template prints these verbatim.
    formulas: {
      co2: "co2_g = ((input + cache_write) × f_in + cache_read × f_in × \(($factors[0].cache_read_factor // 0.08)) + output × f_out) / 1e6",
      energy: "energy_wh = co2_g / \($P.grid_cif_g_per_wh.value)",
      water: "water_ml = energy_wh × (\($P.wue_onsite_l_per_kwh.value)/\($P.pue.value) + \($P.wue_offsite_l_per_kwh.value))",
      embodied: "embodied_g = energy_wh × \($P.embodied_gco2e_per_kwh.value) / 1000",
      balance: "balance_kg = emitted_kg − verified_removal_kg",
      owed: "owed = emitted_t × \($rate) − (offset_$ + donation_$)"
    }
  }')"

mkdir -p "$OUT_DIR"
OUT="${OUT_DIR}/carbon-$(printf '%s' "$TS" | tr ':' '-').html"
{
  cat "$HEAD"
  printf 'const DATA = %s;\n' "$DATA"
  cat "$TAIL"
} >"$OUT"

echo "Dashboard written: ${OUT}"
if [ "$NO_OPEN" = "0" ] && command -v open >/dev/null 2>&1; then
  open "$OUT"
fi
