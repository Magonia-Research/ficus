#!/usr/bin/env bash
# run-dashboard-tests.sh — the dashboard must be deterministic (same fixture DB
# + pinned timestamp -> byte-identical HTML) and fully self-contained (zero
# external references: no http(s)://, no <link>, no external src=), so it
# renders with Wi-Fi off.
#
# It also locks the structure of the redesigned statement: the meter-reading
# band and its evidence-grounded equivalences, the carbon balance, the pure
# dollar ledger (unclamped, so the carbon-negative state is a first-class
# outcome), the tax audit trail with per-payer attribution and SHA-256, the
# giving shortlist with a sources + news link per org, and the methodology
# block. Standing invariants come first; new structure after.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/carbon-ledger-dash.XXXXXX")"
cleanup() {
  case "$TMPROOT" in
  */carbon-ledger-dash.*) rm -rf "$TMPROOT" ;;
  *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

fail=0

want() { # want DESCRIPTION PATTERN
  if grep -q "$2" "$OUT"; then
    echo "PASS dashboard: $1"
  else
    echo "FAIL dashboard: $1 (missing: $2)" >&2
    fail=1
  fi
}

# --- fixture DB: sessions + offsets + donations ------------------------------
DB="${TMPROOT}/carbon.db"
export CARBON_LEDGER_DB="$DB"
# shellcheck source=../scripts/lib/schema.sh
source "${REPO_DIR}/scripts/lib/schema.sh"
ensure_schema "$DB"
sqlite3 "$DB" "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens,
    cost_usd, co2_grams, energy_wh, water_ml, embodied_gco2e, started_at, ended_at,
    source, methodology_version, excluded) VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','p1','claude-fable-5',1,1,42.0,12500.0,43554.0,229421.0,1920.7,
   '2026-06-01T00:00:00Z','2026-06-01T01:00:00Z','backfill',2,0),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','p2','claude-opus-5',1,1,7.0,2000.0,6968.6,36706.0,307.3,
   '2026-07-15T00:00:00Z','2026-07-15T01:00:00Z','backfill',2,0),
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','p3','qwen-local',1,1,0,0,0,0,0,
   '2026-07-20T00:00:00Z','2026-07-20T01:00:00Z','backfill',2,1);
  INSERT INTO offsets (purchase_date, vendor, pathway, kg_co2e, usd, category, payer,
    receipt_path, receipt_sha256, verified, retirement_id, created_at) VALUES
  ('2026-08-01','remove-carbon-today','biochar',10.0,1.60,'removal','Acme Research LLC',
   '/tmp/r1.pdf','abc123',1,'PURO-1','2026-08-01T00:00:00Z'),
  ('2026-08-02','tradewater','refrigerant-destruction',200.0,3.00,'prevention','Example Media Co',
   '/tmp/r2.pdf','def456',1,'','2026-08-02T00:00:00Z');
  INSERT INTO receipt_blobs (offset_id, filename, sha256, content, stored_at) VALUES
  (1,'2026-08-01-remove-carbon-today-1.pdf','abc123',x'25504446','2026-08-01T00:00:00Z');
  INSERT INTO donations (donation_date, org, usd, payer, receipt_path, receipt_sha256, created_at) VALUES
  ('2026-08-03','naturaland-trust',12.00,'Example Media Co','/tmp/d1.pdf','fed789','2026-08-03T00:00:00Z');"

export CARBON_LEDGER_DASHBOARD_DIR="${TMPROOT}/dash"
export CARBON_LEDGER_DASHBOARD_TS="2026-08-06T12:00:00Z"

# --- determinism: two runs, byte-identical -----------------------------------
bash "${REPO_DIR}/scripts/generate-dashboard.sh" --no-open >/dev/null 2>&1 || {
  echo "FAIL dashboard: generate run 1 failed" >&2
  exit 1
}
OUT="${CARBON_LEDGER_DASHBOARD_DIR}/carbon-2026-08-06T12-00-00Z.html"
[ -f "$OUT" ] || {
  echo "FAIL dashboard: expected output at $OUT" >&2
  exit 1
}
cp "$OUT" "${TMPROOT}/run1.html"
bash "${REPO_DIR}/scripts/generate-dashboard.sh" --no-open >/dev/null 2>&1
if cmp -s "${TMPROOT}/run1.html" "$OUT"; then
  echo "PASS dashboard: deterministic under pinned timestamp"
else
  echo "FAIL dashboard: two runs differ on the same fixture DB" >&2
  fail=1
fi

# --- zero external references ------------------------------------------------
# Three narrow, named exceptions, all click-only and none ever fetched:
#   href="https://..."        anchors the renderer built, already in the markup
#   "cite_url":"https://..."  the equivalence citations inside the DATA object
#   "url":"https://..."       the giving shortlist's donate, evidence and news
#                             links, which ride in as data rather than template
#                             prose (data/giving-shortlist.json)
# The last two are values the renderer only ever hands to setAttribute("href") —
# never to a src, a stylesheet, an import or an SVG reference.
# Anything else the browser would LOAD over the network fails the page: it must
# still render fully with Wi-Fi off, which is also why typography comes from a
# system-font stack and never a webfont.
STRIP='s/href="https:\/\/[^"]*"//g; s/"[a-z_]*url":"https:\/\/[^"]*"//g'
if sed "$STRIP" "$OUT" |
  grep -qE 'https?://|<link|src="http|src='"'"'http|@import|url\(http'; then
  echo "FAIL dashboard: external LOADED references found:" >&2
  sed "$STRIP" "$OUT" |
    grep -nE 'https?://|<link|src="http|@import|url\(http' | head -5 >&2
  fail=1
else
  echo "PASS dashboard: zero loaded external references (offline-safe)"
fi
grep -q '@font-face' "$OUT" && {
  echo "FAIL dashboard: @font-face present — typography must be system fonts only" >&2
  fail=1
} || echo "PASS dashboard: no @font-face (system-font stack only)"

# --- the embedded script must actually parse -----------------------------
# Every other assertion in this file greps the source. None of them execute it,
# so a syntax error in the renderer ships a blank page while the suite stays
# green — which is exactly what happened when the water copy landed with a
# stray semicolon inside an object literal. Extract the script and parse it.
# Containerised, and skipped rather than failed where no container runtime is
# available, so this file still runs anywhere.
#
# A FAILED RUN IS NOT A FAILED PARSE. `container` on PATH says nothing about
# whether its service is up: with the daemon stopped the run exits non-zero
# having never reached node, and reporting that as a syntax error sends someone
# hunting a bug in the renderer that is not there. So the verdict is taken from
# what node actually said — a SyntaxError is a failure, anything else is a skip
# with its reason printed.
if command -v container >/dev/null 2>&1; then
  SCRIPT_JS="${TMPROOT}/embedded.js"
  awk '/^<script>$/{flag=1;next} /^<\/script>$/{flag=0} flag' "$OUT" >"$SCRIPT_JS"
  if [ ! -s "$SCRIPT_JS" ]; then
    echo "FAIL dashboard: could not extract the embedded script" >&2
    fail=1
  else
    chk_out="$(container run --rm --platform linux/arm64 \
      --mount "type=bind,source=${TMPROOT},target=/t" node:22-slim \
      node --check /t/embedded.js 2>&1)"
    chk_rc=$?
    if [ "$chk_rc" -eq 0 ]; then
      echo "PASS dashboard: the embedded renderer parses"
    elif printf '%s' "$chk_out" | grep -q 'SyntaxError'; then
      echo "FAIL dashboard: the embedded renderer has a syntax error" >&2
      printf '%s\n' "$chk_out" | head -5 >&2
      fail=1
    else
      echo "SKIP dashboard: container runtime unavailable, embedded script not parsed"
      printf '%s\n' "$chk_out" | grep -v '^\[[0-9]' | head -2
    fi
  fi
else
  echo "SKIP dashboard: no container runtime, embedded script not parsed"
fi

# --- content invariants ------------------------------------------------------
want "DATA embedded" 'const DATA = '
want "caveat present" '±50%'
want "complete HTML document" '</html>'
# The fixture's two non-excluded sessions emit 12500 + 2000 = 14500 g = 14.5 kg;
# the excluded qwen-local row contributes nothing. 14.5 − 10.0 verified removal
# = 4.5. Folding in the 200 kg prevention purchase would give −195.5, and
# counting it as "offset progress" would give 0 — both are wrong.
want "balance = emitted − verified removal only (4.5 kg)" '"balance_kg":4.5'

# --- real-world equivalences, computed from the DB at generation time --------
# energy 50522.6 Wh = 50.5226 kWh; at EIA 10,791 kWh/home/yr that is
#   50.5226 * 365 / 10791 = 1.71 days of an average U.S. home's electricity.
# water 266127 mL = 266.127 L; at EPA WaterSense 63.6 L/shower = 4.18 showers.
# co2 14.5 kg; at EPA 0.393 kg CO2e/mile = 36.9 miles driven.
want "equivalence: home-electricity days" '"home_days":1.71'
want "equivalence: showers" '"showers":4.18'
want "equivalence: car miles" '"car_miles":36.9'
want "equivalence factors carry their source" '"cite"'
want "equivalence cites EIA" 'eia.gov'
want "equivalence cites EPA" 'epa.gov'

# --- the dollar ledger: pure dollars, unclamped ------------------------------
# overall = 14.5 kg = 0.0145 t x $227/t = $3.29.
# contributed = every dollar given: offsets 1.60 + 3.00, donations 12.00 = $16.60.
# owed = 3.29 − 16.60 = −$13.31. Clamping at zero would erase the achievement.
want "dollar ledger overall" '"overall_usd":3.29'
want "dollar ledger contributed" '"contributed_usd":16.6'
want "dollar ledger owed is unclamped and negative" '"owed_usd":-13.31'
want "carbon-negative state is named" 'carbon-negative'

# --- tax audit trail ---------------------------------------------------------
want "audit trail section" 'id="h-audit"'
want "per-payer attribution: first payer" 'Acme Research LLC'
want "per-payer attribution: second payer" 'Example Media Co'
want "receipt SHA-256 recorded" '"receipt_sha256":"abc123"'
want "donation recorded with payer" '"org":"naturaland-trust"'
want "tax-year CSV export named" 'offset-export.sh'
want "retirement id surfaced" 'PURO-1'

# Receipt blobs ride along as base64 so the dashboard alone can hand back the
# PDF (data: URI + download attribute); rows without a blob carry "".
want "receipt blob embedded as base64" '"receipt_b64":"JVBERg=="'
want "blobless purchase carries empty receipt_b64" '"receipt_b64":""'
want "receipt link is a self-contained data: URI download" 'data:application/pdf;base64'

# --- monthly series: one row per month carrying every metric -----------------
# The three headline metrics each get their own lane in the time-series panel,
# so the monthly aggregate has to carry all three — not carbon alone. The
# fixture emits in 2026-06 and 2026-07 only (the 2026-07 qwen row is excluded).
want "monthly series carries carbon" '"month":"2026-06","co2_g":12500'
want "monthly series carries energy" '"energy_wh":43554'
want "monthly series carries water" '"water_ml":229421'

# --- trend: the third badge in each trio -------------------------------------
# Latest month against the one before it, computed in the generator. 2026-07 is
# 2000 g against 2026-06's 12500 g: (2000-12500)/12500 = -84%.
want "trend names the latest month" '"month":"2026-07"'
want "trend names the month it compares against" '"prev_month":"2026-06"'
want "trend carries the latest carbon figure" '"latest_g":2000'
want "trend carries a signed percentage change" '"pct":-84'
want "trend covers energy too" '"latest_wh":6968.6'
want "trend covers water too" '"latest_ml":36706'

# --- giving shortlist rides in as DATA, not template prose -------------------
want "giving shortlist embedded as data" '"giving":{'
want "giving shortlist is tiered" '"id":"settles"'
want "prevention tier is named separately" '"id":"prevents"'
want "conservation tier is named separately" '"id":"fund-separately"'
want "each org states what it does" '"does":"'
want "each org carries a price signal" '"price":"'
want "each org carries the honest carbon verdict" '"verdict":"'
want "each org carries supporting research or an update" '"update":"'
org_missing=0
for org in "Remove Carbon Today" "Tradewater" "Naturaland Trust" "American Rivers" \
  "Congaree Land Trust" "Billion Oyster Project" "Coral Restoration Foundation"; do
  grep -qF "\"name\":\"$org\"" "$OUT" || {
    echo "FAIL dashboard: giving shortlist missing org: $org" >&2
    org_missing=1
    fail=1
  }
done
[ "$org_missing" = "0" ] && echo "PASS dashboard: all seven orgs ride in as data"

# --- giving shortlist: donate + sources + news per org -----------------------
give_missing=0
for link in \
  removecarbontoday.com/collections \
  removecarbontoday.com/pages/proof-of-removal \
  puro.earth/insights \
  tradewater.co/buy-credits \
  tradewater.co/wp-content/uploads/2024/12 \
  tradewater.co/press \
  americanrivers.org/donate \
  arb.ca.gov/sites/default/files/2026-04 \
  americanrivers.org/media-center \
  coralrestoration.org/donate \
  pmc.ncbi.nlm.nih.gov/articles/PMC11555216 \
  coralrestoration.org/blog \
  billionoysterproject.org/donate \
  pubmed.ncbi.nlm.nih.gov/28747477 \
  billionoysterproject.org/blog \
  naturalandtrust.org/donate-now \
  greenvillejournal.com/outdoors-recreation/naturaland-trust-leads-conservation \
  naturalandtrust.org/enewsletter \
  congareelt.org/donate \
  frontiersin.org/journals/forests-and-global-change \
  congareelt.org/news; do
  grep -q "$link" "$OUT" || {
    echo "FAIL dashboard: giving-shortlist link missing: $link" >&2
    give_missing=1
    fail=1
  }
done
if [ "$give_missing" = "0" ]; then
  echo "PASS dashboard: giving shortlist carries donate + sources + news for all seven orgs"
fi
want "giving section heading" 'id="h-give"'

# --- charity hero imagery: the slot, and the gate that guards it -------------
# Images are optional per organisation and carry no markup: an entry supplies a
# viewBox and a list of path "d" strings, which the renderer feeds to
# createElementNS/setAttribute. Nothing is ever parsed as HTML, so an
# illustration cannot become an injection vector.
#
# The gate matters more than the slot. Artwork on this page has to be verifiably
# public domain or CC0 and not machine-generated, and a licence recorded in a
# commit message is a licence nobody can find later. So the generator REFUSES TO
# BUILD if an image is missing any part of its provenance, and the page prints
# the credits where a reader can check them.
if grep -oE '<img[^>]*src="[^"]*"' "$OUT" | grep -qvE 'src="data:'; then
  echo "FAIL dashboard: an <img> loads something that is not an inline data: URI" >&2
  grep -oE '<img[^>]*src="[^"]*"' "$OUT" | grep -vE 'src="data:' | head -3 >&2
  fail=1
else
  echo "PASS dashboard: no externally-loaded image on the page"
fi
want "the hero image runs the full width of the card" 'org__banner'
# Every card is accounted for: it either carries an image or is deliberately
# text-only because no verifiable federal photograph of its subject exists.
# Nothing may be silently missing.
imaged=$(jq '[.orgs[] | select(has("image"))] | length' "${REPO_DIR}/data/giving-shortlist.json")
total=$(jq '.orgs | length' "${REPO_DIR}/data/giving-shortlist.json")
textonly=$(jq -r '[.orgs[] | select(has("image") | not) | .name] | join(", ")' \
  "${REPO_DIR}/data/giving-shortlist.json")
echo "PASS dashboard: ${imaged} of ${total} cards illustrated; text-only: ${textonly:-none}"
# A subject with no public-domain federal photograph gets a typographic plate at
# the same size, so the card reads as a decision rather than a hole.
# A card with no photograph must not RESERVE photo-sized space. The plate
# inherited the banner's 8:3 ratio, so on a full-width tier card it became a
# ~600px empty box with one small label adrift in the middle of it.
if grep -q 'org__banner--none' "$OUT"; then
  echo "FAIL dashboard: the empty photo plate is back — text-only cards must not reserve photo space" >&2
  fail=1
else
  echo "PASS dashboard: text-only cards reserve no photo-sized space"
fi
want "text-only cards are still marked as deliberate" 'org--plain'
# Defensive: a full-width card must never scale a banner to an absurd height.
want "the banner is height-capped" 'max-height: 17rem'
if [ "$imaged" -ne "$total" ]; then
  echo "FAIL dashboard: ${total} cards but only ${imaged} illustrated — every card carries a photograph" >&2
  fail=1
fi
# Two photographs are subject-adjacent rather than literal. That is a finding
# the page states, not one it hides behind a caption.
want "the colophon declares which images are subject-adjacent" 'subject-adjacent rather than literal'
# Every image src must already be an inline data: URI — never a network fetch.
if jq -e '[.orgs[] | select(has("image")) | .image
     | select(has("src")) | select((.src | startswith("data:")) | not)] | length > 0' \
  "${REPO_DIR}/data/giving-shortlist.json" >/dev/null 2>&1; then
  echo "FAIL dashboard: an image src is not an inline data: URI" >&2
  fail=1
else
  echo "PASS dashboard: every image src is an inline data: URI"
fi
# Every illustrated card carries a complete, checkable credit.
missing_credit=$(jq -r '[.orgs[] | select(has("image"))
  | select((.image.alt // "") == "" or (.image.credit.title // "") == ""
        or (.image.credit.author // "") == "" or (.image.credit.agency // "") == ""
        or (.image.credit.source_url // "") == "" or (.image.credit.license // "") == ""
        or (.image.credit.license_url // "") == "")
  | .name] | join(", ")' "${REPO_DIR}/data/giving-shortlist.json")
if [ -n "$missing_credit" ]; then
  echo "FAIL dashboard: incomplete image credit for: ${missing_credit}" >&2
  fail=1
else
  echo "PASS dashboard: every illustrated card carries a complete credit"
fi
want "credits name the agency that made the work" '"agency"'
want "credits cite the federal-works statute" '17 U.S.C. 105'

want "an image supplies geometry, never markup" 'img.paths'
want "credits are rendered where a reader can check them" 'id="credits"'

# The provenance gate, exercised both ways against a throwaway shortlist.
GIVE_SRC="${REPO_DIR}/data/giving-shortlist.json"
GATE_DIR="${TMPROOT}/gate"
mkdir -p "$GATE_DIR"
# (a) a complete image builds, and its credit reaches the page
jq '.orgs[0].image = {viewBox:"0 0 48 48", paths:["M4 4h40v40H4z"], alt:"test mark",
      credit:{title:"Test Plate", author:"A Human", agency:"Test Agency",
              source_url:"https://example.org/plate",
              license:"Public domain (PD-old-100)", license_url:"https://example.org/pd"}}' \
  "$GIVE_SRC" >"${GATE_DIR}/ok.json"
# (b) the same image with its licence stripped must be refused
jq 'del(.orgs[0].image.credit.license)' "${GATE_DIR}/ok.json" >"${GATE_DIR}/bad.json"

gate_run() { # gate_run SHORTLIST OUTDIR
  cp "$GIVE_SRC" "${GATE_DIR}/backup.json"
  cp "$1" "$GIVE_SRC"
  CARBON_LEDGER_DASHBOARD_DIR="$2" \
    bash "${REPO_DIR}/scripts/generate-dashboard.sh" --no-open >/dev/null 2>&1
  local rc=$?
  cp "${GATE_DIR}/backup.json" "$GIVE_SRC"
  return $rc
}
if gate_run "${GATE_DIR}/ok.json" "${GATE_DIR}/out-ok"; then
  echo "PASS dashboard: a fully-attributed image builds"
  if grep -q 'Test Plate' "${GATE_DIR}/out-ok/carbon-2026-08-06T12-00-00Z.html"; then
    echo "PASS dashboard: its credit reaches the page"
  else
    echo "FAIL dashboard: an image shipped without its credit reaching the page" >&2
    fail=1
  fi
else
  echo "FAIL dashboard: a fully-attributed image was refused" >&2
  fail=1
fi
if gate_run "${GATE_DIR}/bad.json" "${GATE_DIR}/out-bad"; then
  echo "FAIL dashboard: an image with no licence recorded was allowed to build" >&2
  fail=1
else
  echo "PASS dashboard: an image missing its licence is refused at build time"
fi

# --- privacy: payer names come from the ledger, never from the template -------
# The templates ship in a public repository. A payer name baked into template
# prose is the maintainer's own business identity published to everyone who
# clones it, and it is wrong for every other user besides. The page still names
# payers — it reads them out of the DB at generation time.
for tpl in "${REPO_DIR}/templates/dashboard-head.html" "${REPO_DIR}/templates/dashboard-tail.html"; do
  if grep -qE 'Signalblur|Lies Above' "$tpl"; then
    echo "FAIL dashboard: a real payer name is hardcoded in $(basename "$tpl")" >&2
    fail=1
  fi
done
echo "PASS dashboard: no payer name hardcoded in the templates"
want "payers are derived from the ledger at generation time" 'id="payer-names"'

# --- receipts: findable even with nothing on file ----------------------------
# The section a user goes looking for when they want to file a receipt must
# announce itself when it is empty, not render as a blank space between two
# headings. Assert the standing scaffolding here; the empty-ledger run below
# asserts what actually appears when there is nothing to show.
want "receipts section is named for what a user is looking for" 'id="h-audit"'
want "receipt downloads are a labelled action, not bare text" 'class: "dl"'
want "receipts are summarised above the register" 'id="receipt-roll"'

# --- methodology -------------------------------------------------------------
want "methodology section" 'id="h-method"'
want "CIF identity stated" 'co2_g / 0.287'
want "water formula stated" '0.18/1.14'
want "embodied factor stated" '44.1'
want "removal-only balance rule restated" 'verified removal'

# --- water: a benchmark and a contribution, never a settlement ---------------
# The user asked for this line and asked that four things be said plainly about
# it. All four are asserted here, because the whole point of the line is that it
# does NOT claim what a carbon offset claims.
want "the water figures are computed for the reader" '"water_match":{'
want "the certificate count is worked out, not left as arithmetic" '"wrc":'
want "both ends of the single-issuer spread ride in" '"usd_low":'
want "the line is named a contribution, not a settlement" 'a contribution, not a settlement'
want "(a) it rests on an estimate this tool produced" 'estimate produced by this tool'
want "(b) it is not fungible with the water used" 'not fungible'
want "(c) it is not verified removal and settles nothing" 'settles nothing'
want "(d) what IS verified is measured restoration work, not advocacy" 'rather than an advocacy'
want "water is basin-local, and the page says so" 'basin-local'
want "the 2x price spread is disclosed rather than hidden" 'one issuer'
# The carbon dollar pair must stay pure. A water figure that leaked into it
# would silently redefine what "owed" means.
if grep -qE '"(overall_usd|owed_usd|contributed_usd)":[0-9.-]*[^,}]*water' "$OUT"; then
  echo "FAIL dashboard: a water figure leaked into the carbon dollar ledger" >&2
  fail=1
else
  echo "PASS dashboard: the water line stays out of the carbon dollar ledger"
fi

# --- energy: unpriced, and the reason is on the page -------------------------
want "energy explains why it carries no price" 'charge twice for one'
want "the CIF identity is the reason given" 'same measurement in two units'

# --- the derivation collapses, but never out of the printed record -----------
# "How these are made" is reference material, not part of the reading, so it
# folds away. It stays in THIS file rather than becoming a second page: the
# whole value of this artifact is that it is one self-contained thing you can
# archive, print or hand to an accountant, and a second file can drift out of
# sync with the ledger that generated it.
want "the derivation is a disclosure" 'id="meth-fold"'
want "the derivation summary names itself" 'Derived, not measured'
# A collapsed disclosure PRINTS collapsed, which would silently gut the archive.
# Per WHATWG HTML the open attribute is what decides: "If the attribute is
# absent, only the summary is to be shown... if the attribute is added, the
# information should be shown" — so the attribute is set before printing, and
# restored afterwards. CSS alone cannot do this.
want "every disclosure is opened before printing" 'beforeprint'
want "and restored after, so the screen is unchanged" 'afterprint'
want "printing is caught where beforeprint is not fired" 'matchMedia'

# --- per-metric calculation explainers ---------------------------------------
# Each metric hero carries its own disclosure explaining ITS maths: the formula,
# the constants with their values, and where each constant came from. A reader
# asking "where does 0.287 come from" should find the answer under the
# electricity card, not three screens away in a combined derivation block.
want "each metric hero carries a calculation disclosure" 'How this is calculated'
want "the disclosure is a native details element" 'class: "calc"'
want "constants ride in with their recorded sources" '"constant_sources"'
want "the grid-intensity source is quoted" 'arXiv:2505.09598'
# The same fact must not live in two diverging places: the per-metric physics
# moved OUT of the combined derivation block when it moved under the heroes.
dupes=$(grep -c 'Not a second model' "$OUT" || true)
if [ "$dupes" = "1" ]; then
  echo "PASS dashboard: the energy derivation is stated once, not duplicated"
else
  echo "FAIL dashboard: 'Not a second model' appears ${dupes} times — the derivation is duplicated" >&2
  fail=1
fi

# --- time granularity --------------------------------------------------------
# One pre-computed series per granularity, switched client-side. Nothing is
# fetched and no physics is recomputed in the browser.
want "the page carries a series per granularity" '"series":{'
want "daily buckets" '"day":{'
want "weekly buckets" '"week":{'
want "monthly buckets" '"month":{'
want "each series declares whether the data supports it" '"ok":'
# The fixture spans 2026-06 to 2026-07, so month has 2 buckets — under the
# 3-bucket floor — and year has 1. Both are correctly withheld, and day (50)
# and week (7) are offered. A granularity the data cannot carry is not shown.
want "a single-bucket year is withheld" '"year":{"rows":\[{"b":"2026"'
# Empty periods are ZEROS, not gaps: the fixture has no sessions in most days
# of that span, and those days must still be in the series.
want "empty periods ride in as zeros" '"co2_g":0,"energy_wh":0'
want "the page says empty periods are zeros" 'zero, not a gap'
# The control is a native radio group: the APG pattern's keyboard contract
# (Tab in and out, arrows move and check, Space checks) comes from the platform.
want "the control is a native radio group" 'type: "radio"'
want "grouped radios share a name" 'name: "gran"'
want "the printed record states which bucketing was captured" 'Bucketed by '
want "hourly is withheld with its reason" 'charge a long session entirely to the hour'

# --- the month view is drawn at DAILY resolution -----------------------------
# A month total hides what produced it: one long Tuesday and a quiet fortnight
# land in the same bin at the same height. So the month view plots one point per
# day and marks each month START with a rule and a label. These lock the three
# things that make that honest rather than merely denser.
want "the month view resolves to days" 'function monthDetail'
want "the trace and the figures table draw from different rows" 'function bucketRows'
want "month starts are found in the daily series" 'function monthStarts'
want "a month boundary gets its own heavier rule" 'grid--m'
want "the month rule is structure, not a reading" 'it is STRUCTURE rather than a reading'
want "daily detail has a stated ceiling" 'DAY_DETAIL_MAX'
want "the ceiling is printed, not silent" 'Daily detail inside each month is withheld past'
want "the page says the trace resolves days inside months" 'rules every month start'
want "the figures table still totals the months" 'The trace above resolves the same span to single days'
# The resolution swap must not become a second y-scale: one measure, one axis
# per lane, everywhere. Overlaying daily points on monthly totals would need two.
want "the swap is documented as a resolution change, not a dual scale" 'RESOLUTION SWAP, not a second scale'
# At daily spacing a dot per point fuses into a ribbon, so only the peak keeps
# one. The peak is the point a reader wants to put a date to.
want "dots thin out when the points pack too tightly" 'var showDots'
want "the peak keeps its dot at any density" 'i !== peak'
# An all-zero lane has no peak: indexOf returns -1, which used to index past the
# end of the points array and take the whole render down.
want "an all-zero lane cannot crash the render" 'if (peak < 0) peak = 0'
# 150 daily numbers read aloud in sequence is the table recited badly.
want "a dense trace summarises instead of reciting every point" 'function laneDesc'
want "the summary points at the table that has every row" 'every figure is in the table below'

# --- a ledger wide enough to exercise the month view -------------------------
# The main fixture spans two months, so month is under the 3-bucket floor and is
# correctly withheld — which means it never exercises the daily-detail path at
# all. This render spans five months of real days so the DATA the month view
# reads is checked for the conditions the view actually depends on, rather than
# only for the source that would use them.
WIDE_DB="${TMPROOT}/wide.db"
ensure_schema "$WIDE_DB"
sqlite3 "$WIDE_DB" "INSERT INTO sessions (session_id, project, model, input_tokens,
    output_tokens, cost_usd, co2_grams, energy_wh, water_ml, embodied_gco2e, started_at,
    ended_at, source, methodology_version, excluded) VALUES
  ('11111111-1111-4111-8111-111111111111','p1','claude-opus-5',1,1,1.0,100.0,348.4,1835.0,15.4,
   '2026-03-05T00:00:00Z','2026-03-05T01:00:00Z','backfill',2,0),
  ('22222222-2222-4222-8222-222222222222','p1','claude-opus-5',1,1,1.0,900.0,3135.9,16519.0,138.3,
   '2026-04-18T00:00:00Z','2026-04-18T01:00:00Z','backfill',2,0),
  ('33333333-3333-4333-8333-333333333333','p1','claude-sonnet-5',1,1,1.0,300.0,1045.3,5506.0,46.1,
   '2026-05-02T00:00:00Z','2026-05-02T01:00:00Z','backfill',2,0),
  ('44444444-4444-4444-8444-444444444444','p1','claude-sonnet-5',1,1,1.0,500.0,1742.2,9177.0,76.8,
   '2026-06-11T00:00:00Z','2026-06-11T01:00:00Z','backfill',2,0),
  ('55555555-5555-4555-8555-555555555555','p1','claude-haiku-4-5',1,1,1.0,200.0,696.9,3671.0,30.7,
   '2026-07-20T00:00:00Z','2026-07-20T01:00:00Z','backfill',2,0);"
WIDE_OUT="${CARBON_LEDGER_DASHBOARD_DIR}/wide/carbon-2026-08-06T12-00-00Z.html"
CARBON_LEDGER_DB="$WIDE_DB" \
  CARBON_LEDGER_DASHBOARD_DIR="${CARBON_LEDGER_DASHBOARD_DIR}/wide" \
  bash "${REPO_DIR}/scripts/generate-dashboard.sh" --no-open >/dev/null 2>&1
if [ ! -f "$WIDE_OUT" ]; then
  echo "FAIL dashboard: five-month render produced no file" >&2
  fail=1
else
  sed -n 's/^const DATA = \(.*\);$/\1/p' "$WIDE_OUT" >"${TMPROOT}/wide.json"
  # The month view needs BOTH of these true, so both are measured rather than
  # assumed: the month bucket has to be offered at all, and the daily series it
  # draws instead has to exist and sit under the stated ceiling.
  wide_q() { jq -r "$1" "${TMPROOT}/wide.json" 2>/dev/null; }
  if [ "$(wide_q '.series.month.ok')" = "true" ] && [ "$(wide_q '.series.month.n')" = "5" ]; then
    echo "PASS dashboard (five months): the month bucket is offered, with five buckets"
  else
    echo "FAIL dashboard (five months): month bucket not offered (ok=$(wide_q '.series.month.ok') n=$(wide_q '.series.month.n'))" >&2
    fail=1
  fi
  wide_days="$(wide_q '.series.day.n')"
  # 2026-03-05 to 2026-07-20 inclusive is 138 days, every one of them emitted —
  # the quiet ones as zeros, because a day with no sessions really did emit
  # nothing and dropping it would compress the axis.
  if [ "$wide_days" = "138" ]; then
    echo "PASS dashboard (five months): every day in the span rides in, quiet ones as zeros"
  else
    echo "FAIL dashboard (five months): expected 138 daily buckets, got ${wide_days}" >&2
    fail=1
  fi
  if [ -n "$wide_days" ] && [ "$wide_days" -ge 3 ] && [ "$wide_days" -le 1100 ]; then
    echo "PASS dashboard (five months): the daily series is inside the detail ceiling"
  else
    echo "FAIL dashboard (five months): daily series outside the detail ceiling (${wide_days})" >&2
    fail=1
  fi
  # Five months of days must still resolve to five month starts, which is what
  # the rules and the axis labels are drawn from.
  wide_starts="$(wide_q '[.series.day.rows[].b | .[0:7]] | unique | length')"
  if [ "$wide_starts" = "5" ]; then
    echo "PASS dashboard (five months): the daily series carries five month starts to rule"
  else
    echo "FAIL dashboard (five months): expected 5 month starts in the daily series, got ${wide_starts}" >&2
    fail=1
  fi
fi

# --- station-record idiom ----------------------------------------------------
# The page is a station record: three streams, each with the same trio of
# readings, then one shared time axis carrying all three traces. These lock that
# shape so a later content edit cannot quietly collapse it back into a bill or a
# generic admin console.
want "station header" 'class="bar"'
# The mark is a potted ficus, not a chart. A bar-chart glyph in the masthead
# competes with the real charts underneath it — a mark that looks like data
# reads as data — and the project is named after the plant.
want "the wordmark carries a ficus" 'class="brand__mark"'
want "the mark is drawn as leaves, not strokes on a baseline" 'A potted ficus'
if grep -q 'd="M4 4v16"' "$OUT"; then
  echo "FAIL dashboard: the bar-chart wordmark is back — the mark is a ficus" >&2
  fail=1
else
  echo "PASS dashboard: the bar-chart wordmark is gone"
fi
# It has to survive greyscale and forced colours, which it only does because the
# pot is the single dark mass under two mint tones. Assert the tonal split.
want "the mark uses both mint tones for depth" 'fill="var(--mint-soft)"'
want "the pot is the mark's one dark mass" 'fill="var(--ink-head)"'
want "streams block" 'id="h-streams"'
want "one card per stream, keyed to its lane" 'stream stream--'
want "carbon stream present" 'stream--carbon'
want "electricity stream present" 'stream--energy'
want "water stream present" 'stream--water'
# The trio is the system: the SAME three readings, in the same order, for every
# stream. Assert all three labels, and that the third is a real month-on-month
# comparison rather than a repeat of the lifetime figure.
want "trio badge 1: lifetime total" 'Lifetime total'
want "trio badge 2: familiar-scale equivalence" 'In familiar terms'
want "trio badge 3: latest month" 'Latest month'
want "trend badge compares against the prior month" '% vs '
# SIGNATURE: the trace. Three lanes on one monthly axis, drawn at load time by
# the embedded script, so it exists in the page as the source that builds it.
want "trace panel" 'id="h-trace"'
want "trace draws one lane per stream" 'function drawTrace'
# The trace is a smooth area chart now, not columns. Two things have to be true
# of the smoothing: it must be a real curve, and it must never invent a peak.
# A Catmull-Rom style spline through five monthly points can overshoot and draw
# a maximum that is not in the data — on a page whose whole claim is that it
# does not make numbers up, that is not a styling choice. Fritsch-Carlson
# monotone cubic limits every tangent so the interpolant stays inside the
# interval it spans, so the curve cannot rise above the highest month or fall
# below the lowest.
want "the curve is a monotone cubic, not a free spline" 'monotonePath'
want "the smoothing is named and justified in the source" 'Fritsch'
want "the curve is emitted as cubic beziers" '"C"'
want "each series has a gradient area fill" 'linearGradient'
want "the fill fades to transparent" 'stop-opacity'
want "the plot carries a faint gridline field" 'grid'
# One vertical hairline per month, running the full height of the stack so a
# single line ties the carbon, electricity and water readings for that month
# together and down to its date label. Drawn before the data so it stays under
# the curves and dots.
want "each month gets a vertical gridline" 'grid--v'
# The curve is interpolated; the dots are the data. Both are drawn, so a reader
# can see which is which.
want "every month is marked as an actual sample" 'dot'
# The model-family panel is legitimately a bar chart, so scope this to the
# trace: its per-lane column geometry is what must be gone.
if grep -q 'width: Math.round(bw)' "$OUT"; then
  echo "FAIL dashboard: the column trace is back — the trace is a smooth area chart" >&2
  fail=1
else
  echo "PASS dashboard: the trace is drawn as areas, not columns"
fi
want "trace lanes are labelled in words, not colour alone" 'class: "lane__n"'
want "the streams share one time axis" 'one shared axis'
want "trace states the lanes are congruent by construction" 'congruent by construction'
want "model breakdown kept its own panel" 'id="by-model"'
# The measure: settled span solid, unsettled span OPEN. Filled-versus-open is
# the channel that survives greyscale, CVD and forced colours, which is exactly
# what the 45-degree hatch it replaced did not do reliably at small sizes.
want "measure marks the settled boundary" 'class: "bound"'
want "measure reports the settled percentage" '% settled'
want "unsettled span is an open track, not a hatch" 'class: "m-open"'
want "open track is a stroke with no fill" '\.m-open { fill: none;'
if grep -q 'patternTransform\|repeating-linear-gradient' "$OUT"; then
  echo "FAIL dashboard: the hatch fill returned — unsettled is an open track" >&2
  fail=1
else
  echo "PASS dashboard: unsettled is drawn as an open track (no hatch pattern)"
fi
# An empty station and an unsettled one must never look the same.
want "no-data track is dashed, distinct from the open track" 'track-none'
# Ledger and console vocabulary must stay gone.
for dead in "Statement of account" "Detach for your records" 'class="sheet"' 'class="mast"' 'class="perf"' 'class="topbar"'; do
  if grep -qF "$dead" "$OUT"; then
    echo "FAIL dashboard: retired vocabulary returned: $dead" >&2
    fail=1
  fi
done
echo "PASS dashboard: ledger/bill/console vocabulary retired"

# --- giving briefing: tiered, and clear about what each org does -------------
want "giving briefing groups orgs by what a gift does" 'class: "tier"'
want "each org card states its carbon verdict under a heading" 'Carbon verdict'
want "each org card surfaces the supporting research" 'Supporting research'
want "the price signal is its own object, not a sentence" 'org__price'
# The ranking research is blunt about reefs; the copy must not launder it.
want "honest carbon verdict on reef restoration" 'Not a carbon investment'

# --- quality floor: the page's own accessibility scaffolding ------------------
want "reduced motion honoured" 'prefers-reduced-motion'
# --- findings from the WCAG 2.2 AA audit, locked so they cannot come back ----
# SC 2.4.11 Focus Not Obscured (Minimum) / F110. scroll-padding is the
# load-bearing half: scroll-margin only applies when the browser decides to
# scroll, and an element already in the scrollport but under a sticky overlay
# counts as visible, so nothing scrolls. Measured before: six elements behind the
# bar, five entirely. After: none, collapsed or expanded.
want "the scrollport is inset for the sticky header" 'scroll-padding-top: 5.5rem'
want "every tab stop reserves the header height, not just jump anchors" 'a\[href\], button, summary, input, label, \[tabindex\] { scroll-margin-top'
# SC 2.1.1 Keyboard, Level A. overflow-x:auto makes a region a mouse can scroll
# and a keyboard cannot. The table wrappers always had this; the formula boxes
# did not, and at 320px the widest is 605px against 251px of visible width.
want "the formula box is keyboard-scrollable" 'class: "calc__f", tabindex: "0"'
want "the methodology formula is keyboard-scrollable" 'class: "meth__f", tabindex: "0"'
want "the copyable command is keyboard-scrollable" 'class: "cmd", tabindex: "0"'
# SC 1.4.10 Reflow: one unstyled colophon link carrying a 32-character hex id
# pushed the whole page to 353px at a 320px viewport.
want "the colophon can break a long filename" '\.credits__list a { overflow-wrap: anywhere'
want "the colophon is styled at all" '\.credits__list {'
# SC 2.5.8 Target Size (Minimum): 0.35rem put two 15px links 23.7px apart,
# missing the 24px spacing circle by 0.3px.
want "evidence links clear the 24px spacing circle" 'gap: 0.5rem; }'
# The accessible name of a heading built from two elements needs a separator in
# the tree, not one on screen — and never display:none, which would remove it.
want "a clipped separator class exists" '\.vh {'
want "the separator is clipped, not hidden" 'clip-path: inset(50%)'
want "the org heading uses it" 'class: "vh" }, " · "'
# A printed disclosure with its summary hidden is content with its heading
# removed — on a page whose purpose is to be filed.
want "the print stylesheet keeps disclosure headings" 'details > summary {'
want "print stylesheet present" '@media print'
want "visible keyboard focus" ':focus-visible'
# FOUR chart slots, because the page draws four things: the three streams and
# the settled span. Every value is pinned at what the dataviz validator cleared
# on ALL PAIRS (worst CVD dE 8.3 protan, worst normal-vision dE 16.6, all four
# >= 3:1 on the white sheet and on the neutral plane).
want "chart palette: carbon slot pinned" '\--viz-carbon:  #4a44a8'
want "chart palette: electricity slot pinned" '\--viz-energy:  #a03d80'
want "chart palette: water slot pinned" '\--viz-water:   #1b83c4'
want "chart palette: settled slot pinned" '\--viz-settled: #0f9563'
# The model-family bars carry their own token. Foam green could not replace
# --viz-carbon: that token also draws the unsettled track on the measure, and a
# green "unsettled" beside the mint "settled" inverts the page's own argument.
want "chart palette: model-family slot pinned" '\--viz-model:   #127f74'
# No oranges or reds in the charts, and no quietly-reintroduced rainbow: the
# only chart tokens permitted are those four. Every one of them was searched
# inside the cool half of the wheel only, because emitting carbon is the normal
# state of doing the work and must never be dressed as an error.
if grep -oE '\--viz-[a-z0-9-]+:' "$OUT" | sort -u |
  grep -qvE '^--viz-(carbon|energy|water|settled|model):$'; then
  echo "FAIL dashboard: unexpected chart palette token(s):" >&2
  grep -oE '\--viz-[a-z0-9-]+:' "$OUT" | sort -u |
    grep -vE '^--viz-(carbon|energy|water|settled|model):$' >&2
  fail=1
else
  echo "PASS dashboard: exactly five chart colours (carbon, electricity, water, settled, model)"
fi
# The working mint is the one colour on this page under a WCAG obligation: it
# draws the meaning-bearing rules (the header rule, the section-head rules, the
# settled span, callout bars), which SC 1.4.11 Non-text Contrast requires to
# reach 3:1 against the adjacent colour. #0f9563 measures 3.82:1 on the #ffffff
# sheet and 3.61:1 on the #f7f9f8 plane. Pin it, so a later palette pass cannot
# lighten it back under the threshold unnoticed. (The plane was #f1f3f2, where
# the same mint measured 3.43:1 — lightening the field raised the ratio, so the
# obligation on the rules got easier rather than harder.)
want "meaning-bearing mint pinned at its measured value" '\--mint:      #0f9563'
want "decorative mint kept separate from the working mint" '\--mint-soft: #9cd8c2'
# One mode, and it is light. A record that changes colour with the reader's OS
# setting is one you cannot check against the copy you filed, so there is no
# dark variant and no theme toggle — and the page says so twice, in CSS and in a
# meta element, so the browser does not auto-darken its own furniture before the
# stylesheet has loaded.
want "page declares itself light in CSS" 'color-scheme: light'
want "page declares itself light before CSS loads" '<meta name="color-scheme" content="light">'
if grep -q 'prefers-color-scheme' "$OUT"; then
  echo "FAIL dashboard: dark mode reintroduced — the record renders light for everyone" >&2
  fail=1
else
  echo "PASS dashboard: no dark variant (single light palette for every reader)"
fi

# Mint is the ruling, not the paper. No surface on this page may be filled with
# it, and no chart colour may become a background either: chart marks are drawn
# as SVG, including the legend swatches, so every background on the page
# resolves to the white sheet or the neutral plane.
if grep -qE 'background(-color)?:[^;]*var\(--(mint|viz-)' "$OUT"; then
  echo "FAIL dashboard: mint or a chart colour used as a surface fill — both are marks, not fields" >&2
  grep -nE 'background(-color)?:[^;]*var\(--(mint|viz-)' "$OUT" | head -3 >&2
  fail=1
else
  echo "PASS dashboard: mint and the chart palette are marks only, never a surface fill"
fi
# --- the receipt picker ------------------------------------------------------
# The user wants to hand the page a file, not read a manual. The page is a
# static offline document and CANNOT write the ledger — and no local server is
# coming back, that attack surface was deleted deliberately. So the picker does
# the honest half: it takes the file locally, hashes it in the browser, and
# hands back the exact command that records it. Nothing leaves the machine.
want "a real file input, not just instructions" 'type: "file"'
want "the drop zone accepts a dragged file" 'dragover'
want "the receipt is hashed in the browser" 'SHA-256'
want "the hash uses the platform digest" 'crypto.subtle'
want "there is a stated fallback when digest is unavailable" 'digest_unavailable'
want "the generated command is copyable" 'Copy command'
want "the page is explicit that nothing is saved yet" 'Nothing is recorded until'
want "the manual steps collapse behind a disclosure" 'How this works'
# The browser deliberately hides the real path (WHATWG HTML: the value IDL
# attribute prefixes the filename with "C:\fakepath\" because legacy agents
# leaking the full path was a security vulnerability). The page must say so
# rather than emit a command with a wrong path in it.
want "the page explains why it cannot know the folder" 'does not reveal'
# ZERO NETWORK. Not a fetch, not an XHR, not a beacon, not a socket, not a
# worker. A receipt is a tax document; it never leaves the machine.
netfail=0
for api in 'fetch(' 'XMLHttpRequest' 'navigator.sendBeacon' 'new WebSocket' 'EventSource' \
  'new Worker' 'importScripts' 'navigator.geolocation'; do
  if grep -qF "$api" "$OUT"; then
    echo "FAIL dashboard: network/exfil-capable API present: $api" >&2
    netfail=1
    fail=1
  fi
done
[ "$netfail" = "0" ] && echo "PASS dashboard: no network or exfiltration-capable API anywhere in the page"

# --- the empty ledger: an empty screen is an invitation to act ---------------
# A fresh install has no offsets and no donations, which is exactly the state a
# user is in when they go looking for "where do I put my receipts". Rendering a
# blank space between two headings is how that user concludes the feature does
# not exist. Regenerate against a books-empty DB and assert the section tells
# them what will appear here and the exact command that puts it there.
EMPTY_DB="${TMPROOT}/empty.db"
CARBON_LEDGER_DB="$EMPTY_DB" ensure_schema "$EMPTY_DB"
sqlite3 "$EMPTY_DB" "INSERT INTO sessions (session_id, project, model, input_tokens,
    output_tokens, cost_usd, co2_grams, energy_wh, water_ml, embodied_gco2e, started_at,
    ended_at, source, methodology_version, excluded) VALUES
  ('dddddddd-dddd-4ddd-8ddd-dddddddddddd','p1','claude-opus-5',1,1,3.0,900.0,3136.0,16515.0,138.3,
   '2026-08-01T00:00:00Z','2026-08-01T01:00:00Z','backfill',2,0);"
EMPTY_OUT="${CARBON_LEDGER_DASHBOARD_DIR}/empty/carbon-2026-08-06T12-00-00Z.html"
CARBON_LEDGER_DB="$EMPTY_DB" \
  CARBON_LEDGER_DASHBOARD_DIR="${CARBON_LEDGER_DASHBOARD_DIR}/empty" \
  bash "${REPO_DIR}/scripts/generate-dashboard.sh" --no-open >/dev/null 2>&1
[ -f "$EMPTY_OUT" ] || {
  echo "FAIL dashboard: empty-ledger render produced no file" >&2
  fail=1
}
ewant() { # ewant DESCRIPTION PATTERN — assert against the empty-ledger render
  # -e, so a pattern that begins with a dash is a pattern and not an option.
  if grep -q -e "$2" "$EMPTY_OUT"; then
    echo "PASS dashboard (empty ledger): $1"
  else
    echo "FAIL dashboard (empty ledger): $1 (missing: $2)" >&2
    fail=1
  fi
}
ewant "the empty books announce themselves" 'class: "start"'
ewant "names what will appear here once a purchase is filed" 'this section will show'
ewant "names the retirement ID that will appear here" 'registry retirement ID'
ewant "gives the skill that records a purchase" '/carbon-offset'
ewant "gives the exact recording command" 'offset-record.sh'
ewant "gives the purchase flags" '--kg 25 --usd'
ewant "gives the receipt flag by name" '--receipt'
ewant "says why a static page cannot take an upload" 'cannot accept an upload'
ewant "gives the donation command too" 'donation-record.sh'
# The page is built by script, so grepping the source cannot tell a rendered
# register from the code that would render one. Assert the thing that IS
# state-specific — the embedded DATA — so the assertions above are known to be
# about the empty state and not about a register that happened to have rows.
ewant "the render really had empty books" '"offsets":\[\]'
ewant "and no donations either" '"donations":\[\]'

want "single main landmark" '<main'
want "skip link to the record" 'class="skip"'

exit "$fail"
