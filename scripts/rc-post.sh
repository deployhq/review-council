#!/usr/bin/env sh
# rc-post.sh — deterministic plumbing for the Review Council PR-digest posting
# engine (Step 6.6 of skills/run/SKILL.md). Report-only by default; this script
# runs ONLY when the orchestrator has resolved `pr_comments.enabled=true` AND a
# human has confirmed the post.
#
# It performs the mechanical GitHub calls and NOTHING judgemental: the
# orchestrator composes the digest markdown (from the judge ledger + triage)
# and hands it over as a file; this script targets the PR and creates/updates
# the single marked comment. No LLM, no formatting decisions here.
#
# Subcommands:
#   detect                          Print the OPEN PR for the current branch as
#                                   `pr=<n>` / `url=<u>` / `head=<sha>`; `pr=`
#                                   (empty) when there is none. Exit 0 either way.
#   open-draft                      Open a DRAFT PR from the current branch
#                                   (pushing it first if needed). Refuses on the
#                                   default branch. Prints `url=<u>`.
#   post <pr> <body-file> [envname] Create or update (idempotent, singleton) the
#                                   digest comment on PR <pr> from <body-file>.
#                                   [envname] optionally NAMES an env var holding
#                                   a bot token; when that var is non-empty the
#                                   comment is posted as that identity, else as
#                                   the authenticated `gh` user.
#
# Idempotency: the digest carries a hidden marker (rc:report). `post` finds the
# most-recent comment bearing it and PATCHes it in place; only when none exists
# (or the update fails) does it create one — so re-runs never spam the PR.
#
# Fail-soft: every failure returns non-zero with a one-line stderr note and posts
# nothing further; the caller surfaces it. Posting never mutates the review.
#
# Requires: gh (authenticated), jq, git.

set -eu

MARKER='<!-- rc:report -->'
GH_POST_TOKEN=''  # set by `post` from the named env var; empty = ambient gh auth

# ---------------------------------------------------------------------------
# Identity: run gh with the posting token when one was resolved, else ambient.
# NEVER set GH_TOKEN to an empty string — gh would treat that as "authenticate
# with an empty token" and fail — so branch on whether a token is present.
# ---------------------------------------------------------------------------
gh_post() {
  if [ -n "$GH_POST_TOKEN" ]; then
    GH_TOKEN="$GH_POST_TOKEN" gh "$@"
  else
    gh "$@"
  fi
}

# resolve_token <envname>: echo the token to post with (empty => post as the gh
# user). <envname> is read via indirect expansion, so it is re-validated as a
# strict POSIX identifier here (defence in depth — rc-config.sh already guards
# it) before it ever reaches `eval`. An empty name, an invalid name, or an
# unset/empty target var all yield an empty token (user identity), never a fail.
resolve_token() {
  _rt_name="$1"
  [ -n "$_rt_name" ] || { printf ''; return 0; }
  case "$_rt_name" in
    *[!A-Za-z0-9_]* | [!A-Za-z_]*)
      echo "rc-post: ignoring invalid bot_token_env name '$_rt_name'; posting as the gh user" >&2
      printf ''
      return 0
      ;;
  esac
  eval "printf '%s' \"\${$_rt_name:-}\""
}

# ---------------------------------------------------------------------------
# detect: the open PR for the current branch (empty when there is none).
# ---------------------------------------------------------------------------
detect_pr() {
  _dp="$(gh pr view --json number,url,headRefOid,state 2>/dev/null)" || {
    printf 'pr=\n'
    return 0
  }
  _dp_state="$(printf '%s' "$_dp" | jq -r '.state // empty')"
  if [ "$_dp_state" = "OPEN" ]; then
    printf 'pr=%s\n' "$(printf '%s' "$_dp" | jq -r '.number')"
    printf 'url=%s\n' "$(printf '%s' "$_dp" | jq -r '.url')"
    printf 'head=%s\n' "$(printf '%s' "$_dp" | jq -r '.headRefOid')"
  else
    printf 'pr=\n'
  fi
}

# ---------------------------------------------------------------------------
# open-draft: create a draft PR from the current branch (after the human said
# yes). Refuses on the default branch; pushes an un-tracked branch first.
# ---------------------------------------------------------------------------
open_draft() {
  _od_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || {
    echo "rc-post: not a git repository" >&2
    return 1
  }
  _od_default="$(gh repo view --json defaultBranchRef 2>/dev/null | jq -r '.defaultBranchRef.name // empty')"
  if [ -n "$_od_default" ] && [ "$_od_branch" = "$_od_default" ]; then
    echo "rc-post: on the default branch ($_od_branch) — nothing to open a PR from" >&2
    return 2
  fi
  if ! git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    git push -u origin "HEAD:$_od_branch" >/dev/null 2>&1 || {
      echo "rc-post: could not push '$_od_branch' (no writable remote?)" >&2
      return 3
    }
  fi
  _od_url="$(gh pr create --draft --fill 2>/dev/null)" || {
    echo "rc-post: 'gh pr create --draft' failed" >&2
    return 4
  }
  printf 'url=%s\n' "$_od_url"
}

# ---------------------------------------------------------------------------
# post <pr> <body-file> [envname]: idempotent single-comment upsert.
# ---------------------------------------------------------------------------
do_post() {
  _pr="${1:?rc-post: post needs <pr-number>}"
  _body="${2:?rc-post: post needs <body-file>}"
  _tokname="${3:-}"

  # Defence in depth: the PR number is meant to come from `detect` (a GitHub
  # integer), but this is called from an LLM-composed template — require it to be
  # purely numeric so it can never reshape the REST path.
  case "$_pr" in
    '' | *[!0-9]*)
      echo "rc-post: invalid PR number '$_pr' (must be digits)" >&2
      return 1
      ;;
  esac
  [ -f "$_body" ] || {
    echo "rc-post: body file not found: $_body" >&2
    return 1
  }
  # Only ever post an actual Review Council digest: require the idempotency marker
  # in the body. A deterministic backstop against a coerced orchestrator being
  # talked into posting some other file's contents.
  grep -qF -- "$MARKER" "$_body" || {
    echo "rc-post: refusing to post — body is not a Review Council digest (missing $MARKER)" >&2
    return 1
  }

  GH_POST_TOKEN="$(resolve_token "$_tokname")"

  _repo="$(gh repo view --json nameWithOwner 2>/dev/null | jq -r '.nameWithOwner // empty')"
  [ -n "$_repo" ] || {
    echo "rc-post: could not resolve owner/repo (gh not authenticated?)" >&2
    return 1
  }

  # Who we post as. Used to only ever update OUR OWN prior comment: the marker is
  # a public string, so without this a third party could plant a marked comment
  # and get it edited under our token (or force an endless spam loop). If the
  # identity can't be resolved (e.g. a GitHub App installation token cannot call
  # /user), fall back to matching only BOT-authored comments — on that path we are
  # a bot, and a human attacker's planted comment is type "User", so it's ignored.
  _me="$(gh_post api user 2>/dev/null | jq -r '.login // empty' 2>/dev/null)" || _me=""

  # List existing comments. A FAILED list must NOT look like an empty list: if we
  # can't read the comments we must not create a new one (that would duplicate an
  # existing digest). Capture the listing and its exit status separately.
  if ! _comments="$(gh_post api --paginate "repos/$_repo/issues/$_pr/comments" 2>/dev/null)"; then
    echo "rc-post: could not list comments on PR $_pr; not posting (avoids a duplicate)" >&2
    return 1
  fi

  # Newest OUR-authored comment bearing the marker, by comment id (monotonic, so
  # independent of API/pagination ordering). `arrays` tolerates a mixed page (an
  # error object among array pages) without a jq type error.
  # `2>/dev/null` + `|| _id=""`: a malformed response (jq parse error) must degrade
  # to "no match" / fail-soft, never abort the script under `set -e`.
  _id="$(printf '%s' "$_comments" | jq -s --arg m "$MARKER" --arg me "$_me" '
    [ .[] | arrays | .[]
      | select(.body != null and (.body | contains($m))
          and (if $me == "" then (.user.type == "Bot") else (.user.login == $me) end)) ]
    | max_by(.id) | .id // empty' 2>/dev/null)" || _id=""

  if [ -n "$_id" ]; then
    if _url="$(jq -Rs '{body: .}' "$_body" \
      | gh_post api "repos/$_repo/issues/comments/$_id" -X PATCH --input - 2>/dev/null \
      | jq -r '.html_url // empty' 2>/dev/null)" && [ -n "$_url" ]; then
      printf 'action=updated\nurl=%s\n' "$_url"
      return 0
    fi
    echo "rc-post: could not update comment $_id; posting a fresh one" >&2
  fi

  # Guard with `|| _url=""` so a non-zero POST/parse never trips `set -e` before
  # the clean fail-soft return below.
  _url="$(jq -Rs '{body: .}' "$_body" \
    | gh_post api "repos/$_repo/issues/$_pr/comments" -X POST --input - 2>/dev/null \
    | jq -r '.html_url // empty' 2>/dev/null)" || _url=""
  [ -n "$_url" ] || {
    echo "rc-post: posting the digest comment failed" >&2
    return 1
  }
  printf 'action=created\nurl=%s\n' "$_url"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
_cmd="${1:-}"
[ "$#" -gt 0 ] && shift || true
case "$_cmd" in
  detect) detect_pr "$@" ;;
  open-draft) open_draft "$@" ;;
  post) do_post "$@" ;;
  *)
    echo "usage: rc-post.sh <detect | open-draft | post <pr> <body-file> [envname]>" >&2
    exit 2
    ;;
esac
