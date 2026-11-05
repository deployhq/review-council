#!/usr/bin/env bats

# Every composite action's action.yml must be valid YAML. actionlint checks
# the workflows but not action.yml files, and GitHub only reports a broken one
# when a run tries to load it (an unquoted ": " in a description did that).
#
# Run: bats tests/unit/action-yaml.bats

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

@test "action.yml files parse as YAML" {
  command -v yq >/dev/null || skip "yq not installed"
  for f in "$ROOT"/.github/actions/*/action.yml; do
    run yq '.' "$f"
    [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
  done
}

@test "request_changes is wired from the reusable workflow to RC_PR_REQUEST_CHANGES" {
  command -v yq >/dev/null || skip "yq not installed"
  wf="$ROOT/.github/workflows/review-council.yml"
  act="$ROOT/.github/actions/review/action.yml"
  [ "$(yq '.on.workflow_call.inputs.request_changes.type' "$wf")" = boolean ]
  [ "$(yq '.on.workflow_call.inputs.request_changes.default' "$wf")" = true ]
  [ "$(yq '.jobs[].steps[] | select(.uses == "./rc-plugin/.github/actions/review") | .with.request_changes' "$wf")" = '${{ inputs.request_changes }}' ]
  [ "$(yq '.inputs.request_changes.default' "$act")" = true ]
  [ "$(yq '.runs.steps[] | select(.name == "Run Review Council") | .env.RC_PR_REQUEST_CHANGES' "$act")" = '${{ inputs.request_changes }}' ]
}
