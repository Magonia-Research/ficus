#!/usr/bin/env bash
# run-docs-tests.sh — the published landing page (docs/index.html) must be
# deterministic, self-contained, and generated from the repository's own data
# rather than typed out.
#
# The last constraint is the one with teeth. A documentation page that restates
# a constant in prose is a second copy of that constant, and the second copy is
# the one that goes stale: the removal price moved from $160 to $227 and three
# different files disagreed about it for days. So these assertions check that
# what the page says matches what data/ says, right now, at build time.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/carbon-ledger-docs-t.XXXXXX")"
cleanup() {
  case "$TMPROOT" in
  */carbon-ledger-docs-t.*) rm -rf "$TMPROOT" ;;
  *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

fail=0
OUT="${REPO_DIR}/docs/index.html"

want() { # want DESCRIPTION PATTERN
  if grep -q -e "$2" "$OUT"; then
    echo "PASS docs: $1"
  else
    echo "FAIL docs: $1 (missing: $2)" >&2
    fail=1
  fi
}

# --- it builds, and it builds the same twice ---------------------------------
export CARBON_LEDGER_DOCS_TS="2026-08-09"
if bash "${REPO_DIR}/scripts/build-docs.sh" >/dev/null 2>&1; then
  echo "PASS docs: the landing page builds"
else
  echo "FAIL docs: build-docs.sh failed" >&2
  bash "${REPO_DIR}/scripts/build-docs.sh" 2>&1 | head -5 >&2
  exit 1
fi
cp "$OUT" "${TMPROOT}/run1.html"
bash "${REPO_DIR}/scripts/build-docs.sh" >/dev/null 2>&1
if cmp -s "${TMPROOT}/run1.html" "$OUT"; then
  echo "PASS docs: two builds are byte-identical"
else
  echo "FAIL docs: the build is not deterministic" >&2
  fail=1
fi

# --- offline: nothing the browser would LOAD ---------------------------------
# Click-only anchors and the contents of code blocks are inert and scrubbed
# first; everything left has to be clean. This is the same invariant the
# dashboard carries, and the reason a receipt page can be opened with Wi-Fi off.
scrub() {
  awk '
    { line = $0 }
    /<pre[ >]/ { inpre = 1 }
    inpre { line = "" }
    /<\/pre>/ { inpre = 0 }
    { gsub(/href="https:\/\/[^"]*"/, "", line)
      gsub(/<code>[^<]*<\/code>/, "", line)
      print line }
  ' "$1"
}
offline_hits="$(scrub "$OUT" | grep -nE 'https?://|<link|src="http|@import|url\(http' || true)"
if [ -n "$offline_hits" ]; then
  echo "FAIL docs: an external loaded reference reached the page" >&2
  printf '%s\n' "$offline_hits" | head -3 >&2
  fail=1
else
  echo "PASS docs: no external loaded references"
fi
if grep -qE 'fetch\(|XMLHttpRequest|<script' "$OUT"; then
  echo "FAIL docs: the landing page has script in it — it is static by design" >&2
  fail=1
else
  echo "PASS docs: no script at all (static by design)"
fi
if grep -q '{{[A-Z_]*}}' "$OUT"; then
  echo "FAIL docs: an unresolved placeholder was published" >&2
  fail=1
else
  echo "PASS docs: every placeholder was resolved"
fi

# --- the five things a visitor came for --------------------------------------
want "an install section" 'id="install"'
want "a data-provenance section" 'id="sources"'
want "a calculation section" 'id="maths"'
want "the giving research" 'id="giving"'
want "an example-dashboard section" 'id="example"'
# The link to the example is the one thing that must be impossible to miss:
# above the fold, again in the nav, and again in its own section.
want "the example is linked from the hero" 'btn btn--go" href="dashboard.html"'
want "the example is linked from the nav" '<a href="dashboard.html">Example</a>'
want "the caveat is on the page, not buried" '±50%'
# The same ficus the dashboard carries, so the two pages are visibly one project.
want "the masthead carries the ficus mark" 'aria-label="Ficus"'
# --- WCAG 2.2 AA findings, locked --------------------------------------------
# SC 2.4.11 Focus Not Obscured (Minimum) / F110 — this page has the same sticky
# masthead as the dashboard and originally had none of the mitigation.
want "the scrollport is inset for the sticky masthead" 'scroll-padding-top: 4.5rem'
want "tab stops reserve the masthead height" 'a\[href\], button, summary, input, label, \[tabindex\] { scroll-margin-top'
# SC 2.1.1 Keyboard, Level A. The settings.json snippet is 528px wide against
# 255px of visible width at a 320px viewport — without a tab stop, half the
# install instructions are unreachable without a pointer.
want "code blocks are keyboard-scrollable" '<pre tabindex="0">'
want "table wrappers are keyboard-scrollable" '<div class="tw" tabindex="0">'
# A <footer> inside <main> maps to role=generic, so the licence, methodology and
# notices were unreachable by landmark navigation.
if grep -q '</main>' "$OUT" && [ "$(grep -n '</main>' "$OUT" | head -1 | cut -d: -f1)" -lt "$(grep -n '<footer' "$OUT" | head -1 | cut -d: -f1)" ]; then
  echo "PASS docs: the footer is a contentinfo landmark, not buried in main"
else
  echo "FAIL docs: <footer> is inside <main> — it maps to role=generic there" >&2
  fail=1
fi
want "the skip target can take focus" '<main class="wrap" id="main" tabindex="-1">'
want "the mark is the plant, not a chart glyph" 'The same potted ficus'
want "the page says the example data is fabricated" 'fabricated'

# --- the page and the data agree ---------------------------------------------
RATE="$(jq -r '.removal_usd_per_tonne' "${REPO_DIR}/data/offset-constants.json")"
PREV="$(jq -r '.prevention_usd_per_tonne' "${REPO_DIR}/data/offset-constants.json")"
CIF="$(jq -r '.physics.grid_cif_g_per_wh.value' "${REPO_DIR}/data/factors.json")"
EMB="$(jq -r '.physics.embodied_gco2e_per_kwh.value' "${REPO_DIR}/data/factors.json")"
want "the removal rate matches data/offset-constants.json" "\\\$${RATE} per tonne"
want "the prevention rate matches data/offset-constants.json" "\\\$${PREV}/t"
want "the energy identity quotes the live grid intensity" "energy_wh = co2_g / ${CIF}"
want "the embodied formula quotes the live factor" "energy_wh × ${EMB} / 1000"

# A stale price hiding in the giving copy is exactly the bug this page exists to
# not repeat, so the superseded index figure must not reappear anywhere.
if grep -q '160 / tonne\|≈ \$160' "$OUT"; then
  echo "FAIL docs: the superseded \$160 wholesale index is quoted as a price" >&2
  fail=1
else
  echo "PASS docs: the superseded \$160 index is not quoted as a price"
fi

# --- every organisation in the data reaches the page -------------------------
# Including the ones whose verdict is that they settle nothing. Dropping those
# would turn a research page into a recommendation page.
missing=""
while IFS= read -r org; do
  grep -qF "$org" "$OUT" || missing="${missing}${org}; "
done < <(jq -r '.orgs[].name' "${REPO_DIR}/data/giving-shortlist.json")
if [ -z "$missing" ]; then
  echo "PASS docs: every organisation in the shortlist is on the page"
else
  echo "FAIL docs: organisations missing from the page: ${missing}" >&2
  fail=1
fi
ORG_N="$(jq -r '.orgs | length' "${REPO_DIR}/data/giving-shortlist.json")"
GOT_N="$(grep -c 'class="org"' "$OUT")"
if [ "$ORG_N" = "$GOT_N" ]; then
  echo "PASS docs: ${GOT_N} organisation cards, one per shortlist entry"
else
  echo "FAIL docs: ${ORG_N} organisations in the data but ${GOT_N} cards rendered" >&2
  fail=1
fi
# What each one actually DOES is the point of the section — assert the field is
# rendered, not just the name.
FIRST_DOES="$(jq -r '.orgs[0].does' "${REPO_DIR}/data/giving-shortlist.json" | cut -c1-40)"
if grep -qF "$FIRST_DOES" "$OUT"; then
  echo "PASS docs: the shortlist's own description of the work is rendered"
else
  echo "FAIL docs: organisation descriptions are not on the page" >&2
  fail=1
fi
# Two entries are on the page precisely because the research says they do NOT
# offset. If that verdict ever quietly disappears the page has become a sales
# sheet.
want "the honest non-offset verdict survives" 'not because they offset anything'
want "no affiliate relationship is stated plainly" 'takes no cut'

# --- the demo dashboard moved, and still exists ------------------------------
if [ -f "${REPO_DIR}/docs/dashboard.html" ]; then
  echo "PASS docs: the example dashboard is where the page links to"
else
  echo "FAIL docs: docs/dashboard.html is missing — the hero link is broken" >&2
  fail=1
fi
# The trace SVG is built by the embedded script, so it is not in the served
# markup — the host element and the DATA payload are, and both have to be there
# for the page to be a statement rather than an empty shell.
if grep -q 'id="trace-body"' "${REPO_DIR}/docs/dashboard.html" 2>/dev/null &&
  grep -q 'const DATA = ' "${REPO_DIR}/docs/dashboard.html" 2>/dev/null; then
  echo "PASS docs: the published example is a real rendered dashboard"
else
  echo "FAIL docs: docs/dashboard.html does not look like a rendered dashboard" >&2
  fail=1
fi
# It must be the DEMO, never a render of someone's real ledger. The fabricated
# purchase carries a retirement id that says so in the string itself, which no
# real Puro retirement would.
if grep -q 'PURO-2026-DEMO-0001' "${REPO_DIR}/docs/dashboard.html" 2>/dev/null; then
  echo "PASS docs: the published example is the fabricated demo, not a real ledger"
else
  echo "FAIL docs: docs/dashboard.html is not the fabricated demo — refusing to publish a real ledger" >&2
  fail=1
fi

[ "$fail" = "0" ] || exit 1
echo "All docs assertions passed."
