# Security Policy

## Scope

Ficus runs entirely locally and makes no network calls, but it does touch
sensitive material:

- It reads your Claude Code transcripts under `~/.claude/projects/` to compute
  usage, and writes them to a SQLite database in `~/.claude/carbon-ledger/`.
- It stores receipt files and their bytes in that database. Receipts carry
  names, amounts and sometimes addresses.
- The `Stop` and `SessionStart` hooks execute on your machine on every session.

Anything that could leak transcript content or receipt data, execute unexpected
code through the hooks, the skills or the dashboard, or make a network call from
a tool that is supposed to make none, is a security issue worth reporting.

The dashboard is a particular case: it embeds ledger strings into an HTML file
that opens over `file://`. Every value reaches the DOM as a text node, never as
parsed markup. A way around that is a security issue.

## Not in scope

The estimates. The methodology is documented as ±50% order-of-magnitude and
disagreeing with a factor is a
[normal issue](https://github.com/Magonia-Research/ficus/issues), not a vulnerability.

## Reporting

Do not open a public issue for a security problem.
[Open a private security advisory](https://github.com/Magonia-Research/ficus/security/advisories/new)
on GitHub. Include what you found, how to reproduce it, and what an attacker
could do with it.

## Upstream

Ficus is a fork of
[claude-carbon](https://github.com/gwittebolle/claude-carbon) pinned at
`upstream-43fb883`. Several upstream components were deleted in this fork
because of their attack surface — the OAuth-token-reading statusline, the
pipe-to-shell installer, and the auto-update path (see the README's fork
provenance section). A vulnerability that only exists in upstream code this fork
does not ship belongs in
[upstream's advisory queue](https://github.com/gwittebolle/claude-carbon/security/advisories/new),
not here.
