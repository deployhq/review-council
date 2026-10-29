#!/usr/bin/env bash
# Review Council CI gate (called by .github/actions/gate/action.yml).
# Inputs (env): GH_TOKEN EVENT_NAME REPO PR_NUMBER COMMENT_ID COMMENTER RUN_BUDGET
# Writes proceed / pr_number / head_ref / timeout_minutes to $GITHUB_OUTPUT.
set -euo pipefail

skip() { echo "Skipping: $1"; echo "proceed=false" >> "$GITHUB_OUTPUT"; exit 0; }

case "${PR_NUMBER:-}" in ''|*[!0-9]*) skip "no PR number on this event" ;; esac

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

if [ "$EVENT_NAME" = "issue_comment" ] && [ -n "${COMMENT_ID:-}" ]; then
  gh api --silent -X POST "repos/$REPO/issues/comments/$COMMENT_ID/reactions" \
    -f content=eyes || echo "::warning::could not react to the comment"
fi

# Review timeout: budget (rounded up to minutes) + headroom for Round 1
# (reviewer_timeout_seconds), setup, judging and posting.
budget="${RUN_BUDGET:-}"
case "$budget" in ''|*[!0-9]*) budget=900 ;; esac
timeout_min=$(( (budget + 59) / 60 + 30 ))

{
  echo "proceed=true"
  echo "pr_number=$PR_NUMBER"
  echo "head_ref=$head_ref"
  echo "timeout_minutes=$timeout_min"
} >> "$GITHUB_OUTPUT"
