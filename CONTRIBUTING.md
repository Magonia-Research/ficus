# Contributing to Ficus

Plain bash, jq, awk and sqlite3. No build step, nothing to install. It is also a
fork with a pinned upstream, which constrains how some files may be edited, so
read the fork rules before touching `scripts/`.

## Layout

| Path                    | What it is                                                          |
| ----------------------- | ------------------------------------------------------------------- |
| `hooks/hooks.json`      | Stop + SessionStart hook declarations                               |
| `scripts/`              | Session capture, backfill, recompute, offsets, export, dashboard    |
| `scripts/lib/`          | Shared schema DDL, model-family mapping, factors.env, segment cache |
| `skills/`               | The `/carbon`, `/carbon-offset` and `/carbon-review` commands       |
| `data/*.json`           | Every numeric constant, each with a `_source` and a date            |
| `templates/`            | Dashboard head/tail (inline CSS + vanilla JS, no external refs)     |
| `tests/`                | One `run-*.sh` per concern; `run-tests.sh` discovers them all       |
| `statusline-snippet.sh` | Reference statusline segment (what the benchmark measures)          |
| `METHODOLOGY.md`        | How every number is derived                                         |
| `MAINTENANCE.md`        | Upstream cherry-pick procedure and the consolidation tiers          |

## Tests

```bash
bash tests/run-tests.sh           # all twelve suites
bash tests/run-offset-tests.sh    # or one concern at a time
```

`run-tests.sh` globs `tests/run-*.sh`, so a new suite is picked up with no edit
to the runner. The twelve:

| Suite | What it holds |
| --- | --- |
| `run-vectors.sh` | Golden methodology vectors, including physics and model-family precedence |
| `run-reconciliation.sh` | Parser output against the pinned `upstream-43fb883` tag |
| `run-physics-db.sh` | The three write paths that populate the derived columns |
| `run-offset-tests.sh` | The offsets and donations ledger, receipts, export |
| `run-crosscheck.sh` | EcoLogits cross-check, plus a mutation test proving the gate bites |
| `run-review-tests.sh` | The `/carbon-review` output |
| `run-statusline-bench.sh` | Render-path latency, p95 under 50 ms |
| `run-dashboard-tests.sh` | Determinism and offline safety |
| `run-hygiene.sh` | Zero network call sites, no legacy naming |
| `run-lint.sh` | shellcheck and shfmt |
| `run-day-split-tests.sh` | Per-day attribution ties out to the session row, and the calendar the day ruler is drawn from (leap February included) |
| `run-docs-tests.sh` | The published landing page: determinism, offline safety, and that it still agrees with `data/` |

Every suite runs in its own sandbox: `CARBON_LEDGER_DB` points at a temp file
and the scripts derive receipts, exports, dashboards and the segment cache from
that path, so a real `~/.claude/carbon-ledger/` is never read or written. New
tests do the same. `mktemp -d`, export `CARBON_LEDGER_DB`, clean up with a
path-guarded `trap`. Nothing in the suite may touch the network.

## Red first

Write the failing assertion before the code that satisfies it, and watch it fail
for the reason you expect. A test that has never been red has not been shown to
test anything. When you change behaviour an existing test covers, change the
test in the same commit and say why in the message.

## Two gates that do not get weakened

`run-hygiene.sh` allows zero network call sites in `scripts/`, `hooks/` and
`skills/`. That invariant is the point of the fork.

`run-dashboard-tests.sh` requires two things of the generated page. It must be
byte-identical across two runs from the same fixture database under a pinned
`CARBON_LEDGER_DASHBOARD_TS`, and it must contain nothing a browser would load.
Three narrow exceptions exist and all three are click-only: `href="https://..."`
anchors, and the `cite_url` and `url` values inside the DATA object, which the
renderer only ever hands to `setAttribute("href")`. Never a `src`, a stylesheet,
an import or an SVG reference. The page has to render fully with Wi-Fi off,
which is also why typography comes from a system-font stack and never a webfont.

## Changing a factor or a price

An edit to `data/factors.json`, `data/prices.json` or
`data/offset-constants.json` ships in the same commit as:

1. Updated expectations in `tests/methodology-vectors.json`.
2. A `_source` naming where the number came from and when it was recorded. No
   script may hardcode a constant.
3. An update to `METHODOLOGY.md` explaining the derivation. "It looks right" is
   not a derivation.
4. A green `scripts/check-crosscheck.sh`, which blocks a factor change that
   diverges more than 3x either way from the EcoLogits model.

New constants also go into the validation guard in `recompute.sh` and the emit
guard in `scripts/lib/factors-env.sh`, in that same commit.

## Fork rules

The upstream remote is fetch-only. Files that exist in the `upstream-43fb883`
tag stay **byte-close to upstream** so cherry-picks apply cleanly. Do not
reformat them, do not reindent them, do not clean them up in passing. The
`aggregate_jsonl` jq programs in `backfill.sh` and `persist-session.sh` are the
strictest case: they are the most likely recipients of an upstream
transcript-format fix, so leave them alone unless the change is the point of the
commit.

Fork-added files are normal code and are the only ones `shfmt` formats.
`MAINTENANCE.md` has the tier table and the cherry-pick procedure.

## Lint

`tests/run-lint.sh` runs shellcheck over every `*.sh` and shfmt over fork-added
files only. It uses local binaries when present and otherwise runs pinned images
through the Apple `container` CLI. `--platform linux/arm64` is not optional; the
CLI mis-detects the platform when left to negotiate.

```bash
container run --rm --platform linux/arm64 \
  --mount "type=bind,source=$PWD,target=/repo" \
  koalaman/shellcheck:stable --severity=warning /repo/scripts/your-file.sh

container run --rm --platform linux/arm64 \
  --mount "type=bind,source=$PWD,target=/repo" \
  mvdan/shfmt:latest -d -i 2 /repo/scripts/your-file.sh
```

Fix warnings rather than suppressing them. If a suppression is genuinely
required, put the justification on the line above it. New scripts open with
`set -euo pipefail`, and `export LC_ALL=C` when they do any numeric formatting.

Install the pre-commit hook once:

```bash
git config core.hooksPath .githooks
```

It runs `tests/run-lint.sh` and `tests/run-vectors.sh` before every commit, or
defers to `prek run` when prek is installed.

## Things that are never done

- **Never `rm -rf` a path you did not construct.** The cleanup traps in the test
  suite pattern-match the temp directory name before deleting and refuse
  anything else. Copy that shape.
- **Never move or delete a receipt.** `offset-record.sh` only ever copies. The
  file, its SHA-256 and its stored bytes are the audit trail, and a correction
  is a new row or an `--update`, not an edit to history.
- **Never add a network call.** Not for an update check, not for a font, not for
  a price lookup.
- **Never widen the render path.** The statusline may source `factors.env`, run
  one `awk`, and read the segment cache. No database, no jq against
  `factors.json`. New derived values are computed at write time and cached.

## Commits and pull requests

Branch from `main` and open the PR against `main`. Imperative mood, one logical
change per commit, subject under 72 characters, describing what the code does
now rather than what you tried first. Plain language: a bug fix is a bug fix.
Add a dated entry to `CHANGELOG.md` for user-visible changes.

## Security

Do not open a public issue for a security problem. See [SECURITY.md](SECURITY.md).
