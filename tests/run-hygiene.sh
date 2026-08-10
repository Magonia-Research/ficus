#!/usr/bin/env bash
# run-hygiene.sh — proves the fork has zero network call sites in the code that
# runs on this machine: scripts/, hooks/, skills/.
#
# Two checks:
#   1. In shell code (comment lines stripped): no curl/wget/nc, no URL literals,
#      no /dev/tcp, no python http.server.
#   2. In every file (skills' markdown included — skill text is agent-executable
#      instruction): no curl/wget, no git pull/clone/fetch, no http.server.
# Citation URLs in comments are the only sanctioned appearance of http(s)://.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"

fail=0

# --- 1. shell code, comments stripped --------------------------------------
sh_hits=""
while IFS= read -r f; do
  hits="$(sed 's/^[[:space:]]*#.*//' "$f" |
    grep -n -E '\b(curl|wget|nc)\b|https?://|/dev/tcp|http\.server' |
    sed "s|^|$f:|" || true)"
  [ -n "$hits" ] && sh_hits="${sh_hits}${hits}
"
done < <(find scripts hooks skills -name '*.sh' 2>/dev/null | sort)

if [ -n "$sh_hits" ]; then
  echo "FAIL hygiene: network call sites in shell code:" >&2
  printf '%s' "$sh_hits" >&2
  fail=1
else
  echo "PASS hygiene: shell code clean"
fi

# --- 2. fork naming: no legacy claude-carbon paths or env vars ---------------
# Comment lines excepted (upstream attribution); everything executable must use
# the carbon-ledger state dir and CARBON_LEDGER_* env vars, with no fallback.
legacy_hits="$(grep -rn -E 'claude-carbon|CLAUDE_CARBON' scripts hooks skills 2>/dev/null |
  grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"

if [ -n "$legacy_hits" ]; then
  echo "FAIL hygiene: legacy claude-carbon naming in executable lines:" >&2
  printf '%s\n' "$legacy_hits" >&2
  fail=1
else
  echo "PASS hygiene: no legacy claude-carbon naming"
fi

# --- 3. all files: network commands anywhere (markdown included) ------------
cmd_hits="$(grep -rn -E '\b(curl|wget)\b|git (pull|clone|fetch)|http\.server' \
  scripts hooks skills 2>/dev/null || true)"

if [ -n "$cmd_hits" ]; then
  echo "FAIL hygiene: network commands referenced:" >&2
  printf '%s\n' "$cmd_hits" >&2
  fail=1
else
  echo "PASS hygiene: no network commands in scripts/ hooks/ skills/"
fi

exit "$fail"
