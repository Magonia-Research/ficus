---
name: carbon-offset
description: Record a carbon-offset purchase (receipt-backed, tax-grade), update a record with a registry retirement id, or export a tax-year CSV
---

Map the user's request onto exactly one of these commands, run it, and present
the output verbatim. `LEDGER` below means
`${CARBON_LEDGER_DIR:-$HOME/Documents/Research/carbon-tracker/carbon-ledger}`.

**Record a purchase** (receipt file is REQUIRED — ask for its path if missing):

```bash
bash "$LEDGER/scripts/offset-record.sh" \
  --kg <kg_co2e> --usd <amount> --vendor <name> \
  --pathway <biochar|refrigerant-destruction|methane|dac|other> \
  --category <removal|prevention> --payer "<entity>" \
  --receipt <path> [--date YYYY-MM-DD] [--retirement-id <id>] [--notes "<text>"]
```

**Record a charitable donation** (giving-shortlist orgs). The statusline cost
pair is a pure dollar ledger: every dollar recorded here or via offset-record
subtracts 1:1 from the owed side, and owed goes negative once contributions
pass carbon-neutral. The tonnes balance still settles only with verified
removal:

```bash
bash "$LEDGER/scripts/donation-record.sh" \
  --usd <amount> --org "<name>" --payer "<entity>" \
  [--date YYYY-MM-DD] [--notes "<text>"] [--receipt <path>]
```

**Add the registry retirement id when the confirmation arrives:**

```bash
bash "$LEDGER/scripts/offset-record.sh" --update <id> --retirement-id <registry-id>
```

**Export a tax year (CSV per payer, accountant-ready):**

```bash
bash "$LEDGER/scripts/offset-export.sh" --tax-year <YYYY> [--payer "<entity>"]
```

**Extract a stored receipt from the DB** (recording also stores the receipt
bytes in the `receipt_blobs` table, so the DB alone is a complete record; the
dashboard offers the same bytes as download links):

```bash
sqlite3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/carbon-ledger/carbon.db" \
  "SELECT writefile('<output-path>', content) FROM receipt_blobs WHERE offset_id=<id>;"
```

**Search receipt text** — recording best-effort parses the PDF's text into
`receipt_blobs.extracted_text` (NULL for scanned/image-only receipts):

```bash
sqlite3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/carbon-ledger/carbon.db" \
  "SELECT offset_id, filename FROM receipt_blobs WHERE extracted_text LIKE '%<term>%';"
```

Rules for the agent:

- Never invent flag values. If kg, USD, vendor, payer, or the receipt path is
  not in the conversation, ask the user.
- category is `removal` only for durable removal (e.g. Puro-audited biochar
  CORCs). Refrigerant/methane destruction is `prevention`. When unsure, ask —
  do not guess `removal`.
- `--no-receipt` exists but stores the row UNVERIFIED; only use it when the
  user explicitly says they have no receipt, and repeat the script's warning.
- Never delete or edit receipt files; the script only ever copies them.
