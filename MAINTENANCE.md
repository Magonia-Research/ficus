# carbon-ledger maintenance

## Upstream review & cherry-pick procedure (manual, always)

There is no update checker by design. On an upstream release:

1. `git fetch upstream` (the remote is fetch-only; push is disabled).
2. `git log 43fb883ac1989d962c8699afb0be37fbe69c4476..upstream/main --oneline`
   and read every commit.
   Most likely to matter: transcript-format changes, new model factors/prices.
3. Diff-review each candidate commit in full (`git show <sha>`), with the
   2026-08-06 audit findings in mind: anything touching network, credentials,
   installers, updaters, or skills is rejected or stripped.
4. Cherry-pick reviewed commits only: `git cherry-pick -x <sha>`.
5. Run the whole suite: `bash tests/run-tests.sh`. A factor change must update
   `tests/methodology-vectors.json` expectations in the same commit and pass
   the cross-check gate; parser changes must keep reconciliation green.
6. Move the audit baseline only after a full re-review: retag
   `upstream-<newsha>` and update the tag name in `tests/run-lint.sh`,
   `tests/run-reconciliation.sh`, and this file.

## Consolidation tier policy (what may drift from upstream)

| Tier | Files | Policy |
| --- | --- | --- |
| Consolidated | `scripts/lib/*.sh` (schema, model-family, factors-env, segment-cache) | Fork-owned. Upstream schema/factor changes are re-expressed here, never cherry-picked directly. |
| Upstream-close | `aggregate_jsonl` jq programs in `backfill.sh` and `persist-session.sh` | Kept byte-close to upstream ON PURPOSE — they are the most likely cherry-pick recipients (transcript-format changes). Do NOT consolidate or reformat them. |
| Fork-only | offsets, physics, dashboard, statusline snippet, skills, tests beyond `run-vectors` | No upstream counterpart; normal development. |

`recompute.sh`'s SQL LIKE clauses mirror `lib/model-family.sh` and are annotated
in place — keep both in sync when adding a model family (vector
`family-precedence-fable-over-opus` locks the precedence).

## Published pages

Two files under `docs/`, both generated and neither hand-edited:

| Page | Built by | What it is |
| --- | --- | --- |
| `docs/index.html` | `scripts/build-docs.sh` | The landing page: install, provenance, the maths, the giving research. Rendered from `templates/docs-index.html` plus `data/factors.json`, `data/offset-constants.json` and `data/giving-shortlist.json`. |
| `docs/dashboard.html` | `scripts/build-demo.sh` | The example dashboard, from fabricated sessions. |
| `docs/dashboard.png` | headless render of `docs/dashboard.html` | The README screenshot. |

Rebuild both after any change to a constant, to the giving shortlist or to the
dashboard templates, and `tests/run-docs-tests.sh` will fail if the published
page and `data/` have drifted apart.

## Per-day attribution

`sessions` holds one row per session; `session_days` holds one row per (session,
day it actually spent tokens), written by the Stop hook from the timestamp each
transcript message already carries. It is a **grouping of measurements, never an
apportionment** — the per-day rows sum to exactly the session row, and
`run-day-split-tests.sh` asserts that tie-out on tokens and on carbon. Anything
that breaks it means something started being modelled.

Why it exists: measured on a 1,470-session ledger, 80 sessions crossed midnight
(5%) but carried **88.7% of the carbon**. Charging a session to its start day is
not a rounding error once the chart draws days.

Rules for anything that reads time series:

- Build on the `DAY_ROWS_CTE` in `generate-dashboard.sh`, which prefers
  `session_days` and falls back to `date(started_at)` for sessions with no
  split. Both paths are needed — a pruned transcript can never be split.
- Count a split session **once, on its earliest split day**. Not on
  `date(started_at)`: the hook stamps that when it first sees a session, so a
  resumed or re-read session matches none of its own days.
- `aggregate_jsonl` stays byte-close to upstream. The day split is a separate
  function in `lib/day-split.sh` for exactly that reason.

## Cache invalidation (the $160/$227 lesson)

`~/.claude/carbon-ledger/factors.env` is a CACHE of `data/factors.json` and
`data/offset-constants.json`, because the statusline render path may not run
`jq`. When the removal price changed, every path that read the JSON directly
picked it up and the statusline did not — the two figures on screen disagreed by
thirty percent, with nothing failing. `lib/factors-env.sh` now carries
`refresh_factors_env_if_stale`, called from the Stop hook, which compares mtimes
numerically (never `-nt`, which is false for equal timestamps at one-second
granularity). **Any new consumer of a `data/` constant must either read the file
directly or go through that cache — never keep a third copy.**

## Constants provenance

Every numeric constant lives in a data file with a `_source` and date; scripts
never hardcode one. The validation guard in `recompute.sh` (and the emit guard
in `lib/factors-env.sh`) must list every constant interpolated into SQL or
sourced shell — add new constants to those guards in the same commit.

| Constant | Value | File | Source |
| --- | --- | --- | --- |
| co2 factors (fable/opus/sonnet/haiku) | 156/3304 · 78/1652 · 39/826 · 20/413 gCO2e/Mtok | `data/factors.json` `.models` | Jegham et al. 2025 (arXiv:2505.09598); fable = 2x opus extrapolation |
| cache_read_factor | 0.08 | `data/factors.json` | engineering estimate, METHODOLOGY.md |
| grid CIF | 0.287 g/Wh | `.physics` | Jegham et al. (AWS location-based) — the CIF identity anchor |
| PUE | 1.14 | `.physics` | AWS fleet, Jegham et al. |
| WUE on-site / off-site | 0.18 / 5.11 L/kWh | `.physics` | AWS 2023 / WRI via Li et al., METHODOLOGY.md:42-47 |
| embodied intensity | 44.1 gCO2e/kWh | `.physics` | 8xH100 server LCA (BoaviztAPI + Lees-Perasso), 3-yr life at TDP — derivation in the file |
| EcoLogits α/β/γ/B | 1.17e-6 / −0.0112 / 4.05e-5 / 64 | `.ecologits` | ecologits.ai methodology (fetched 2026-08-06), cross-check ONLY |
| Claude parameter estimates | fable 800B, opus 400B, sonnet 200B, haiku 50B (+tps) | `.ecologits.models` | undisclosed by Anthropic; labeled estimates, cross-check ONLY |
| offset prices | $227/t removal, $15/t prevention, $4.00/kgal water | `data/offset-constants.json` | workspace `research/offset-methodology-proposal-2026-08.md` (retail price, fetched 2026-08-08; FX-sensitive, refresh quarterly) |
| prices | per `data/prices.json` | `data/prices.json` | Anthropic list prices |

## Live wiring (done 2026-08-06, Phase 9)

- State: `~/.claude/carbon-ledger/` (DB, factors.env, segment-cache,
  receipts/, exports/, dashboard/)
- Hooks in `~/.claude/settings.json`: Stop → `scripts/persist-session.sh`,
  SessionStart → `scripts/safety-rescan.sh` (backup:
  `settings.json.bak-carbon-ledger-2026-08-06`)
- Statusline: segment merged into `~/.claude/statusline.sh` (backup:
  `statusline.sh.bak-carbon-ledger-2026-08-06`); render path is
  source factors.env + one awk + cat segment-cache
- Skills: `~/.claude/commands/carbon.md` and `carbon-offset.md` symlink to
  `skills/*/SKILL.md`
- Real-history reconciliation vs upstream: `docs/real-data-reconciliation.md`
  (1468/1470 token-exact; 2 in-flight sessions differed by capture time only)

## Test suite

`bash tests/run-tests.sh` auto-discovers every `tests/run-*.sh`:
vectors (13, incl. physics + precedence), reconciliation (vs upstream tag),
physics-db (3 write paths), offsets (33 assertions), cross-check (+ mutation),
statusline bench (p95 < 50 ms), dashboard (determinism + zero external refs),
hygiene (no network call sites, no legacy naming), lint (shellcheck all,
shfmt on fork-added files; containerized when not installed locally).
No commit hook and no prek config: `tests/run-tests.sh` is the only entry point,
so there is no second, quieter subset of it to drift out of step.
