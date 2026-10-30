#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for .github/actions/review/summary.sh: the job summary and the
# step-log trace written after the run (also after a timeout or cancel).
#
# Run: bats tests/unit/summary.bats

ACTION="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/.github/actions/review"

setup() {
  export GITHUB_ACTION_PATH="$ACTION" RUNNER_TEMP="$BATS_TEST_TMPDIR"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  LOG="$RUNNER_TEMP/rc-run.jsonl"
}

tool() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{"description":"%s"}}]}}\n' "$1" "$2"; }

@test "summary: a failed run says failed, and the step log shows the error" {
  { tool Bash "Run the static scan"
    printf '{"type":"result","subtype":"success","is_error":true,"duration_ms":1000,"result":"Credit balance is too low"}\n'; } >"$LOG"
  run bash "$ACTION/summary.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::error::Review Council: Credit balance is too low"* ]] || false
  grep -qF '_failed · 1s' "$GITHUB_STEP_SUMMARY"
}

@test "summary: the step log lists the tools that ran (last one shows where a hang stopped)" {
  { tool Bash "Run the static scan"; tool Agent "Security review"; } >"$LOG"
  run bash "$ACTION/summary.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Bash: Run the static scan"* ]] || false
  [[ "$output" == *"Agent: Security review"* ]] || false
  [[ "$output" != *"::error::"* ]] || false
  grep -qF 'no final result' "$GITHUB_STEP_SUMMARY"
}

@test "summary: a secret in the trace is redacted" {
  tool Bash "echo sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345" >"$LOG"
  run bash "$ACTION/summary.sh"
  [[ "$output" == *"[REDACTED]"* ]] || false
  [[ "$output" != *"ABCDEFGHIJKLMNOP"* ]] || false
}

@test "summary: a successful run keeps its subtype" {
  printf '{"type":"result","subtype":"success","is_error":false,"duration_ms":61000,"total_cost_usd":1.5,"result":"done"}\n' >"$LOG"
  run bash "$ACTION/summary.sh"
  [[ "$output" != *"::error::"* ]] || false
  grep -qF '_success · 61s · $1.5_' "$GITHUB_STEP_SUMMARY"
  grep -qxF 'done' "$GITHUB_STEP_SUMMARY"
}
