#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for scripts/sync-metadata.sh.
#
# The primary test runs `sync-metadata.sh --check` against the real,
# committed repo files and asserts it passes -- this is the drift detector
# CI relies on: if .claude-plugin/plugin.json's `.description` is edited
# without re-running `scripts/sync-metadata.sh` to restamp README.md /
# CLAUDE.md / skills/run/SKILL.md / marketplace.json, this test fails the
# `bats tests/unit/` run.
#
# A second test proves --check actually detects drift (and writes nothing)
# by working on a throwaway copy of the repo, so it never touches the real
# checkout.
#
# Requires jq (same as the script under test). Skips gracefully if jq isn't
# installed -- see scripts/sync-metadata.sh's own header for why that's a
# graceful no-op rather than a failure.
#
# Run: bats tests/unit/sync-metadata.bats

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$ROOT/scripts/sync-metadata.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
}

@test "sync-metadata.sh --check passes against the committed files" {
  run --separate-stderr "$SCRIPT" --check
  echo "status=$status"
  echo "output=<<$output>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
}

@test "sync-metadata.sh --check is idempotent and writes nothing" {
  BEFORE="$(cd "$ROOT" && git diff --stat -- . 2>/dev/null || true)"
  run --separate-stderr "$SCRIPT" --check
  [ "$status" -eq 0 ]
  run --separate-stderr "$SCRIPT" --check
  [ "$status" -eq 0 ]
  AFTER="$(cd "$ROOT" && git diff --stat -- . 2>/dev/null || true)"
  [ "$BEFORE" = "$AFTER" ]
}

@test "sync-metadata.sh --check detects a drifted file" {
  SCRATCH="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$SCRATCH"
  cp -R "$ROOT/.claude-plugin" "$ROOT/README.md" "$ROOT/CLAUDE.md" "$ROOT/skills" "$ROOT/scripts" "$SCRATCH/"

  TMP_MKT="$BATS_TEST_TMPDIR/marketplace.json"
  jq '.description = "stale description for test"' "$SCRATCH/.claude-plugin/marketplace.json" >"$TMP_MKT"
  mv "$TMP_MKT" "$SCRATCH/.claude-plugin/marketplace.json"

  run --separate-stderr "$SCRATCH/scripts/sync-metadata.sh" --check
  echo "status=$status"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 1 ]

  case "$stderr" in
    *marketplace.json*) ;;
    *) echo "expected marketplace.json to be reported out of sync"; return 1 ;;
  esac

  # --check must never write.
  ACTUAL_DESC="$(jq -r '.description' "$SCRATCH/.claude-plugin/marketplace.json")"
  [ "$ACTUAL_DESC" = "stale description for test" ]
}
