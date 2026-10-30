#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for .github/actions/review/review-timeout.sh — sizes the CI run's
# time limit so it never kills a custom seat before the seat's own deadline.
# Input: the gate's minutes as $1, the resolved rc-config.sh output on stdin.
#
# Run: bats tests/unit/review-timeout.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/.github/actions/review/review-timeout.sh"

seat() { # seat <slot> <harness> [timeout_minutes] [needs_confirm]
  printf 'reviewer.custom.%s.enabled=true\nreviewer.custom.%s.harness=%s\nreviewer.custom.%s.needs_confirm=%s\n' \
    "$1" "$1" "$2" "$1" "${4:-false}"
  [ -z "${3:-}" ] || printf 'reviewer.custom.%s.opt.timeout_minutes=%s\n' "$1" "$3"
}

@test "review-timeout: no seats keeps the gate's limit" {
  run --separate-stderr bash "$SCRIPT" 45 < <(printf 'settings.ci=true\n')
  [ "$status" -eq 0 ]
  [ "$output" = 45 ]
}

@test "review-timeout: a seat's timeout_minutes plus headroom raises the limit" {
  run --separate-stderr bash "$SCRIPT" 45 < <(seat kimi claude 60)
  [ "$output" = 80 ]
}

@test "review-timeout: an agent seat without timeout_minutes uses its 30-minute default" {
  run --separate-stderr bash "$SCRIPT" 45 < <(seat kimi claude)
  [ "$output" = 50 ]
}

@test "review-timeout: an ocr seat without timeout_minutes fits the run budget (no change)" {
  run --separate-stderr bash "$SCRIPT" 45 < <(seat qwen ocr)
  [ "$output" = 45 ]
}

@test "review-timeout: the longest seat wins" {
  run --separate-stderr bash "$SCRIPT" 45 < <(seat a claude 40; seat b opencode 70; seat c codex)
  [ "$output" = 90 ]
}

@test "review-timeout: a seat that won't run (not approved, or disabled) is ignored" {
  run --separate-stderr bash "$SCRIPT" 45 < <(seat kimi claude 90 true; printf 'reviewer.custom.x.enabled=false\nreviewer.custom.x.harness=claude\nreviewer.custom.x.opt.timeout_minutes=90\n')
  [ "$output" = 45 ]
}

@test "review-timeout: a limit beyond the job's cap is capped, with a warning" {
  run --separate-stderr bash "$SCRIPT" 45 < <(seat kimi claude 180)
  [ "$output" = 110 ]
  printf '%s' "$stderr" | grep -qF '::warning::'
  printf '%s' "$stderr" | grep -qF 'kimi'
}

@test "review-timeout: a bad gate value falls back to 45" {
  run --separate-stderr bash "$SCRIPT" abc < <(printf '')
  [ "$output" = 45 ]
}
