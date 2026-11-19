#!/usr/bin/env bash
# Review Council CI gate (called by .github/actions/gate/action.yml).
# Inputs (env): GH_TOKEN EVENT_NAME EVENT_ACTION REPO PR_NUMBER COMMENT_ID
#               COMMENT_BODY COMMENTER RUN_BUDGET SKIP_BOT_PRS RECHECK_ON_PUSH
# Writes proceed / pr_number / head_ref / timeout_minutes / mode to
# $GITHUB_OUTPUT. mode is `full` (a whole council run) or `recheck` (only
# re-check the council's open comments).
set -euo pipefail

skip() { echo "Skipping: $1"; echo "proceed=false" >> "$GITHUB_OUTPUT"; exit 0; }

case "${PR_NUMBER:-}" in ''|*[!0-9]*) skip "no PR number on this event" ;; esac

# Mode. A comment's first word is /review-council (the workflow's pre-filter
# checks that); a second word `recheck` asks for a recheck only, anything else
# is a full run. Split on any whitespace, CR included (web comments use CRLF),
# with globbing off so a `*` in the comment stays text.
mode=full
if [ "$EVENT_NAME" = "issue_comment" ]; then
  set -f
  # shellcheck disable=SC2046 # deliberate word splitting
  set -- $(printf '%s' "${COMMENT_BODY:-}" | tr '\r\n\t' '   ')
  set +f
  if [ "${1:-}" = "/review-council" ] && [ "${2:-}" = "recheck" ]; then
    mode=recheck
  fi
elif [ "$EVENT_NAME" = "pull_request" ] && [ "${EVENT_ACTION:-}" = "synchronize" ]; then
  # A push never starts a full run: it rechecks, and only while one of our
  # reviews still requests changes (checked below, after the PR checks).
  [ "${RECHECK_ON_PUSH:-true}" = "true" ] || skip "recheck_on_push is off"
  mode=recheck
fi

if [ "$EVENT_NAME" = "issue_comment" ]; then
  perm_json="$(gh api "repos/$REPO/collaborators/$COMMENTER/permission")" \
    || skip "could not read the commenter's permission"
  perm="$(jq -r '.permission // ""' <<<"$perm_json")"
  role="$(jq -r '.role_name // ""' <<<"$perm_json")"
  case "$perm:$role" in
    admin:*|write:*|*:maintain) ;;
    *) skip "commenter lacks write/maintain/admin permission" ;;
  esac
fi

pr_json="$(gh api "repos/$REPO/pulls/$PR_NUMBER")" || skip "could not read PR #$PR_NUMBER"
state="$(jq -r '.state' <<<"$pr_json")"
draft="$(jq -r '.draft' <<<"$pr_json")"
head_repo="$(jq -r '.head.repo.full_name // ""' <<<"$pr_json")"
head_ref="$(jq -r '.head.ref' <<<"$pr_json")"

[ "$state" = "open" ] || skip "PR #$PR_NUMBER is not open"
[ "$draft" = "false" ] || skip "PR #$PR_NUMBER is a draft"
[ "$head_repo" = "$REPO" ] || skip "PR #$PR_NUMBER comes from a fork"
# Opt-in: bot-opened PRs (Dependabot, Renovate, an App's agent) can carry
# third-party text. Off by default, since reviewing agent PRs is a main use.
if [ "${SKIP_BOT_PRS:-false}" = "true" ] && [ "$(jq -r '.user.type // ""' <<<"$pr_json")" = "Bot" ]; then
  skip "PR #$PR_NUMBER was opened by a bot (skip_bot_prs)"
fi

# On a push, recheck only while one of our reviews still requests changes:
# state CHANGES_REQUESTED and the council's hidden marker in its body. A
# listing that fails or can't be parsed skips (the next push tries again).
if [ "$EVENT_NAME" = "pull_request" ] && [ "${EVENT_ACTION:-}" = "synchronize" ]; then
  reviews="$(gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/reviews")" \
    || skip "could not list the PR's reviews"
  active="$(jq -s '[.[][] | select(.state == "CHANGES_REQUESTED" and ((.body // "") | contains("<!-- rc:review -->")))] | length' <<<"$reviews")" \
    || skip "could not read the PR's reviews"
  [ "${active:-0}" -gt 0 ] || skip "nothing to recheck (no Review Council review requests changes)"
fi

# The 👀 reaction needs pull-requests: write (a PR comment), not issues: write.
if [ "$EVENT_NAME" = "issue_comment" ] && [ -n "${COMMENT_ID:-}" ]; then
  gh api --silent -X POST "repos/$REPO/issues/comments/$COMMENT_ID/reactions" \
    -f content=eyes || echo "::warning::could not react to the comment"
fi

# Review timeout: budget (rounded up to minutes) + headroom for Round 1
# (reviewer_timeout_seconds), setup, judging and posting.
# A recheck is one small model call: a flat 15 minutes.
if [ "$mode" = "recheck" ]; then
  timeout_min=15
else
  budget="${RUN_BUDGET:-}"
  case "$budget" in ''|*[!0-9]*) budget=900 ;; esac
  timeout_min=$(( (budget + 59) / 60 + 30 ))
fi

{
  echo "proceed=true"
  echo "pr_number=$PR_NUMBER"
  echo "head_ref=$head_ref"
  echo "timeout_minutes=$timeout_min"
  echo "mode=$mode"
} >> "$GITHUB_OUTPUT"
