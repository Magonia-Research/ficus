# Real-history reconciliation vs upstream 43fb883

**Date:** 2026-08-06 (Phase 9 live wiring)
**Method:** fork `scripts/backfill.sh` backfilled the live `~/.claude/projects`
transcripts into `~/.claude/carbon-ledger/carbon.db`; a detached worktree of tag
`upstream-43fb883` then backfilled the same transcripts into a scratch DB
(`CLAUDE_CARBON_DB` override, live config dir read-only). Row-level SQL join on
`session_id` compared all four token columns exactly and co2/cost within 1e-6.

## Result

| Check | Count |
| --- | --- |
| Upstream rows | 1470 |
| Fork rows | 1470 |
| Common session_ids | 1470 (no asymmetry either way) |
| Token-exact matches | **1468 / 1470** |
| Token mismatches | 2 |

The 2 mismatching sessions were **actively running Claude Code sessions**
(one of them the session performing this wiring). The upstream backfill ran
~10 minutes after the fork's; both mismatches show strictly larger upstream
token counts and a later upstream `ended_at`, i.e. the transcript grew between
the two snapshots. This is capture-time skew on in-flight sessions, not parser
divergence.

Parser equality on identical inputs is separately locked by
`tests/run-reconciliation.sh` (fixture transcripts, exact equality, runs in
every suite).

**Verdict: reconciled.** Every session whose transcript was static between the
two runs is token-identical, with co2/cost equal within 1e-6.
