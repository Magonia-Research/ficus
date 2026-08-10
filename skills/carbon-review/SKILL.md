---
name: carbon-review
description: Styled in-context review of lifetime Claude usage — every metric explained, with cited familiar-scale comparisons (home-days of electricity, showers, miles driven). Use when the user asks what their usage means, for a usage overview/review/summary, or to put the footprint numbers in perspective.
---

Run this command and present its output verbatim — it is already markdown,
so rendering it IS the styling. Do not paraphrase the numbers, recompute any
equivalence, or drop the explainer or caveat lines.

```bash
bash "${CARBON_LEDGER_DIR:-$HOME/Documents/Research/carbon-tracker/carbon-ledger}/scripts/carbon-review.sh"
```

Notes for the agent:

- Every figure and every "≈ familiar scale" comparison is computed by the
  script from data/equivalence-constants.json (published EIA/EPA figures with
  citations). Never substitute your own equivalences or arithmetic — a
  plausible-sounding comparison from memory is exactly what this skill exists
  to prevent.
- If the output says the equivalence constants are unavailable, relay that
  line as-is; do not fill the gap.
- Follow-up questions about a specific metric can be answered from the
  report's "What these numbers mean" section. Anything deeper (methodology,
  sources) lives in data/factors.json and MAINTENANCE.md.
- Plain totals without the explainer → /carbon. Recording purchases or
  donations → /carbon-offset.
