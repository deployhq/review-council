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
  REVIEWS="$BATS_TEST_TMPDIR/reviews.json"
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  : >"$GHLOG"
  : >"$GITHUB_OUTPUT"
  printf '{"permission":"write","role_name":"write"}\n' >"$PERM"
  pr_json
  printf '[]\n' >"$REVIEWS"
  cat >"$FAKEDIR/gh" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$*" >>"$GHLOG"
case "$*" in
  *permission*) cat "$PERM" ;;
  *reactions*)  : ;;
  */reviews*)   [ -f "$REVIEWS" ] || exit 1; cat "$REVIEWS" ;;
  *pulls/*)     cat "$PRJSON" ;;
esac
EOF
  chmod +x "$FAKEDIR/gh"
  export GHLOG PERM PRJSON REVIEWS GITHUB_OUTPUT
  export GH_TOKEN=x REPO=owner/repo PR_NUMBER=5 EVENT_NAME=issue_comment COMMENT_ID=9 COMMENTER=alice RUN_BUDGET=900
  export COMMENT_BODY='/review-council'
  unset SKIP_BOT_PRS EVENT_ACTION RECHECK_ON_PUSH
}

# pr_json [state] [draft] [head repo] [author type]: defaults to an open,
# non-draft, same-repo PR opened by a person.
pr_json() {
  jq -n --arg state "${1:-open}" --argjson draft "${2:-false}" --arg repo "${3:-owner/repo}" --arg type "${4:-User}" \
    '{state: $state, draft: $draft, head: {ref: "feature", repo: {full_name: $repo}}, user: {login: "u", type: $type}}' >"$PRJSON"
}

gate() { PATH="$FAKEDIR:$PATH" run bash "$GATE"; }
mode_is() { grep -qx "mode=$1" "$GITHUB_OUTPUT"; }

# A council review (its body carries the rc:review marker) and someone else's.
rc_review() { jq -n --arg state "$1" '{state: $state, body: "Summary\n<!-- rc:review -->\n"}'; }
other_review() { jq -n --arg state "$1" '{state: $state, body: "please fix"}'; }
proceeds() { grep -qx 'proceed=true' "$GITHUB_OUTPUT"; }
skipped() { grep -qx 'proceed=false' "$GITHUB_OUTPUT" && printf '%s\n' "$output" | grep -qF "$1"; }

@test "gate: a write-access /review-council on an open same-repo PR proceeds" {
  gate
  [ "$status" -eq 0 ]
  proceeds
  grep -qx 'pr_number=5' "$GITHUB_OUTPUT"
  grep -qx 'head_ref=feature' "$GITHUB_OUTPUT"
  grep -qx 'timeout_minutes=45' "$GITHUB_OUTPUT"
  mode_is full
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
  EVENT_NAME=pull_request EVENT_ACTION=opened COMMENT_ID='' COMMENTER='' gate
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

# --- mode -------------------------------------------------------------------

@test "mode: a bare /review-council, or with a trailing space or newline, is a full run" {
  for body in '/review-council' '/review-council ' $'/review-council\r\n' $'/review-council\n\nthanks'; do
    : >"$GITHUB_OUTPUT"
    COMMENT_BODY="$body" gate
    proceeds
    mode_is full || { echo "body: $body"; return 1; }
    grep -qx 'timeout_minutes=45' "$GITHUB_OUTPUT"
  done
}

@test "mode: /review-council recheck is a recheck with a 15-minute timeout" {
  COMMENT_BODY='/review-council recheck' RUN_BUDGET=3600 gate
  proceeds
  mode_is recheck
  grep -qx 'timeout_minutes=15' "$GITHUB_OUTPUT"
  grep -qF 'reactions' "$GHLOG"
}

@test "mode: extra spaces, tabs, CRLF and trailing text still read the second word" {
  for body in '/review-council   recheck' $'/review-council\trecheck ' $'/review-council recheck\r\n' $'/review-council\r\nrecheck please'; do
    : >"$GITHUB_OUTPUT"
    COMMENT_BODY="$body" gate
    mode_is recheck || { echo "body: $body"; return 1; }
  done
}

@test "mode: check, any case and hyphens also mean a recheck" {
  for body in '/review-council check' '/review-council Check' '/review-council Recheck' '/review-council RE-CHECK' '/review-council re-check' '/Review-Council check' $'/review-council check\r\nthanks'; do
    : >"$GITHUB_OUTPUT"
    COMMENT_BODY="$body" gate
    proceeds
    mode_is recheck || { echo "body: $body"; return 1; }
  done
}

@test "mode: any other second word is a full run" {
  for body in '/review-council something' '/review-council run' '/review-council rechecks' '/review-council checks' '/review-council checkout' '/review-council * recheck'; do
    : >"$GITHUB_OUTPUT"
    COMMENT_BODY="$body" gate
    proceeds
    mode_is full || { echo "body: $body"; return 1; }
  done
}

@test "mode: the second word counts only after exactly /review-council" {
  COMMENT_BODY='/review-councilx recheck' gate
  mode_is full
}

@test "mode: a recheck comment still needs write access" {
  printf '{"permission":"read","role_name":"read"}\n' >"$PERM"
  COMMENT_BODY='/review-council recheck' gate
  skipped "lacks write"
}

@test "mode: an opened, reopened or ready_for_review PR is a full run and lists no reviews" {
  for action in opened ready_for_review reopened; do
    : >"$GITHUB_OUTPUT"
    EVENT_NAME=pull_request EVENT_ACTION=$action COMMENT_ID='' COMMENTER='' COMMENT_BODY='' gate
    proceeds
    mode_is full
  done
  ! grep -qF '/reviews' "$GHLOG" || return 1
}

# --- recheck on push (pull_request synchronize) -----------------------------

push() { EVENT_NAME=pull_request EVENT_ACTION=synchronize COMMENT_ID='' COMMENTER='' COMMENT_BODY='' gate; }

@test "push: rechecks while a council review requests changes" {
  { other_review APPROVED; rc_review CHANGES_REQUESTED; } | jq -s . >"$REVIEWS"
  push
  [ "$status" -eq 0 ]
  proceeds
  mode_is recheck
  grep -qx 'timeout_minutes=15' "$GITHUB_OUTPUT"
  grep -qF -- '--paginate repos/owner/repo/pulls/5/reviews' "$GHLOG"
  ! grep -qF 'reactions' "$GHLOG" || return 1
  ! grep -qF 'permission' "$GHLOG" || return 1
}

@test "push: finds a council review on a later page" {
  { other_review COMMENTED | jq -s .; rc_review CHANGES_REQUESTED | jq -s .; } >"$REVIEWS"
  push
  proceeds
  mode_is recheck
}

@test "push: skips when no council review requests changes" {
  { rc_review DISMISSED; rc_review COMMENTED; other_review CHANGES_REQUESTED; } | jq -s . >"$REVIEWS"
  push
  [ "$status" -eq 0 ]
  skipped "nothing to recheck"
}

@test "push: skips a PR with no reviews" {
  push
  skipped "nothing to recheck"
}

@test "push: skips when recheck_on_push is off, without calling GitHub" {
  rc_review CHANGES_REQUESTED | jq -s . >"$REVIEWS"
  RECHECK_ON_PUSH=false push
  skipped "recheck_on_push is off"
  [ ! -s "$GHLOG" ]
}

@test "push: skips when the reviews can't be listed or parsed" {
  rm -f "$REVIEWS"
  push
  [ "$status" -eq 0 ]
  skipped "could not list"
  : >"$GITHUB_OUTPUT"
  printf 'not json\n' >"$REVIEWS"
  push
  [ "$status" -eq 0 ]
  skipped "could not read the PR's reviews"
}

@test "push: the PR checks still apply before the reviews are listed" {
  rc_review CHANGES_REQUESTED | jq -s . >"$REVIEWS"
  pr_json open true
  push
  skipped "is a draft"
  ! grep -qF '/reviews' "$GHLOG" || return 1
}
