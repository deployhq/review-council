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
