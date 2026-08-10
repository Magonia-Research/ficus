#!/usr/bin/env bash
# run-lint.sh — shellcheck + shfmt gate for the carbon-ledger fork.
#
# Runs shellcheck on every *.sh in the tree, upstream's own invocation (--severity=warning),
# and shfmt on fork-added files only — files listed in tests/upstream-43fb883-files.txt keep
# their upstream formatting so cherry-pick diffs stay minimal.
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
# The upstream file list is COMMITTED DATA, not a ref lookup. Deriving it from a
# local `upstream-43fb883` tag failed silently the moment this history stopped
# reaching upstream: git printed nothing, `|| true` swallowed the error, every
# upstream file read as fork-added, and shfmt failed the suite against the files
# it exists to leave alone. A missing manifest is a hard error now, because the
# only thing worse than this gate failing is it passing for the wrong reason.
UPSTREAM_MANIFEST="${REPO_DIR}/tests/upstream-43fb883-files.txt"
if [ ! -f "$UPSTREAM_MANIFEST" ]; then
  echo "FAIL: missing $UPSTREAM_MANIFEST — cannot separate fork files from upstream files" >&2
  exit 1
fi
upstream_list="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$UPSTREAM_MANIFEST")"
if [ -z "$upstream_list" ]; then
  echo "FAIL: $UPSTREAM_MANIFEST lists no paths" >&2
  exit 1
fi
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
