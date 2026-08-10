#!/usr/bin/env bash
# build-demo.sh — rebuild docs/dashboard.html, the GitHub Pages demo dashboard.
#
# It lives at dashboard.html rather than at the site root because the root is
# now the landing page (scripts/build-docs.sh): someone arriving at the project
# needs to read what the numbers mean before being handed a statement of them.
#
# Everything here is fabricated: made-up sessions, made-up projects, made-up
# purchases, a generated one-page receipt. No real ledger is read and no real
# state directory is touched — the demo DB lives in a throwaway temp dir that is
# removed on exit.
#
# Deterministic by construction: fixed rows, a pinned CARBON_LEDGER_DASHBOARD_TS,
# and receipt paths normalized away from the temp dir, so re-running after a
# dashboard change produces a diff that is only the dashboard change.
#
#   bash scripts/build-demo.sh

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

DEMO_TS="2026-08-07T09:00:00Z"
OUT="${REPO_DIR}/docs/dashboard.html"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/carbon-ledger-demo.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
cleanup() {
  case "$TMPROOT" in
  */carbon-ledger-demo.*) rm -rf "$TMPROOT" ;;
  *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

STATE="${TMPROOT}/state"
mkdir -p "$STATE"
DB="${STATE}/carbon.db"
export CARBON_LEDGER_DB="$DB"

# shellcheck source=lib/schema.sh
source "${SCRIPT_DIR}/lib/schema.sh"
ensure_schema "$DB"

# --- fake sessions -----------------------------------------------------------
# Eleven counted sessions across five months (41.6 kg CO2e) plus one local-model
# session that must be excluded from every aggregate.
sqlite3 "$DB" "INSERT INTO sessions (session_id, project, model, input_tokens,
    output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, co2_grams,
    started_at, ended_at, source, methodology_version, excluded) VALUES
  ('10000000-0000-4000-8000-000000000001','demo-api','claude-sonnet-5',
   42000,61000,910000,38000,2.40,1850.0,'2026-04-03T09:12:00Z','2026-04-03T10:41:00Z','live',2,0),
  ('10000000-0000-4000-8000-000000000002','blog','claude-haiku-5',
   18000,22000,240000,9000,0.35,320.0,'2026-04-17T14:03:00Z','2026-04-17T14:38:00Z','live',2,0),
  ('10000000-0000-4000-8000-000000000003','demo-api','claude-opus-5',
   96000,148000,2100000,74000,9.10,6400.0,'2026-05-02T08:40:00Z','2026-05-02T12:05:00Z','live',2,0),
  ('10000000-0000-4000-8000-000000000004','experiments','claude-sonnet-5',
   61000,89000,1350000,52000,3.60,2700.0,'2026-05-19T16:20:00Z','2026-05-19T18:02:00Z','live',2,0),
  ('10000000-0000-4000-8000-000000000005','blog','claude-sonnet-5',
   27000,37000,540000,21000,1.45,1120.0,'2026-05-28T11:07:00Z','2026-05-28T11:59:00Z','live',2,0),
  ('10000000-0000-4000-8000-000000000006','demo-api','claude-fable-5',
   118000,171000,3400000,96000,21.30,9800.0,'2026-06-08T07:55:00Z','2026-06-08T13:30:00Z','live',2,0),
  ('10000000-0000-4000-8000-000000000007','experiments','claude-opus-5',
   72000,101000,1480000,55000,6.20,4350.0,'2026-06-21T13:11:00Z','2026-06-21T15:47:00Z','live',2,0),
  ('10000000-0000-4000-8000-000000000008','demo-api','claude-sonnet-5',
   70000,104000,1610000,60000,4.05,3180.0,'2026-07-04T10:25:00Z','2026-07-04T12:44:00Z','live',2,0),
  ('10000000-0000-4000-8000-000000000009','blog','claude-haiku-5',
   24000,33000,360000,13000,0.50,480.0,'2026-07-16T19:02:00Z','2026-07-16T19:51:00Z','live',2,0),
  ('10000000-0000-4000-8000-00000000000a','experiments','claude-fable-5',
   103000,139000,2750000,81000,17.40,7900.0,'2026-07-29T09:30:00Z','2026-07-29T14:12:00Z','live',2,0),
  ('10000000-0000-4000-8000-00000000000b','demo-api','claude-opus-5',
   58000,81000,1190000,44000,5.00,3500.0,'2026-08-05T08:05:00Z','2026-08-05T10:20:00Z','live',2,0),
  ('10000000-0000-4000-8000-00000000000c','experiments','local-llama',
   31000,44000,0,0,0,0,'2026-08-06T20:15:00Z','2026-08-06T21:00:00Z','live',2,1);"

# Derive the physics columns exactly the way recompute.sh does, from the cited
# constants in data/factors.json — never a second energy model.
FACTORS="${REPO_DIR}/data/factors.json"
CIF="$(jq -r '.physics.grid_cif_g_per_wh.value' "$FACTORS")"
PUE="$(jq -r '.physics.pue.value' "$FACTORS")"
WUE_ON="$(jq -r '.physics.wue_onsite_l_per_kwh.value' "$FACTORS")"
WUE_OFF="$(jq -r '.physics.wue_offsite_l_per_kwh.value' "$FACTORS")"
EMB="$(jq -r '.physics.embodied_gco2e_per_kwh.value' "$FACTORS")"
for v in "$CIF" "$PUE" "$WUE_ON" "$WUE_OFF" "$EMB"; do
  case "$v" in
  '' | *[!0-9.]*) echo "build-demo: non-numeric physics constant ('${v}')" >&2 && exit 1 ;;
  esac
done
sqlite3 "$DB" "UPDATE sessions SET
    energy_wh = co2_grams / ${CIF},
    water_ml = (co2_grams / ${CIF}) * (${WUE_ON}/${PUE} + ${WUE_OFF}),
    embodied_gco2e = (co2_grams / ${CIF}) * ${EMB} / 1000.0
  WHERE co2_grams IS NOT NULL;"

# --- fake receipt ------------------------------------------------------------
# A minimal uncompressed PDF, so the receipt-text extraction path runs and the
# download button in the demo hands back a file that actually opens.
RECEIPT="${TMPROOT}/demo-biochar-receipt.pdf"
{
  printf '%%PDF-1.4\n'
  printf '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
  printf '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n'
  printf '3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >> endobj\n'
  printf '4 0 obj << /Length 96 >> stream\n'
  printf 'BT /F1 12 Tf 72 720 Td (DEMO RECEIPT - not a real purchase - 25 kg biochar CORC) Tj ET\n'
  printf 'endstream endobj\n'
  printf 'trailer << /Root 1 0 R >>\n'
  printf '%%%%EOF\n'
} >"$RECEIPT"

# --- fake purchases and donation --------------------------------------------
RECORD="${SCRIPT_DIR}/offset-record.sh"
DONATE="${SCRIPT_DIR}/donation-record.sh"

bash "$RECORD" --kg 25 --usd 4.00 --vendor remove-carbon-today --pathway biochar \
  --category removal --payer "Acme Research LLC" --receipt "$RECEIPT" \
  --date 2026-06-30 --notes "demo data" >/dev/null
bash "$RECORD" --update 1 --retirement-id "PURO-2026-DEMO-0001" >/dev/null

bash "$RECORD" --kg 200 --usd 3.00 --vendor tradewater --pathway refrigerant-destruction \
  --category prevention --payer "Example Media Co" --receipt "$RECEIPT" \
  --date 2026-07-22 --notes "demo data" >/dev/null

bash "$DONATE" --usd 25.00 --org "American Rivers" --payer "Acme Research LLC" \
  --date 2026-08-01 --notes "demo data" >/dev/null

# The recorded receipt paths point into the throwaway temp dir. Rewrite them to
# the path a real install would show, so the published page carries no build
# machine's directories and the output stays byte-stable across rebuilds.
sqlite3 "$DB" "UPDATE offsets SET receipt_path =
    '~/.claude/carbon-ledger/receipts/2026/' ||
    purchase_date || '-' || vendor || '-' || id || '.pdf';"

# --- render ------------------------------------------------------------------
export CARBON_LEDGER_DASHBOARD_DIR="${TMPROOT}/dash"
export CARBON_LEDGER_DASHBOARD_TS="$DEMO_TS"
bash "${SCRIPT_DIR}/generate-dashboard.sh" --no-open >/dev/null

BUILT="${CARBON_LEDGER_DASHBOARD_DIR}/carbon-$(printf '%s' "$DEMO_TS" | tr ':' '-').html"
[ -f "$BUILT" ] || {
  echo "build-demo: generate-dashboard.sh produced no file at ${BUILT}" >&2
  exit 1
}

# Same offline invariant tests/run-dashboard-tests.sh enforces: nothing the
# browser would LOAD over the network may appear in a page we publish. Keep the
# three exceptions identical to that test's — click-only anchor hrefs, the
# equivalence citation URLs, and the giving shortlist's link values. All three
# only ever reach the page through setAttribute("href").
STRIP='s/href="https:\/\/[^"]*"//g; s/"[a-z_]*url":"https:\/\/[^"]*"//g'
# Captured rather than piped into `grep -q`: under `set -o pipefail` a matching
# `grep -q` closes the pipe, sed dies of SIGPIPE, and the pipeline reports
# failure — so the `if` went FALSE precisely when a violation existed and this
# guard could never fire. Found while auditing the sibling guard in build-docs.sh.
OFFLINE_HITS="$(sed "$STRIP" "$BUILT" |
  grep -nE 'https?://|<link|src="http|src='"'"'http|@import|url\(http' || true)"
if [ -n "$OFFLINE_HITS" ]; then
  echo "build-demo: refusing to publish — external loaded references found" >&2
  printf '%s\n' "$OFFLINE_HITS" | head -5 >&2
  exit 1
fi

mkdir -p "${REPO_DIR}/docs"
cp "$BUILT" "$OUT"
echo "Demo dashboard written: ${OUT}"
