---
name: carbon
description: Report the energy, water, and CO2e footprint of Claude Code usage, with offset balance and cost-to-clear
---

Run this command and present its output to the user verbatim. Do not paraphrase,
reformat, or omit the caveat line.

```bash
bash "${CARBON_LEDGER_DIR:-$HOME/Documents/Research/carbon-tracker/carbon-ledger}/scripts/carbon-report.sh"
```

If the user asks for the dashboard (e.g. "/carbon --dashboard" or "show me the
dashboard"), pass `--dashboard` instead: it generates a self-contained HTML
file under `~/.claude/carbon-ledger/dashboard/` and opens it locally (file://,
zero network).

Notes for the agent:

- The headline UNOFFSET BALANCE counts verified removal only. Prevention and
  unverified rows are separate lines by design — never add them together.
- If the user asks to purchase offsets, show the links the report prints and let
  the user click them; never fetch them yourself and never automate a payment.
- If the user wants to record a purchase they made, use the /carbon-offset skill.
