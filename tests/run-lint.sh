#!/usr/bin/env bash
# run-lint.sh — shellcheck + shfmt gate for the carbon-ledger fork.
#
# Runs shellcheck on every *.sh in the tree, upstream's own invocation (--severity=warning),
# and shfmt on fork-added files only — files present in the upstream-43fb883 tag keep their
# upstream formatting so cherry-pick diffs stay minimal.
#
# Uses local binaries when present; otherwise runs the pinned container images
# (Apple `container` CLI, --platform linux/arm64 — the CLI mis-detects the platform
# when left to negotiate).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"

SHELLCHECK_IMAGE="koalaman/shellcheck:stable"
SHFMT_IMAGE="mvdan/shfmt:latest"

fail=0

# --- collect shell files ---------------------------------------------------
sh_files=()
while IFS= read -r f; do
  sh_files+=("$f")
done < <(find . -name '*.sh' -not -path './.git/*' | sed 's|^\./||' | sort)

if [ "${#sh_files[@]}" -eq 0 ]; then
  echo "FAIL: no shell files found (wrong directory?)" >&2
  exit 1
fi

# --- shellcheck ------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=warning "${sh_files[@]}"; then
    echo "PASS shellcheck (${#sh_files[@]} files, local)"
  else
    echo "FAIL shellcheck" >&2
    fail=1
  fi
else
  repo_paths=()
  for f in "${sh_files[@]}"; do repo_paths+=("/repo/$f"); done
  if container run --rm --platform linux/arm64 \
    --mount "type=bind,source=$REPO_DIR,target=/repo" \
    "$SHELLCHECK_IMAGE" --severity=warning "${repo_paths[@]}"; then
    echo "PASS shellcheck (${#sh_files[@]} files, container)"
  else
    echo "FAIL shellcheck" >&2
    fail=1
  fi
fi

# --- shfmt (fork-added files only) -----------------------------------------
upstream_list="$(git ls-tree -r upstream-43fb883 --name-only 2>/dev/null || true)"
fork_files=()
for f in "${sh_files[@]}"; do
  if ! grep -qxF "$f" <<<"$upstream_list"; then
    fork_files+=("$f")
  fi
done

if [ "${#fork_files[@]}" -eq 0 ]; then
  echo "PASS shfmt (no fork-added shell files yet)"
elif command -v shfmt >/dev/null 2>&1; then
  if shfmt -d -i 2 "${fork_files[@]}"; then
    echo "PASS shfmt (${#fork_files[@]} fork-added files, local)"
  else
    echo "FAIL shfmt — run: shfmt -w -i 2 <file>" >&2
    fail=1
  fi
else
  repo_paths=()
  for f in "${fork_files[@]}"; do repo_paths+=("/repo/$f"); done
  if container run --rm --platform linux/arm64 \
    --mount "type=bind,source=$REPO_DIR,target=/repo" \
    "$SHFMT_IMAGE" -d -i 2 "${repo_paths[@]}"; then
    echo "PASS shfmt (${#fork_files[@]} fork-added files, container)"
  else
    echo "FAIL shfmt — run: shfmt -w -i 2 <file>" >&2
    fail=1
  fi
fi

exit "$fail"
