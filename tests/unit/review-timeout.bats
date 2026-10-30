#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for .github/actions/review/review-timeout.sh — sizes the CI run's
# time limit so it never kills a custom seat before the seat's own deadline.
# Input: the gate's minutes as $1, the resolved rc-config.sh output on stdin.
#
# Run: bats tests/unit/review-timeout.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/.github/actions/review/review-timeout.sh"

seat() { # seat <slot> <harness> [timeout_minutes] [needs_confirm] [provider] [effort]
  printf 'reviewer.custom.%s.enabled=true\nreviewer.custom.%s.harness=%s\nreviewer.custom.%s.needs_confirm=%s\nreviewer.custom.%s.provider=%s\n' \
    "$1" "$1" "$2" "$1" "${4:-false}" "$1" "${5:-openrouter}"
  [ -z "${3:-}" ] || printf 'reviewer.custom.%s.opt.timeout_minutes=%s\n' "$1" "$3"
  [ -z "${6:-}" ] || printf 'reviewer.custom.%s.opt.effort=%s\n' "$1" "$6"
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

@test "review-timeout: an OpenRouter agent seat without timeout_minutes uses the reviewer timeout (fits)" {
  run --separate-stderr bash "$SCRIPT" 45 < <(seat kimi claude; printf 'settings.reviewer_timeout_seconds=600\n')
  [ "$output" = 45 ]
}

@test "review-timeout: a local (ollama) agent seat without timeout_minutes uses its 30-minute default" {
  run --separate-stderr bash "$SCRIPT" 45 < <(seat qwen opencode "" false ollama)
  [ "$output" = 50 ]
}

@test "review-timeout: an OpenRouter ocr seat without timeout_minutes fits the run budget (no change)" {
  run --separate-stderr bash "$SCRIPT" 45 < <(seat qwen ocr; printf 'settings.run_budget_seconds=900\n')
  [ "$output" = 45 ]
}

@test "review-timeout: an ocr seat's deadline is multiplied by its effort rounds" {
  run --separate-stderr bash "$SCRIPT" 45 < <(seat qwen ocr 20 false openrouter medium)
  [ "$output" = 62 ]
}

@test "review-timeout: a local ocr seat without timeout_minutes gets 30 minutes per round" {
  run --separate-stderr bash "$SCRIPT" 45 < <(seat qwen ocr "" false ollama)
  [ "$output" = 52 ]
}

@test "review-timeout: a high-effort ocr seat past the job cap is capped, with a warning" {
  run --separate-stderr bash "$SCRIPT" 45 < <(seat qwen ocr 30 false openrouter high)
  [ "$output" = 110 ]
  printf '%s' "$stderr" | grep -qF 'qwen'
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
