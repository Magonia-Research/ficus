#!/usr/bin/env bash
# build-docs.sh — render docs/index.html, the GitHub Pages landing page, from
# templates/docs-index.html plus the repository's own data files.
#
# The page explains four things a visitor needs before they trust a number:
# how to install it, where the data comes from, how each figure is calculated,
# and what the organisations it links to actually do. It also links prominently
# to the example dashboard at docs/dashboard.html.
#
# NOTHING ON THIS PAGE IS TYPED TWICE. Every constant, formula, price and
# sentence about an organisation is generated from data/factors.json,
# data/offset-constants.json and data/giving-shortlist.json, which is what stops
# the documentation drifting away from the ledger — the exact failure that let
# the removal price sit at $160 in one place and $227 in another.
#
# The same offline invariant as the dashboard applies: nothing the browser would
# LOAD over the network may appear in a page we publish. Click-only anchor hrefs
# are the one exception, because a link is not a load.
#
#   bash scripts/build-docs.sh

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

TEMPLATE="${REPO_DIR}/templates/docs-index.html"
FACTORS="${REPO_DIR}/data/factors.json"
OFFSETS="${REPO_DIR}/data/offset-constants.json"
GIVING="${REPO_DIR}/data/giving-shortlist.json"
OUT="${REPO_DIR}/docs/index.html"
GENERATED="${CARBON_LEDGER_DOCS_TS:-$(date -u +%Y-%m-%d)}"

for f in "$TEMPLATE" "$FACTORS" "$OFFSETS" "$GIVING"; do
  [ -f "$f" ] || {
    echo "build-docs: missing input: ${f}" >&2
    exit 1
  }
done

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/carbon-ledger-docs.XXXXXX")"
cleanup() {
  case "$TMPROOT" in
  */carbon-ledger-docs.*) rm -rf "$TMPROOT" ;;
  *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

# --- the constants table ------------------------------------------------------
# Rendered from .physics, with the URLs stripped out of the source prose exactly
# as the dashboard's methodology block does it: the citation names the
# publication, and the file itself carries the link. Anything that reaches the
# page as text is @html-escaped at the jq layer, so a stray ampersand in a source
# string cannot produce broken markup.
jq -r --arg cr "$(jq -r '._cache_read_factor // ""' "$FACTORS")" '
  # Stripping a URL out of prose leaves punctuation behind it: a citation
  # written "(https://…, fetched 2026-08-06)" becomes "(, fetched 2026-08-06)".
  # Tidy the wreckage rather than shipping it.
  def clean:
    gsub("\\s*https?://[^ ,)]*"; "")
    | gsub("\\(\\s*,\\s*"; "(")
    | gsub("\\(\\s*\\)"; "")
    | gsub("\\s+"; " ")
    | sub("^\\s+"; "") | sub("\\s+$"; "");
  def human($k):
    { "grid_cif_g_per_wh":      "Grid carbon intensity · g/Wh",
      "pue":                    "Power usage effectiveness (PUE)",
      "wue_onsite_l_per_kwh":   "On-site water use · L/kWh",
      "wue_offsite_l_per_kwh":  "Off-site water use · L/kWh",
      "embodied_gco2e_per_kwh": "Embodied carbon · gCO2e/kWh"
    }[$k] // $k;
  (.physics | to_entries | map(select(.value | type == "object"))
    | map("          <tr><th scope=\"row\">" + (human(.key) | @html)
        + "</th><td class=\"n\">" + (.value.value | tostring)
        + "</td><td class=\"src\">" + ((.value._source // "" | clean) | @html)
        + "</td></tr>") | join("\n"))
  + "\n          <tr><th scope=\"row\">Cache-read factor</th><td class=\"n\">"
  + ((.cache_read_factor // 0.08) | tostring)
  + "</td><td class=\"src\">" + (($cr | clean) | @html) + "</td></tr>"
' "$FACTORS" >"${TMPROOT}/constants.html"

# --- the giving research ------------------------------------------------------
# Grouped by tier, in the tiers array's own order. Every sentence is a field:
# what the organisation does, what it costs, the verdict on whether it settles
# anything, and the live update that says what has changed since the research
# was written. The two entries whose verdict is "this does not offset" are
# rendered exactly like the rest — the honesty is in the copy, not in hiding
# them.
jq -r '
  def esc: . // "" | @html;
  [ .tiers[] as $t
    | "    <div class=\"tier\">\n      <div class=\"tier__h\"><h3>" + ($t.label | esc)
      + "</h3></div>\n      <p class=\"tier__b\">" + ($t.blurb | esc) + "</p>\n"
      + ([ .orgs[] | select(.tier == $t.id)
          | "      <article class=\"org\">\n"
            + "        <div class=\"org__h\">\n"
            + "          <h4>" + (.name | esc) + "</h4>\n"
            + "          <span class=\"org__area\">" + (.area | esc)
              + " · " + (.sub | esc) + "</span>\n"
            + "          <span class=\"chip\">" + (.price | esc) + "</span>\n"
            + "        </div>\n"
            + "        <p>" + (.does | esc) + "</p>\n"
            + "        <p class=\"note\"><strong>On the price.</strong> " + (.price_note | esc) + "</p>\n"
            + "        <p class=\"verdict\">" + (.verdict | esc) + "</p>\n"
            + "        <p class=\"update\"><strong>Since the research was written.</strong> "
              + (.update | esc) + "</p>\n"
            + "        <ul class=\"org__links\">\n"
            + "          <li><a href=\"" + (.url | esc) + "\">" + (.name | esc) + " →</a></li>\n"
            + ([ (.evidence // [])[]
                | "          <li><a href=\"" + (.url | esc) + "\">" + (.label | esc) + "</a></li>" ]
               | join("\n"))
            + (if .news then "\n          <li><a href=\"" + (.news.url | esc) + "\">"
                + (.news.label | esc) + "</a>"
                + (if (.news.note // "") != ""
                   then " <span class=\"note\">(" + (.news.note | esc) + ")</span>" else "" end)
                + "</li>" else "" end)
            + "\n        </ul>\n      </article>\n" ] | join(""))
      + "    </div>" ] | join("\n")
' "$GIVING" >"${TMPROOT}/orgs.html"

for f in constants orgs; do
  [ -s "${TMPROOT}/${f}.html" ] || {
    echo "build-docs: generated an empty ${f} fragment — refusing to publish a page with a hole in it" >&2
    exit 1
  }
done

# --- scalars ------------------------------------------------------------------
# Composed from the same constants the ledger computes with, in the same words
# generate-dashboard.sh uses, so the two pages can never quote different maths.
p() { jq -r "$1" "$2"; }
CIF="$(p '.physics.grid_cif_g_per_wh.value' "$FACTORS")"
PUE="$(p '.physics.pue.value' "$FACTORS")"
WUE_ON="$(p '.physics.wue_onsite_l_per_kwh.value' "$FACTORS")"
WUE_OFF="$(p '.physics.wue_offsite_l_per_kwh.value' "$FACTORS")"
EMB="$(p '.physics.embodied_gco2e_per_kwh.value' "$FACTORS")"
CACHE_READ="$(p '.cache_read_factor // 0.08' "$FACTORS")"
REMOVAL_RATE="$(p '.removal_usd_per_tonne' "$OFFSETS")"
PREVENTION_RATE="$(p '.prevention_usd_per_tonne' "$OFFSETS")"

for v in "$CIF" "$PUE" "$WUE_ON" "$WUE_OFF" "$EMB" "$CACHE_READ" "$REMOVAL_RATE" "$PREVENTION_RATE"; do
  case "$v" in
  '' | null | *[!0-9.]*)
    echo "build-docs: non-numeric constant ('${v}') — refusing to publish" >&2
    exit 1
    ;;
  esac
done

{
  printf 'F_CO2\tco2_g = ((input + cache_write) × f_in + cache_read × f_in × %s + output × f_out) / 1e6\n' "$CACHE_READ"
  printf 'F_ENERGY\tenergy_wh = co2_g / %s\n' "$CIF"
  printf 'F_WATER\twater_ml = energy_wh × (%s/%s + %s)\n' "$WUE_ON" "$PUE" "$WUE_OFF"
  printf 'F_EMBODIED\tembodied_g = energy_wh × %s / 1000\n' "$EMB"
  printf 'CACHE_READ\t%s\n' "$CACHE_READ"
  printf 'CIF\t%s\n' "$CIF"
  printf 'PUE\t%s\n' "$PUE"
  printf 'WUE_ON\t%s\n' "$WUE_ON"
  printf 'WUE_OFF\t%s\n' "$WUE_OFF"
  printf 'EMB\t%s\n' "$EMB"
  printf 'REMOVAL_RATE\t%s\n' "$REMOVAL_RATE"
  printf 'PREVENTION_RATE\t%s\n' "$PREVENTION_RATE"
  printf 'GENERATED\t%s\n' "$GENERATED"
} >"${TMPROOT}/scalars.tsv"

# --- assemble -----------------------------------------------------------------
# Literal substitution, never a regex one: a constant containing & or \ would be
# reinterpreted by sed's replacement syntax, and silently mangling a published
# figure is worse than any amount of awk.
mkdir -p "${REPO_DIR}/docs"
awk -v consts="${TMPROOT}/constants.html" -v orgs="${TMPROOT}/orgs.html" \
  -v scalars="${TMPROOT}/scalars.tsv" '
function lrep(s, from, to,   out, p) {
  while ((p = index(s, from)) > 0) {
    out = out substr(s, 1, p - 1) to
    s = substr(s, p + length(from))
  }
  return out s
}
function emit(path,   line) {
  while ((getline line < path) > 0) print line
  close(path)
}
BEGIN {
  FS = "\t"
  while ((getline line < scalars) > 0) {
    split(line, kv, "\t")
    key[++n] = kv[1]
    val[kv[1]] = kv[2]
  }
  close(scalars)
}
{
  if ($0 ~ /^<!--\{\{CONSTANTS\}\}-->$/) { emit(consts); next }
  if ($0 ~ /^<!--\{\{ORGS\}\}-->$/)      { emit(orgs);   next }
  line = $0
  for (i = 1; i <= n; i++) line = lrep(line, "{{" key[i] "}}", val[key[i]])
  print line
}
' "$TEMPLATE" >"${TMPROOT}/index.html"

# Every placeholder must have been consumed. An unresolved {{TOKEN}} on a
# published page is a broken promise about where the number came from.
if grep -q '{{[A-Z_]*}}\|<!--{{' "${TMPROOT}/index.html"; then
  echo "build-docs: unresolved placeholders remain:" >&2
  grep -o '{{[A-Z_]*}}\|<!--{{[A-Z_]*}}-->' "${TMPROOT}/index.html" | sort -u >&2
  exit 1
fi

# --- the offline invariant ----------------------------------------------------
# Same rule as build-demo.sh: nothing the browser would LOAD may appear in a page
# we publish. Two things are scrubbed before the check rather than exempted from
# it, because both are inert:
#   - click-only anchor hrefs, which is what build-demo.sh already allows, and
#   - the contents of <pre> and <code>, which an install guide cannot do without.
#     A repository address inside a shell snippet is text a human retypes; the
#     browser never dereferences it.
# What survives the scrub is checked strictly, so a URL that wanders into an
# attribute or into ordinary prose still stops the build.
scrub() {
  # `<pre` and not `<pre>`: the blocks carry a tabindex so a keyboard can scroll
  # them, and matching the bare tag silently stopped scrubbing the moment that
  # attribute was added.
  awk '
    { line = $0 }
    /<pre[ >]/ { inpre = 1 }
    inpre { line = "" }
    /<\/pre>/ { inpre = 0 }
    {
      gsub(/href="https:\/\/[^"]*"/, "", line)
      gsub(/<code>[^<]*<\/code>/, "", line)
      print line
    }
  ' "$1"
}
# CAPTURED, NOT PIPED INTO `grep -q`. Under `set -o pipefail`, `grep -q` closes
# the pipe the instant it matches, awk dies of SIGPIPE with status 141, and the
# pipeline reports 141 — so the `if` was FALSE exactly when a violation was
# found. This guard could not fail. It reported success on a page that had a
# bare URL in it, which is the worst way for a safety check to be wrong.
OFFLINE_HITS="$(scrub "${TMPROOT}/index.html" |
  grep -nE 'https?://|<link|src="http|src='"'"'http|@import|url\(http' || true)"
if [ -n "$OFFLINE_HITS" ]; then
  echo "build-docs: refusing to publish — external loaded references found" >&2
  printf '%s\n' "$OFFLINE_HITS" | head -5 >&2
  exit 1
fi

mv -f "${TMPROOT}/index.html" "$OUT"
echo "Docs landing page written: ${OUT}"
