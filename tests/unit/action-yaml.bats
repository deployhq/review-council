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

@test "recheck_on_push is wired from the reusable workflow to the gate's RECHECK_ON_PUSH" {
  command -v yq >/dev/null || skip "yq not installed"
  wf="$ROOT/.github/workflows/review-council.yml"
  gate="$ROOT/.github/actions/gate/action.yml"
  [ "$(yq '.on.workflow_call.inputs.recheck_on_push.type' "$wf")" = boolean ]
  [ "$(yq '.on.workflow_call.inputs.recheck_on_push.default' "$wf")" = true ]
  [ "$(yq '.jobs.gate.steps[] | select(.uses == "./rc-plugin/.github/actions/gate") | .with.recheck_on_push' "$wf")" = '${{ inputs.recheck_on_push }}' ]
  [ "$(yq '.inputs.recheck_on_push.default' "$gate")" = true ]
  [ "$(yq '.runs.steps[] | select(.id == "gate") | .env.RECHECK_ON_PUSH' "$gate")" = '${{ inputs.recheck_on_push }}' ]
  [ "$(yq '.runs.steps[] | select(.id == "gate") | .env.COMMENT_BODY' "$gate")" = '${{ github.event.comment.body }}' ]
  [ "$(yq '.runs.steps[] | select(.id == "gate") | .env.EVENT_ACTION' "$gate")" = '${{ github.event.action }}' ]
}

@test "the gate's mode reaches the review run as RC_MODE, recheck_model as RC_RECHECK_MODEL" {
  command -v yq >/dev/null || skip "yq not installed"
  wf="$ROOT/.github/workflows/review-council.yml"
  gate="$ROOT/.github/actions/gate/action.yml"
  act="$ROOT/.github/actions/review/action.yml"
  [ "$(yq '.outputs.mode.value' "$gate")" = '${{ steps.gate.outputs.mode }}' ]
  [ "$(yq '.jobs.gate.outputs.mode' "$wf")" = '${{ steps.gate.outputs.mode }}' ]
  [ "$(yq '.on.workflow_call.inputs.recheck_model.type' "$wf")" = string ]
  [ "$(yq '.on.workflow_call.inputs.recheck_model.default' "$wf")" = '' ]
  step='.jobs.review.steps[] | select(.uses == "./rc-plugin/.github/actions/review")'
  [ "$(yq "$step | .with.mode" "$wf")" = '${{ needs.gate.outputs.mode }}' ]
  [ "$(yq "$step | .with.recheck_model" "$wf")" = '${{ inputs.recheck_model }}' ]
  [ "$(yq '.inputs.mode.default' "$act")" = full ]
  [ "$(yq '.inputs.recheck_model.default' "$act")" = '' ]
  run_step='.runs.steps[] | select(.name == "Run Review Council")'
  [ "$(yq "$run_step | .env.RC_MODE" "$act")" = '${{ inputs.mode }}' ]
  [ "$(yq "$run_step | .env.RC_RECHECK_MODEL" "$act")" = '${{ inputs.recheck_model }}' ]
}

@test "the gate job may react (pull-requests: write); only a recheck's review job cancels in progress" {
  command -v yq >/dev/null || skip "yq not installed"
  wf="$ROOT/.github/workflows/review-council.yml"
  [ "$(yq '.jobs.gate.permissions."pull-requests"' "$wf")" = write ]
  [ "$(yq '.jobs.gate.concurrency' "$wf")" = null ]
  [ "$(yq '.jobs.review.concurrency."cancel-in-progress"' "$wf")" = "\${{ needs.gate.outputs.mode == 'recheck' }}" ]
  [[ "$(yq '.jobs.review.concurrency.group' "$wf")" == *"format('rc-run-{0}', github.run_id)"* ]]
}
