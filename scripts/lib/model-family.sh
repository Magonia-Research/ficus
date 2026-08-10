#!/usr/bin/env bash
# model-family.sh — single source of truth for model-family resolution.
# First-match precedence: fable/mythos -> opus -> haiku -> sonnet (fallback).
# Locked by methodology vector "family-precedence-fable-over-opus".
# recompute.sh mirrors this in SQL LIKE clauses (annotated there, not sourced);
# keep the two in sync when adding a family.
#
# Sourced by backfill.sh, persist-session.sh, and tests/run-vectors.sh; must
# stay side-effect-free (persist-session.sh runs without set -e in a Stop hook).

resolve_family() {
  local model="$1"
  if echo "$model" | grep -qiE "fable|mythos"; then
    echo "fable"
  elif echo "$model" | grep -qi "opus"; then
    echo "opus"
  elif echo "$model" | grep -qi "haiku"; then
    echo "haiku"
  else
    echo "sonnet"
  fi
}
