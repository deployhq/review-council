#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for .github/actions/gate/gate.sh — the CI authorisation gate
# (event, fork, draft, open state, commenter permission, opt-in bot-PR skip).
# A fake `gh` on PATH returns canned JSON; nothing touches GitHub.
#
# Run: bats tests/unit/gate.bats

GATE="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/.github/actions/gate/gate.sh"

setup() {
  FAKEDIR="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEDIR"
  GHLOG="$BATS_TEST_TMPDIR/ghlog"
  PERM="$BATS_TEST_TMPDIR/perm.json"
  PRJSON="$BATS_TEST_TMPDIR/pr.json"
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  : >"$GHLOG"
  : >"$GITHUB_OUTPUT"
  printf '{"permission":"write","role_name":"write"}\n' >"$PERM"
  pr_json
  cat >"$FAKEDIR/gh" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$*" >>"$GHLOG"
case "$*" in
  *permission*) cat "$PERM" ;;
  *reactions*)  : ;;
  *pulls/*)     cat "$PRJSON" ;;
esac
EOF
  chmod +x "$FAKEDIR/gh"
  export GHLOG PERM PRJSON GITHUB_OUTPUT
  export GH_TOKEN=x REPO=owner/repo PR_NUMBER=5 EVENT_NAME=issue_comment COMMENT_ID=9 COMMENTER=alice RUN_BUDGET=900
  unset SKIP_BOT_PRS
}

# pr_json [state] [draft] [head repo] [author type]: defaults to an open,
# non-draft, same-repo PR opened by a person.
pr_json() {
  jq -n --arg state "${1:-open}" --argjson draft "${2:-false}" --arg repo "${3:-owner/repo}" --arg type "${4:-User}" \
    '{state: $state, draft: $draft, head: {ref: "feature", repo: {full_name: $repo}}, user: {login: "u", type: $type}}' >"$PRJSON"
}

gate() { PATH="$FAKEDIR:$PATH" run bash "$GATE"; }
proceeds() { grep -qx 'proceed=true' "$GITHUB_OUTPUT"; }
skipped() { grep -qx 'proceed=false' "$GITHUB_OUTPUT" && printf '%s\n' "$output" | grep -qF "$1"; }

@test "gate: a write-access /review-council on an open same-repo PR proceeds" {
  gate
  [ "$status" -eq 0 ]
  proceeds
  grep -qx 'pr_number=5' "$GITHUB_OUTPUT"
  grep -qx 'head_ref=feature' "$GITHUB_OUTPUT"
  grep -qx 'timeout_minutes=45' "$GITHUB_OUTPUT"
  grep -qF 'reactions' "$GHLOG"
}

@test "gate: maintain and admin may trigger" {
  printf '{"permission":"write","role_name":"maintain"}\n' >"$PERM"
  gate
  proceeds
  : >"$GITHUB_OUTPUT"
  printf '{"permission":"admin","role_name":"admin"}\n' >"$PERM"
  gate
  proceeds
}

@test "gate: read or triage access is refused" {
  printf '{"permission":"read","role_name":"triage"}\n' >"$PERM"
  gate
  [ "$status" -eq 0 ]
  skipped "lacks write"
  ! grep -qF 'reactions' "$GHLOG" || return 1
}

@test "gate: an unreadable permission is refused" {
  cat >"$FAKEDIR/gh" <<'EOF'
#!/usr/bin/env sh
case "$*" in *permission*) exit 1 ;; esac
EOF
  chmod +x "$FAKEDIR/gh"
  gate
  skipped "could not read the commenter"
}

@test "gate: a fork PR is skipped" {
  pr_json open false someone/fork
  gate
  skipped "from a fork"
}

@test "gate: a draft PR is skipped" {
  pr_json open true
  gate
  skipped "is a draft"
}

@test "gate: a closed PR is skipped" {
  pr_json closed
  gate
  skipped "is not open"
}

@test "gate: a non-numeric PR number is skipped" {
  PR_NUMBER='5/../x' gate
  skipped "no PR number"
}

@test "gate: a pull_request event needs no commenter check" {
  EVENT_NAME=pull_request COMMENT_ID='' COMMENTER='' gate
  proceeds
  ! grep -qF 'permission' "$GHLOG" || return 1
}

@test "gate: bot-opened PRs are reviewed by default" {
  pr_json open false owner/repo Bot
  gate
  proceeds
}

@test "gate: skip_bot_prs skips a bot-opened PR, not a person's" {
  pr_json open false owner/repo Bot
  SKIP_BOT_PRS=true gate
  skipped "opened by a bot"
  : >"$GITHUB_OUTPUT"
  pr_json
  SKIP_BOT_PRS=true gate
  proceeds
}
