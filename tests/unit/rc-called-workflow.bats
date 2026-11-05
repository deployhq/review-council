#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for scripts/rc-called-workflow.sh: when a changed workflow calls
# Review Council's reusable workflow, print the plugin's own copy of it as
# reference context for reviewers and verifiers (skills/run/SKILL.md Step 2).
#
# Run: bats tests/unit/rc-called-workflow.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
REAL="$REPO_ROOT/scripts/rc-called-workflow.sh"

USES='deployhq/review-council/.github/workflows/review-council.yml'

setup() {
  # A fake plugin root, so the tests do not depend on the real workflow.
  PLUGIN="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$PLUGIN/scripts" "$PLUGIN/.github/workflows" "$PLUGIN/.claude-plugin"
  cp "$REAL" "$PLUGIN/scripts/"
  SCRIPT="$PLUGIN/scripts/rc-called-workflow.sh"
  printf '{"name":"review-council","version":"9.8.7"}\n' > "$PLUGIN/.claude-plugin/plugin.json"
  printf 'name: Review Council\nconcurrency:\n  group: fake-group-marker\n' > "$PLUGIN/.github/workflows/review-council.yml"

  # The reviewed repo, used as the working directory.
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.github/workflows"
  cd "$REPO" || return 1
}

caller() { # caller <file> <uses-line>
  printf 'on: pull_request\njobs:\n  review:\n%s\n' "$2" > "$REPO/$1"
}

called() { run --separate-stderr "$SCRIPT"; }

@test "a changed caller workflow prints one block with path, ref, version and the copy" {
  caller .github/workflows/rc.yml "    uses: $USES@v1.2.3"
  called <<< ".github/workflows/rc.yml"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^CALLED REVIEW COUNCIL WORKFLOW (reference only' <<< "$output")" -eq 1 ]
  [[ "$output" == *"- .github/workflows/rc.yml pins @v1.2.3"* ]]
  [[ "$output" == *"(plugin version 9.8.7)"* ]]
  [[ "$output" == *"group: fake-group-marker"* ]]
  [[ "$output" == *'```yaml'* ]]
  [ "${lines[${#lines[@]}-1]}" = '```' ]
}

@test "two calling files: one block, two caller lines, copy printed once" {
  caller .github/workflows/a.yml "    uses: $USES@main"
  caller .github/workflows/b.yaml "    uses: $USES@0123abc"
  called <<< $'.github/workflows/a.yml\n.github/workflows/b.yaml'
  [ "$status" -eq 0 ]
  [ "$(grep -c '^CALLED REVIEW COUNCIL WORKFLOW' <<< "$output")" -eq 1 ]
  [[ "$output" == *"- .github/workflows/a.yml pins @main"* ]]
  [[ "$output" == *"- .github/workflows/b.yaml pins @0123abc"* ]]
  [ "$(grep -c 'fake-group-marker' <<< "$output")" -eq 1 ]
}

@test "quoted value, list dash and trailing comment are still matched" {
  caller .github/workflows/q1.yml "    uses: \"$USES@v1\""
  caller .github/workflows/q2.yml "    uses: '$USES@release/v2' # pinned"
  caller .github/workflows/q3.yml "  - uses: $USES@abc123 # comment"
  called <<< $'.github/workflows/q1.yml\n.github/workflows/q2.yml\n.github/workflows/q3.yml'
  [ "$status" -eq 0 ]
  [[ "$output" == *"- .github/workflows/q1.yml pins @v1"$'\n'* ]]
  [[ "$output" == *"- .github/workflows/q2.yml pins @release/v2"$'\n'* ]]
  [[ "$output" == *"- .github/workflows/q3.yml pins @abc123"$'\n'* ]]
}

@test "no caller: a workflow that uses something else prints nothing" {
  caller .github/workflows/ci.yml "    uses: actions/checkout@v4"
  caller .github/workflows/other.yml "    uses: someone/review-council/.github/workflows/review-council.yml@v1"
  called <<< $'.github/workflows/ci.yml\n.github/workflows/other.yml'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "non-workflow paths, .., subdirectories, missing files and symlinks are ignored" {
  mkdir -p "$REPO/src" "$REPO/.github/workflows/sub" "$REPO/elsewhere"
  caller src/x.yml "    uses: $USES@v1"
  caller .github/workflows/sub/x.yml "    uses: $USES@v1"
  caller elsewhere/target.yml "    uses: $USES@v1"
  ln -s ../../elsewhere/target.yml "$REPO/.github/workflows/link.yml"
  caller .github/workflows/notyaml.txt "    uses: $USES@v1"
  called <<< $'src/x.yml\n.github/workflows/sub/x.yml\n.github/workflows/../../elsewhere/target.yml\n.github/workflows/missing.yml\n.github/workflows/link.yml\n.github/workflows/notyaml.txt\n/etc/passwd'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a symlinked workflows directory is ignored" {
  rm -rf "$REPO/.github/workflows"
  mkdir -p "$REPO/elsewhere"
  caller elsewhere/rc.yml "    uses: $USES@v1"
  ln -s ../elsewhere "$REPO/.github/workflows"
  called <<< ".github/workflows/rc.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a ref with bad characters prints (unrecognised ref), never the raw value" {
  caller .github/workflows/bad.yml "    uses: $USES@\$(touch pwned)\`id\`"
  called <<< ".github/workflows/bad.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- .github/workflows/bad.yml pins @(unrecognised ref)"* ]]
  [[ "$output" != *"pwned"* ]]
  [[ "$output" != *'`id`'* ]]
  [ ! -e "$REPO/pwned" ]
}

@test "an over-long ref is unrecognised" {
  long="$(printf 'a%.0s' $(seq 1 101))"
  caller .github/workflows/long.yml "    uses: $USES@$long"
  called <<< ".github/workflows/long.yml"
  [[ "$output" == *"pins @(unrecognised ref)"* ]]
  [[ "$output" != *"$long"* ]]
}

@test "plugin copy missing: header, caller lines, then the not-installed line" {
  rm "$PLUGIN/.github/workflows/review-council.yml"
  caller .github/workflows/rc.yml "    uses: $USES@v1"
  called <<< ".github/workflows/rc.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- .github/workflows/rc.yml pins @v1"* ]]
  [ "${lines[${#lines[@]}-1]}" = "Review Council's own workflow is not in this plugin install, so it cannot be shown." ]
  [[ "$output" != *'```'* ]]
}

@test "version is unknown when plugin.json is missing" {
  rm "$PLUGIN/.claude-plugin/plugin.json"
  caller .github/workflows/rc.yml "    uses: $USES@v1"
  called <<< ".github/workflows/rc.yml"
  [[ "$output" == *"(plugin version unknown)"* ]]
}

@test "the fence is longer than any backtick run in the copy" {
  printf 'run: |\n  echo "````` five"\n' > "$PLUGIN/.github/workflows/review-council.yml"
  caller .github/workflows/rc.yml "    uses: $USES@v1"
  called <<< ".github/workflows/rc.yml"
  [[ "$output" == *$'\n``````yaml\n'* ]]
  [ "${lines[${#lines[@]}-1]}" = '``````' ]
}

@test "a caller listed after 60 non-workflow paths is still found" {
  caller .github/workflows/rc.yml "    uses: $USES@v1"
  input="$(for i in $(seq 1 60); do echo "src/file$i.rb"; done; echo .github/workflows/rc.yml)"
  called <<< "$input"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- .github/workflows/rc.yml pins @v1"* ]]
}

@test "only the first 50 workflow paths are considered" {
  caller .github/workflows/rc.yml "    uses: $USES@v1"
  input="$(for i in $(seq 1 50); do echo ".github/workflows/w$i.yml"; done; echo .github/workflows/rc.yml)"
  called <<< "$input"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "smoke: the real plugin copy exists and is shown" {
  [ -f "$REPO_ROOT/.github/workflows/review-council.yml" ]
  caller .github/workflows/rc.yml "    uses: $USES@main"
  run --separate-stderr "$REAL" <<< ".github/workflows/rc.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"concurrency:"* ]]
  [[ "$output" != *"plugin version unknown"* ]]
}
