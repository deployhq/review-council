#!/usr/bin/env sh
# rc-post.sh — deterministic plumbing for the Review Council PR-digest posting
# engine (Step 6.6 of skills/run/SKILL.md). Report-only by default; this script
# runs ONLY when the orchestrator has resolved `pr_comments.enabled=true` AND a
# human has confirmed the post.
#
# It performs the mechanical GitHub calls and NOTHING judgemental: the
# orchestrator composes the digest markdown (from the judge ledger + triage)
# and writes the ledger JSON; this script places each finding on the diff (or
# not), renders the inline comments, and posts one review per run that carries
# the summary. No LLM here.
#
# Subcommands:
#   detect                          Print the OPEN PR for the current branch as
#                                   `pr=<n>` / `url=<u>` / `head=<sha>`; `pr=`
#                                   (empty) when there is none. Exit 0 either way.
#   open-draft                      Open a DRAFT PR from the current branch
#                                   (pushing it first if needed). Refuses on the
#                                   default branch. Prints `url=<u>`.
#   post <pr> <body-file> [envname] Create or update (idempotent, singleton) the
#                                   digest comment on PR <pr> from <body-file>
#                                   (used when there is no ledger).
#                                   [envname] optionally NAMES an env var holding
#                                   a bot token; when that var is non-empty the
#                                   comment is posted as that identity, else as
#                                   the authenticated `gh` user.
#   review <pr> <digest-file> <ledger> [envname] [recheck-file]
#                                   Post one review: the summary (the digest),
#                                   the findings not on the diff, and an inline
#                                   comment per finding on the diff ("request
#                                   changes" on a critical/important finding);
#                                   resolve the re-checked fixed ones first.
#                                   See the `review / stale` section below.
#   stale <pr> <ledger> [envname]   Print (JSON) our open inline comments whose
#                                   finding this run no longer reports.
#   open <pr> [envname]             Print (JSON) the council's state on the PR:
#                                   our inline comments and outside-the-diff
#                                   findings with a status each, our active
#                                   "request changes" reviews, what blocks them
#                                   and what a person acknowledged. See the
#                                   `open / recheck` section below.
#   recheck <pr> <verdicts> [envname]
#                                   Act on a recheck's verdicts: reply "looks
#                                   fixed" (and resolve) on the fixed inline
#                                   comments, one PR comment for the fixed
#                                   outside-the-diff findings, and dismiss our
#                                   "request changes" when nothing blocking is
#                                   left. Never posts a review or new findings.
#   identity [envname]              Print `identity=<who we post as>`.
#   redact                          Read text on stdin, write it to stdout with
#                                   likely secrets replaced by [REDACTED]; the
#                                   count goes to stderr only. Non-zero exit (and
#                                   no stdout) if redaction itself fails. Same
#                                   implementation `post` uses.
#
# Idempotency: the digest carries a hidden marker (rc:report). `post` finds the
# most-recent comment bearing it and PATCHes it in place; only when none exists
# (or the update fails) does it create one — so re-runs never spam the PR.
# Everything posted ends with the same footer (resolve_identity).
#
# Fail-soft: every failure returns non-zero with a one-line stderr note and posts
# nothing further; the caller surfaces it. Posting never mutates the review.
#
# Env: RC_PR_REQUEST_CHANGES (`review`) — `true` (default; unset/empty too):
# a critical/important finding posts the review as "request changes".
# `false`: always a plain comment (an earlier "request changes" of ours can
# still be dismissed by a clean run). Any other value: a stderr note, then
# `true`. Read from the environment only, never from config (committed config
# is untrusted, so a reviewed PR must not be able to turn the block off).
# RC_PLAN_OUT (`review`) — a file path: `review` writes {"head", "status",
# "block", "reported", "posted"} there (posted false until the run posted), for
# the recheck that follows a full run in CI.
#
# Requires: gh (authenticated), jq, git.

set -eu

MARKER='<!-- rc:report -->'

# Likely-secret shapes redacted from the digest before it is posted (the body is
# model-composed from review context, which may quote a credential). One
# Oniguruma regex for jq: Anthropic sk-ant-, OpenRouter sk-or-, OpenAI
# sk-proj-/sk-svcacct-/sk-admin- and legacy sk-<32+ alnum>, GitHub
# ghp_/gho_/ghs_/ghu_/ghr_ and github_pat_, Perplexity pplx-, AWS access key ids
# AKIA/ASIA, Google AIza, Slack xox[abpr]-, Stripe sk_live_/rk_live_, JWTs
# (OAuth/OIDC/access tokens, e.g. a Codex access token's login file), and PEM
# private key blocks (the whole block when its END line is there). The
# lookbehind/lookahead keep it to whole tokens; `_` is NOT in the
# lookbehind so a token wrapped in markdown italics (`_sk-ant-..._`) is still
# caught. The length floors keep ordinary text ("sk-learn", a 40-hex SHA) out.
SECRET_RE='(?<![A-Za-z0-9-])(?:sk-(?:ant|or|proj|svcacct|admin)-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|pplx-[A-Za-z0-9]{32,}|(?:AKIA|ASIA)[0-9A-Z]{16}(?![0-9A-Za-z])|AIza[0-9A-Za-z_-]{35}|xox[abpr]-[A-Za-z0-9-]{10,}|[sr]k_live_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----(?:[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----)?)'
GH_POST_TOKEN=''  # set by `post` from the named env var; empty = ambient gh auth

# ---------------------------------------------------------------------------
# redact_file <in> <out>: write <in> to <out> with every SECRET_RE match replaced
# by [REDACTED], byte-for-byte otherwise (jq -j: no added newline). Sets
# _RED_N to the match count. Returns non-zero if the scan or the rewrite fails —
# callers must then treat the text as unvetted. The ONE redaction implementation:
# `post` and the `redact` subcommand both go through here.
# ---------------------------------------------------------------------------
redact_file() {
  _RED_N="$(jq -Rrs --arg re "$SECRET_RE" '[match($re; "g")] | length' "$1" 2>/dev/null)" || _RED_N=""
  [ -n "$_RED_N" ] || return 1
  jq -Rjs --arg re "$SECRET_RE" 'gsub($re; "[REDACTED]")' "$1" >"$2" 2>/dev/null || return 1
}

# redact: stdin -> stdout, count -> stderr. Output is only released once the
# whole redaction succeeded, so a failure never leaks unredacted text.
do_redact() {
  _rd_in="$(mktemp "${TMPDIR:-/tmp}/rc-redact-in.XXXXXX")" || {
    echo "rc-post: could not create a temp file; not redacting" >&2
    return 1
  }
  _rd_out="$(mktemp "${TMPDIR:-/tmp}/rc-redact-out.XXXXXX")" || {
    rm -f "$_rd_in"
    echo "rc-post: could not create a temp file; not redacting" >&2
    return 1
  }
  trap 'rm -f "$_rd_in" "$_rd_out"' EXIT
  cat >"$_rd_in" || {
    echo "rc-post: could not read stdin; not redacting" >&2
    return 1
  }
  redact_file "$_rd_in" "$_rd_out" || {
    echo "rc-post: redaction failed; no output" >&2
    return 1
  }
  cat "$_rd_out"
  echo "rc-post: redacted $_RED_N likely secret(s)" >&2
}

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

  # Redact likely secrets into the request payload ({"body": ...}) — redact and
  # post, never refuse (fail-soft); the note carries the count only, never a
  # value. If redaction itself fails we cannot vouch for the body: don't post.
  _payload="$(mktemp "${TMPDIR:-/tmp}/rc-post.XXXXXX")" || {
    echo "rc-post: could not create a temp file; not posting" >&2
    return 1
  }
  _redacted="$(mktemp "${TMPDIR:-/tmp}/rc-post-red.XXXXXX")" || {
    rm -f "$_payload"
    echo "rc-post: could not create a temp file; not posting" >&2
    return 1
  }
  trap 'rm -f "$_payload" "$_redacted"' EXIT
  if ! redact_file "$_body" "$_redacted" \
    || ! jq -Rs '{body: .}' "$_redacted" >"$_payload" 2>/dev/null; then
    echo "rc-post: could not scan the digest for secrets; not posting" >&2
    return 1
  fi
  if [ "$_RED_N" != 0 ]; then
    echo "rc-post: redacted $_RED_N likely secret(s) from the digest before posting" >&2
  fi

  GH_POST_TOKEN="$(resolve_token "$_tokname")"

  _repo="$(gh repo view --json nameWithOwner 2>/dev/null | jq -r '.nameWithOwner // empty')"
  [ -n "$_repo" ] || {
    echo "rc-post: could not resolve owner/repo (gh not authenticated?)" >&2
    return 1
  }
  resolve_identity
  if ! jq --arg f "$_footer" '.body += "\n\n" + $f' "$_payload" >"$_redacted" \
    || ! mv "$_redacted" "$_payload"; then
    echo "rc-post: could not add the footer; not posting" >&2
    return 1
  fi
  upsert_digest "$_pr" "$_payload" || return 1
  printf 'action=%s\nurl=%s\n' "$_DG_ACTION" "$_DG_URL"
}

# ---------------------------------------------------------------------------
# identity [envname]: print who we would post as (identity=<text>, empty when
# unknown), for the person to check before anything is posted.
# ---------------------------------------------------------------------------
do_identity() {
  GH_POST_TOKEN="$(resolve_token "${1:-}")"
  resolve_identity
  printf 'identity=%s\n' "$_who"
}

# ---------------------------------------------------------------------------
# resolve_identity: who we post as (needs GH_POST_TOKEN set). Sets _me (login,
# empty when unreadable) and _fb_login (the only Bot login to match then).
# Used to only ever touch OUR OWN prior comments: the markers are public
# strings, so without this a third party could plant a marked comment and get
# it edited under our token (or force an endless spam loop). If the identity
# can't be resolved (e.g. a GitHub App installation token cannot call /user),
# fall back to matching only BOT-authored comments — on that path we are a bot,
# and a human attacker's planted comment is type "User", so it's ignored. Under
# GitHub Actions with no bot token we post as the Actions token, so narrow
# further to login `github-actions[bot]`.
# ---------------------------------------------------------------------------
resolve_identity() {
  _me="$(gh_post api user 2>/dev/null | jq -r '.login // empty' 2>/dev/null)" || _me=""
  _fb_login=""
  if [ -z "$_me" ] && [ "${GITHUB_ACTIONS:-}" = true ] && [ -z "$GH_POST_TOKEN" ]; then
    _fb_login='github-actions[bot]'
  elif [ -z "$_me" ] && [ -n "$GH_POST_TOKEN" ] && [ -n "${RC_PR_BOT_LOGIN:-}" ]; then
    # A bot token (e.g. an App's) can't read /user: the caller names its login
    # (trusted env). Same charset as a GitHub login, optional `[bot]`.
    # One line only: grep -x matches line by line, so reject newlines first.
    if [ "$(printf '%s' "$RC_PR_BOT_LOGIN" | wc -l | tr -d ' ')" = 0 ] \
      && printf '%s' "$RC_PR_BOT_LOGIN" | grep -Eqx '[A-Za-z0-9][A-Za-z0-9-]{0,38}(\[bot\])?'; then
      _fb_login="$RC_PR_BOT_LOGIN"
    else
      echo "rc-post: ignoring invalid RC_PR_BOT_LOGIN" >&2
    fi
  fi
  # Unknown = any Bot could be us: then we never resolve or dismiss anything.
  _known=true
  [ -n "$_me" ] || [ -n "$_fb_login" ] || _known=false
  # The sign-off on everything we post. Locally, with no bot token, we post as
  # the person's own account, so say it is automated.
  if [ -z "$GH_POST_TOKEN" ] && [ "${GITHUB_ACTIONS:-}" != true ] && [ -n "$_me" ]; then
    _who="posted by @$_me (not a personal comment)"
  else
    _who="${_me:-$_fb_login}"
  fi
  _footer="---

<sub>Review done with [Review Council](https://github.com/deployhq/review-council/)${_who:+ · $_who}</sub>"
}

# ---------------------------------------------------------------------------
# upsert_digest <pr> <payload-file> [update-only]: create or update the
# singleton digest comment from a ready ({"body": ...}, already redacted)
# payload; with update-only, never create one. Needs _repo, _me, _fb_login.
# Sets _DG_ACTION (created|updated) and _DG_URL.
# ---------------------------------------------------------------------------
upsert_digest() {
  # List existing comments. A FAILED list must NOT look like an empty list: if we
  # can't read the comments we must not create a new one (that would duplicate an
  # existing digest). Capture the listing and its exit status separately.
  if ! _comments="$(gh_post api --paginate "repos/$_repo/issues/$1/comments" 2>/dev/null)"; then
    echo "rc-post: could not list comments on PR $1; not posting (avoids a duplicate)" >&2
    return 1
  fi

  # Newest OUR-authored comment bearing the marker, by comment id (monotonic, so
  # independent of API/pagination ordering). The Bot fallback also requires the
  # body to START with the marker (our digest always does; a bot quoting it
  # mid-text does not). `arrays` tolerates a mixed page (an error object among
  # array pages) without a jq type error.
  # `2>/dev/null` + `|| _id=""`: a malformed response (jq parse error) must degrade
  # to "no match" / fail-soft, never abort the script under `set -e`.
  _id="$(printf '%s' "$_comments" | jq -s --arg m "$MARKER" --arg me "$_me" --arg fb "$_fb_login" '
    [ .[] | arrays | .[]
      | select((.body | type) == "string"
          and (if $me != "" then (.user.login == $me and (.body | contains($m)))
               else (.user.type == "Bot" and (.body | startswith($m))
                     and ($fb == "" or .user.login == $fb)) end)) ]
    | max_by(.id) | .id // empty' 2>/dev/null)" || _id=""

  if [ -n "$_id" ]; then
    if _DG_URL="$(gh_post api "repos/$_repo/issues/comments/$_id" -X PATCH --input - <"$2" 2>/dev/null \
      | jq -r '.html_url // empty' 2>/dev/null)" && [ -n "$_DG_URL" ]; then
      _DG_ACTION=updated
      return 0
    fi
    if [ "${3:-}" = update-only ]; then
      echo "rc-post: could not update comment $_id" >&2
      return 1
    fi
    echo "rc-post: could not update comment $_id; posting a fresh one" >&2
  fi
  [ "${3:-}" != update-only ] || return 1

  # Guard with `|| _DG_URL=""` so a non-zero POST/parse never trips `set -e`
  # before the clean fail-soft return below.
  _DG_URL="$(gh_post api "repos/$_repo/issues/$1/comments" -X POST --input - <"$2" 2>/dev/null \
    | jq -r '.html_url // empty' 2>/dev/null)" || _DG_URL=""
  [ -n "$_DG_URL" ] || {
    echo "rc-post: posting the digest comment failed" >&2
    return 1
  }
  _DG_ACTION=created
}

# ---------------------------------------------------------------------------
# review / stale: inline review comments + the digest, tracked across runs.
#
# Input is the judge's ledger (skills/run/SKILL.md §5.7): a JSON object in the
# `review-council/ledger` v1 shape, of which this script reads
#   .findings[] | {fingerprint, outcome, section, severity, badge, title, issue,
#                  why_it_matters, recommendation, how_to_verify, origins[].reviewer,
#                  location: {path, line, line_end, code}}
# Everything in it is model-composed, so it is DATA: this script decides where a
# finding goes, renders it, and builds every request with jq. A reported
# finding goes inline only when its path is a file in the PR's diff (GitHub's
# own list) and its line is a right-side line of one of that file's hunks;
# before that, a finding with `location.code` (the exact text of its first
# line) is moved to where that text is in the file at the reviewed commit:
# the line it names if the text is there, else the nearest line holding it
# (an exact match, whitespace collapsed, before a substring one), else no line
# at all. Model-reported line numbers can be off; the text is checked here.
# Everything else goes to the review's "Outside the diff" section (at the
# digest's placeholder line `<!-- rc:inline -->`, else at the end). The review
# body is the digest: a review per run, no separate summary comment (that is
# only the fallback when GitHub accepts no review).
#
# Tracking: each inline comment ends with `<!-- rc:finding <fingerprint> -->`.
# A finding that already has one of OUR comments is left alone (not reposted,
# not edited). Our unresolved comments whose finding is no longer reported are
# "stale": `stale` lists them for the orchestrator to re-check, and `review`
# resolves only the ones the re-check marked fixed — and only those that are
# still stale when it runs. Nothing is resolved or dismissed on a `degraded`
# run (rc:state line): a reviewer that failed reports nothing, not "fixed".
#
# Blocking: when any reported finding is critical or important, the review is
# posted as "request changes" (once — not again while ours is still active;
# never with RC_PR_REQUEST_CHANGES=false);
# when none is, our earlier "request changes" reviews are dismissed, unless
# one of our critical/important comments is still open and the re-check
# didn't mark it fixed. If a person dismisses ours, the findings it listed
# never request changes again.
# ---------------------------------------------------------------------------
INLINE_MARK='<!-- rc:inline -->'
MAX_INLINE=50

# Right-side (commentable) line numbers per hunk, per file, from the
# `pulls/<n>/files` pages: {"<path>": [[12,13,14], [40,41]], ...}. A file
# without a `patch` (binary, too large) has no hunks, so nothing anchors there.
# shellcheck disable=SC2016  # jq program, not shell
DIFFMAP_JQ='
  [ .[] | arrays | .[] | select((.filename | type) == "string" and (.patch | type) == "string") ]
  | map({key: .filename, value: (
      .patch | split("\n")
      | reduce .[] as $l ({h: [], r: 0};
          if ($l | startswith("@@")) then
            ($l | capture("^@@ -[0-9]+(,[0-9]+)? \\+(?<s>[0-9]+)") | .s | tonumber) as $s
            | .r = $s | .h += [[]]
          elif (.h | length) == 0 or $l == "" or ($l | startswith("-")) or ($l | startswith("\\")) then .
          else .h[(.h | length) - 1] += [.r] | .r += 1
          end)
      | .h)})
  | from_entries'

# Our earlier inline comments: root comments by us that carry a finding marker,
# joined with their review thread ({id, resolved, by} from GraphQL, null if
# unknown), each with a status:
#   fixed    — we replied "looks fixed" (`rc:fixed`, either variant) and nobody
#              reopened it;
#   reopened — we replied "looks fixed", then a person unresolved the thread we
#              had resolved (`rc:fixed resolved`), or replied after us;
#   resolved_by_person — the thread is resolved by a person (resolvedBy is not
#              us, null = not a person) and was not answered "looks fixed", or
#              a person resolved it after replying to our unresolved "looks
#              fixed". A thread we resolved (`rc:fixed resolved`) that is
#              resolved now is fixed whoever resolvedBy names (or reopened if a
#              person replied after us): our own resolve must never read as a
#              person's acknowledgement;
#   resolved — the thread is resolved otherwise (by us);
#   open     — anything else, including an unknown thread state.
# `fixed` (bool) = status fixed: a finding that comes back gets a new comment.
# A person = a User other than the identity we post as (as for dismissals).
# shellcheck disable=SC2016  # jq program, not shell
OURS_JQ='
  def ours: if $me != "" then .user.login == $me
            else (.user.type == "Bot" and ($fb == "" or .user.login == $fb)) end;
  ([ $t[0][] | .data.repository.pullRequest.reviewThreads.nodes[]? ]
   | map({key: (.comments.nodes[0].databaseId | tostring),
          value: {id: .id, resolved: .isResolved, by: (.resolvedBy.login? // null)}})
   | from_entries) as $th
  | [ .[] | arrays | .[] | select((.body | type) == "string") ] as $all
  | [ $all[] | select(ours) ] as $mine
  | [ $mine[] | select(.in_reply_to_id == null)
      | (.body | capture("<!-- rc:finding (?<fp>[A-Za-z0-9._:/@+-]{1,200}) -->\\s*$") .fp) as $fp
      | .id as $rid
      | $th[$rid | tostring] as $thr
      # Our latest "looks fixed" reply (old `rc:fixed` and new `rc:fixed resolved`).
      | ([ $mine[] | select(.in_reply_to_id == $rid and (.body | contains("<!-- rc:fixed"))) ] | max_by(.id)) as $fx
      | ($fx != null and any($all[]; .in_reply_to_id == $rid and (.id | type) == "number" and .id > $fx.id
                             and .user.type == "User" and (ours | not))) as $replied
      | ($fx != null and ($fx.body | contains("<!-- rc:fixed resolved -->"))) as $weresolved
      | ($thr != null and ($thr.by | type) == "string" and $thr.by != "" and $thr.by != $me and $thr.by != $fb) as $byperson
      | (if $thr != null and $thr.resolved == true then
           (if $fx == null then (if $byperson then "resolved_by_person" else "resolved" end)
            # We resolved it (`rc:fixed resolved`): resolvedBy is never trusted
            # (a bot token may resolve under another login), so it stays fixed
            # unless a person replied after us.
            elif $weresolved then (if $replied then "reopened" else "fixed" end)
            elif $byperson and $replied then "resolved_by_person"
            elif $replied then "reopened"
            else "fixed" end)
         elif $fx != null then
           (if $replied or ($weresolved and $thr != null and $thr.resolved == false) then "reopened" else "fixed" end)
         else "open" end) as $st
      | {id, fp: $fp, path, line: (.line // .original_line), body, url: (.html_url // null), thread: $thr,
         status: $st, fixed: ($st == "fixed"),
         severity: (.body | if startswith("**🔴 Critical**") then "critical"
                            elif startswith("**🟠 Important**") then "important"
                            elif startswith("**🟡 Suggestion**") then "suggestion" else "unknown" end)} ]'

# Shared jq definitions: the ledger's reported findings, normalised.
# shellcheck disable=SC2016  # jq program, not shell
LEDGER_DEFS='
  def str: type == "string" and . != "";
  def posint: type == "number" and . == floor and . > 0 and . < 10000000;
  # Model text: no hidden markers, no secrets (redacted here, before JSON
  # encoding, so a secret at the start of a line is still caught), and no
  # live @mentions outside code spans (a zero-width space after the @).
  def clean: tostring | gsub("\r"; "") | gsub("<!--"; "&lt;!--") | gsub($re; "[REDACTED]")
    | [splits("`")] | to_entries
    | map(if .key % 2 == 0 then .value | gsub("@(?<c>[A-Za-z0-9_])"; "@\u200b\(.c)") else .value end)
    | join("`");
  def oneline: clean | gsub("\n+"; " ") | .[0:300];
  def reported:
    (if type == "object" then .findings else null end) | if type == "array" then . else [] end
    | map(select(type == "object" and .outcome == "reported" and ((.section // "main") == "main")
                 and (.title | str)))
    # Fingerprints are normalised to the marker charset, the same way every
    # run, so any judge fingerprint can be tracked.
    | map(. + {fingerprint: (.fingerprint | if type == "string" then gsub("[^A-Za-z0-9._:/@+-]"; "-") | .[0:200] else null end)})
    | map(. + {
        path: (.location.path // null),
        line: (if (.location.line_end | posint) then .location.line_end else .location.line end),
        start_line: .location.line,
        tracked: ((.fingerprint | type) == "string" and (.fingerprint | test("^[A-Za-z0-9._:/@+-]{1,200}$")))});
'

# The "looks fixed" texts (needs LEDGER_DEFS). $why: {summary, points} written
# by a model (or null): through `clean`, summary <= 300 chars, <= 5 points of
# <= 300 chars, so it can never carry a marker, a secret or a live @mention.
# shellcheck disable=SC2016  # jq program, not shell
REPLY_DEFS='
  # An odd backtick count would leave an unclosed "code span" that `clean`
  # skips but GitHub renders as text (a live @mention): drop them then.
  def rtext: tostring | (if ([match("`"; "g")] | length) % 2 == 1 then gsub("`"; "") else . end) | oneline;
  def whysum($why; $dflt):
    (if ($why | type) == "object" and ($why.summary | type) == "string" then $why.summary | rtext else "" end)
    | if . == "" then $dflt else . end;
  def whydetails($why):
    [ (if ($why | type) == "object" and ($why.points | type) == "array" then $why.points[] else empty end)
      | strings | rtext | select(. != "") ][0:5]
    | if length == 0 then ""
      else "\n\n<details>\n<summary>Why we think it\u0027s fixed</summary>\n\n"
           + (map("- " + .) | join("\n")) + "\n\n</details>" end;
  def signoff($who): "<sub>Recheck by [Review Council](https://github.com/deployhq/review-council/)"
    + (if $who != "" then " · " + $who else "" end);
  # The inline reply: $resolved = whether we resolved the thread.
  def fixedreply($why; $short; $resolved; $who; $dflt):
    "**Looks fixed** at `" + $short + "` · rechecked by Review Council\n\n" + whysum($why; $dflt) + whydetails($why)
    + "\n\n" + signoff($who) + " · Disagree? "
    + (if $resolved then "Unresolve this conversation" else "Reply here" end)
    + " and the council will treat it as still open.</sub>\n\n"
    + (if $resolved then "<!-- rc:fixed resolved -->" else "<!-- rc:fixed -->" end);
'

# The plan: what to post, list outside the diff, and resolve.
# shellcheck disable=SC2016  # jq program, not shell
PLAN_JQ='
  def norm: gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");
  def dist($a; $b): ($a - $b) | if . < 0 then -. else . end;
  # Re-anchor on location.code against $src[0] ({path: [lines]} at the
  # reviewed commit); see the header above.
  def relocate:
    (if (.path | str) then $src[0][.path] else null end) as $ls
    | if ($ls | type) != "array" or (.location.code | str | not) then .
      else (.location.code | split("\n")[0] | norm) as $c
      | if $c == "" then .
        else ([range(0; $ls | length) | select(($ls[.] | norm) == $c) | . + 1]) as $eq
        | (if ($eq | length) > 0 then $eq
           elif ($c | length) >= 8 then [range(0; $ls | length) | select($ls[.] | norm | contains($c)) | . + 1]
           else [] end) as $m
        | (if (.start_line | posint) then .start_line elif (.line | posint) then .line else null end) as $s
        | if ($m | length) == 0 then . + {start_line: null, line: null}
          elif $s != null and ($m | index($s)) != null then .
          elif $s == null then . + {start_line: $m[0], line: $m[0]}
          else ($m | min_by(dist(.; $s))) as $t
          | . + {start_line: $t, line: (if (.line | posint) then .line + $t - $s else $t end)}
          end
        end
      end;
  def sevlabel: {critical: "🔴 Critical", important: "🟠 Important", suggestion: "🟡 Suggestion"}[.] // "Finding";
  def fence($t): ([$t | match("`+"; "g") | .length] | max // 0) as $m | "`" * ([$m + 1, 3] | max);
  def lines: if (.start_line | posint) and (.line | posint) and .start_line < .line
             then "\(.start_line)-\(.line)" elif (.line | posint) then "\(.line)" else null end;
  def loc:
    if (.path | str) then "`" + (.path | oneline | gsub("`"; "")) + (lines as $l | if $l then ":" + $l else "" end) + "`"
    else "no location" end;
  def render:
    ([ (.issue | select(str) | clean),
       (.why_it_matters | select(str) | "**Why it matters:** " + clean),
       (.recommendation | select(str) | "**Fix:** " + clean) ] | join("\n\n")) as $text
    | ([ "In " + loc + ":", (.issue | select(str) | clean), (.recommendation | select(str) | clean),
         (.how_to_verify | select(str) | "Verify: " + clean) ] | join("\n")) as $p
    | fence($p) as $fc
    | ([.origins[]?.reviewer | select(str) | oneline] | unique | join(", ")) as $by
    | ("**" + ((.severity | tostring) | sevlabel) + "**"
       + (if (.badge | str) then " · " + (.badge | oneline | gsub("`"; "") | if startswith("[") then . else "[" + . + "]" end | "`" + . + "`") else "" end)
       + (if $by != "" then " · found by " + $by else "" end)
       + "\n\n**" + (.title | oneline) + "**"
       + (if $text != "" then "\n\n" + $text else "" end)
       + "\n\n<details>\n<summary>🤖 Prompt for AI agents</summary>\n\n" + $fc + "text\n" + $p + "\n" + $fc + "\n\n</details>")[0:60000];
  def anchor:
    (if (.path | type) == "string" then $d[0][.path] else null end) as $hs
    | if ($inline | not) or $hs == null or (.line | posint | not) then null
      else .line as $l
      | (if (.start_line | posint) then .start_line else $l end) as $s0
      | ([$hs[] | select(any(.[]; . == $l))] | first) as $h
      | if $h != null then
          (if $s0 < $l and any($h[]; . == $s0)
           then {start_line: $s0, start_side: "RIGHT", line: $l, side: "RIGHT"}
           else {line: $l, side: "RIGHT"} end)
        elif ([$hs[] | select(any(.[]; . == $s0))] | first) != null then {line: $s0, side: "RIGHT"}
        else null end
      end;

  reported
  | map(relocate)
  # One comment per fingerprint: a repeated fingerprint is listed, not tracked.
  | reduce .[] as $x ({seen: {}, out: []};
      if $x.tracked and .seen[$x.fingerprint] then .out += [$x + {tracked: false}]
      elif $x.tracked then .seen[$x.fingerprint] = true | .out += [$x]
      else .out += [$x] end)
  | .out
  | map(. + {md: render, loc: loc})
  # A finding with one of our comments that is not "fixed" (open, reopened or
  # resolved) is not posted again; a fixed one that comes back is.
  | ([$ex[0][] | select(.fixed | not) | .fp] + ($cov | map(tostring))) as $have
  | map(. as $x | . + {have: ($x.tracked and ($have | index($x.fingerprint)) != null)}) as $fs
  | [ $fs[] | select((.have | not) and .tracked) | . + {a: anchor} | select(.a != null) ] as $cand
  | ([$fs[] | select(.tracked) | .fingerprint]) as $fps
  # Outside-the-diff entries: the text, and the fingerprint for the
  # `rc:outside` marker (null = untracked: listed without a marker).
  | def outent: {fp: (if .tracked then .fingerprint else null end), md: (.loc + "\n\n" + .md)};
  {
      block: any($fs[]; .severity == "critical" or .severity == "important"),
      blocking: [ $fs[] | select(.severity == "critical" or .severity == "important") | if .tracked then .fingerprint else "" end ],
      reported: ($fps | unique),
      kept: ([$fs[] | select(.have)] | length),
      new: [ $cand[0:$maxn][] | .a + {path, body: (.md + "\n\n" + $footer + "\n\n<!-- rc:finding " + .fingerprint + " -->"),
                                      outside: outent} ],
      outside: ([ $fs[] | select(.have | not) | select(. as $x | any($cand[0:$maxn][]; .fingerprint == $x.fingerprint) | not)
                  | outent ]),
      # Only an open comment is re-checked: a reopened one never is again.
      stale: [ $ex[0][] | select((.fp as $fp | $fps | index($fp)) == null and .status == "open"
                                 and .thread != null and .thread.resolved == false) ],
    }
  | .resolve = [ .stale[] | select(.id as $i | $res | index($i)) | select(.thread.id | test("^[A-Za-z0-9_=-]+$"))
                 | {id, thread: .thread.id} ]
  # Our critical/important comments the re-check did not find fixed (still
  # present, or not re-checked), and the ones a person reopened: they keep our
  # "request changes" in place. Built from all our comments, not .stale: when
  # the threads cannot be listed every .thread is null (unknown), and an
  # unknown thread holds (status open); only one known to be resolved does not.
  | .held = [ $ex[0][] | select((.fp as $fp | $fps | index($fp)) == null)
              | select(.status == "reopened" or (.status == "open" and (.id as $i | $res | index($i) | not)))
              | select(.severity == "critical" or .severity == "important")
              | .id ]'

# load_pr_state <pr> <dir>: write <dir>/diff.json and <dir>/ours.json. Sets
# _inline=false (and empty files) when the reviewed commit is not the PR head
# or the PR's files / review comments can't be read — then every finding goes
# in the digest and nothing is resolved. Needs _repo, _me, _fb_login.
load_pr_state() {
  printf '{}\n' >"$2/diff.json"
  printf '[]\n' >"$2/ours.json"
  _inline=true
  _threads_ok=false
  _local_head="$(git rev-parse HEAD 2>/dev/null)" || _local_head=""
  _pr_head="$(gh_post api "repos/$_repo/pulls/$1" 2>/dev/null | jq -r '.head.sha // empty' 2>/dev/null)" || _pr_head=""
  if [ -z "$_pr_head" ] || [ "$_local_head" != "$_pr_head" ]; then
    echo "rc-post: the reviewed commit is not the PR head; listing every finding in the digest" >&2
    _inline=false
    return 0
  fi
  # A failed thread listing is not fatal: nothing gets resolved (threads unknown).
  # shellcheck disable=SC2016  # GraphQL variables, not shell
  if _threads="$(gh_post api graphql --paginate -F owner="${_repo%%/*}" -F name="${_repo#*/}" -F number="$1" \
    -f query='query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) {
        reviewThreads(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes { id isResolved resolvedBy { login } comments(first: 1) { nodes { databaseId } } } } } } }' 2>/dev/null)"; then
    _threads_ok=true
  else
    _threads=""
  fi
  printf '%s' "$_threads" | jq -s '.' >"$2/threads.json" 2>/dev/null || {
    printf '[]\n' >"$2/threads.json"
    _threads_ok=false
  }
  if _files="$(gh_post api --paginate "repos/$_repo/pulls/$1/files" 2>/dev/null)" \
    && printf '%s' "$_files" | jq -s "$DIFFMAP_JQ" >"$2/diff.json" 2>/dev/null \
    && _rcs="$(gh_post api --paginate "repos/$_repo/pulls/$1/comments" 2>/dev/null)" \
    && printf '%s' "$_rcs" | jq -s --arg me "$_me" --arg fb "$_fb_login" \
      --slurpfile t "$2/threads.json" "$OURS_JQ" >"$2/ours.json" 2>/dev/null; then
    return 0
  fi
  echo "rc-post: could not read the PR's files or review comments; listing every finding in the digest" >&2
  _inline=false
  printf '{}\n' >"$2/diff.json"
  printf '[]\n' >"$2/ours.json"
}

# Common start of `stale` and `review`: validate, resolve repo + identity,
# make the temp dir, load the PR state. Sets _tmp, _ledger.
review_setup() {
  case "$_pr" in
    '' | *[!0-9]*)
      echo "rc-post: invalid PR number '$_pr' (must be digits)" >&2
      return 1
      ;;
  esac
  _tmp="$(mktemp -d "${TMPDIR:-/tmp}/rc-review.XXXXXX")" || {
    echo "rc-post: could not create a temp dir" >&2
    return 1
  }
  trap 'rm -rf "$_tmp"' EXIT
  if jq -e 'type == "object"' "$_ledger" >/dev/null 2>&1; then
    :
  else
    echo "rc-post: ledger is not a JSON object; treating it as having no findings" >&2
    printf '{}\n' >"$_tmp/ledger.json"
    _ledger="$_tmp/ledger.json"
  fi
  GH_POST_TOKEN="$(resolve_token "$_tokname")"
  _repo="$(gh repo view --json nameWithOwner 2>/dev/null | jq -r '.nameWithOwner // empty')"
  [ -n "$_repo" ] || {
    echo "rc-post: could not resolve owner/repo (gh not authenticated?)" >&2
    return 1
  }
  resolve_identity
  load_pr_state "$_pr" "$_tmp"
}

# stale <pr> <ledger> [envname]: print (JSON) our unresolved inline comments
# whose finding this run no longer reports: [{id, fingerprint, path, line, body}].
do_stale() {
  _pr="${1:?rc-post: stale needs <pr-number>}"
  _ledger="${2:?rc-post: stale needs <ledger-file>}"
  _tokname="${3:-}"
  review_setup || return 1
  # Nothing to re-check when we can't tell our comments from another bot's.
  if [ "$_known" != true ]; then
    printf '[]\n'
    return 0
  fi
  jq -n --slurpfile f "$_ledger" --slurpfile ex "$_tmp/ours.json" --arg re "$SECRET_RE" "$LEDGER_DEFS"'
    ($f[0] | reported | map(select(.tracked) | .fingerprint)) as $fps
    | [ $ex[0][] | select((.fp as $fp | $fps | index($fp)) == null and .status == "open"
                          and .thread != null and .thread.resolved == false)
        | {id, fingerprint: .fp, path, line, body} ]'
}

# Our reviews (every review we post carries `<!-- rc:review -->`: another
# bot's or another workflow's review is never ours to count or dismiss):
#   active   — ours still requesting changes;
#   ack      — blocking fingerprints (the hidden `rc:blocking` line of each
#              "request changes" review) whose review a PERSON dismissed: they
#              never block again. The dismisser comes from the PR timeline; if
#              it can't be read, every dismissed review of ours counts as a
#              person's (never re-raise by mistake);
#   blocking — the fingerprints the active reviews block on; "" = an untracked
#              blocker (`rc:blocking-untracked`, or no `rc:blocking` line);
#   outside  — the tracked outside-the-diff findings (`rc:outside-begin` …
#              `rc:outside <fp>`, both written only by this script), the latest
#              review per fingerprint. Reviews posted before these markers have
#              none: their outside findings are not recheckable.
# shellcheck disable=SC2016  # jq program, not shell
REVIEWS_JQ='
  def ours: if $me != "" then .user.login == $me
            else (.user.type == "Bot" and ($fb == "" or .user.login == $fb)) end;
  def sevof: if contains("**🔴 Critical**") then "critical" elif contains("**🟠 Important**") then "important"
             elif contains("**🟡 Suggestion**") then "suggestion" else "unknown" end;
  [ .[] | arrays | .[]
    | select((.body | type) == "string" and (.body | contains("<!-- rc:review -->")) and ours) ] as $ours
  # A person = a User actor other than the identity we post as.
  | (if $tl[0] == null then null
     else [ $tl[0][] | arrays | .[]
            | select(.event == "review_dismissed" and .actor.type == "User" and .actor.login != $me)
            | .dismissed_review.review_id | tostring ] end) as $human
  | { active: [ $ours[] | select(.state == "CHANGES_REQUESTED") | .id ],
      ack: ([ $ours[] | select(.state == "DISMISSED") | . as $r
              | select($human == null or ($r.id | tostring | IN($human[])))
              | .body | capture("<!-- rc:blocking (?<l>[A-Za-z0-9._:/@+ -]*) -->").l
              | split(" ")[] | select(. != "") ] | unique),
      blocking: ([ $ours[] | select(.state == "CHANGES_REQUESTED") | .body
                   | [match("<!-- rc:blocking (?<l>[A-Za-z0-9._:/@+ -]*) -->"; "g") | .captures[0].string] as $ls
                   | if ($ls | length) == 0 then ""
                     else ($ls[] | split(" ")[] | select(. != "")),
                          (if contains("<!-- rc:blocking-untracked -->") then "" else empty end) end ] | unique),
      outside: ([ $ours[] | . as $r | ($r.body | split("<!-- rc:outside ")) as $parts
                  | range(1; $parts | length) as $i
                  | ([$parts[$i] | capture("^(?<fp>[A-Za-z0-9._:/@+-]{1,200}) -->") | .fp] | first) as $fp
                  | select($fp != null)
                  | ($parts[$i - 1] | split("<!-- rc:outside-begin -->")
                     | if length > 1 then last | sub("^\\s+"; "") | sub("\\s+$"; "") else "" end) as $text
                  # The location line the script wrote first: `path:12`, `path:3-5` or none.
                  | ([$text | split("\n")[0] | capture("^`(?<p>[^`]+?)(?::(?<l>[0-9]+)(?:-[0-9]+)?)?`$")] | first) as $loc
                  | {fingerprint: $fp, severity: ($text | sevof), review_id: $r.id, url: ($r.html_url // null),
                     path: ($loc.p? // null), line: ($loc.l? // null | if . == null then null else tonumber end),
                     title: ([$text | split("\n")[] | capture("^\\*\\*(?<t>.+)\\*\\*$") | .t
                              | select(IN("🔴 Critical", "🟠 Important", "🟡 Suggestion", "Finding") | not)] | first // ""),
                     text: $text, submitted_at: ($r.submitted_at // null)} ]
                | group_by(.fingerprint) | map(max_by(.review_id))) }'

# load_reviews <pr>: our reviews into $_tmp/rv.json (REVIEWS_JQ). Sets
# _rv_ok=false (and an empty object) when they can't be read: a failed listing
# must not look like an empty one. The timeline goes through a file, never
# argv (Linux caps one argument at 128 KB, and a busy PR's timeline is bigger).
load_reviews() {
  _rv_ok=false
  printf '{"active":[],"ack":[],"blocking":[],"outside":[]}\n' >"$_tmp/rv.json"
  _revs="$(gh_post api --paginate "repos/$_repo/pulls/$1/reviews" 2>/dev/null)" || return 0
  printf 'null\n' >"$_tmp/tl.json"
  if _tlraw="$(gh_post api --paginate "repos/$_repo/issues/$1/timeline" 2>/dev/null)"; then
    printf '%s' "$_tlraw" | jq -s -c '.' >"$_tmp/tl.json" 2>/dev/null || printf 'null\n' >"$_tmp/tl.json"
  fi
  if printf '%s' "$_revs" | jq -s -c --arg me "$_me" --arg fb "$_fb_login" --slurpfile tl "$_tmp/tl.json" \
    "$REVIEWS_JQ" >"$_tmp/rv.new" 2>/dev/null && [ -s "$_tmp/rv.new" ]; then
    mv "$_tmp/rv.new" "$_tmp/rv.json"
    _rv_ok=true
  fi
}

# load_outside_fixed <pr>: [{fp, at}] of our PR comments that say an outside
# finding looks fixed (`rc:outside-fixed <fp>`) into $_tmp/ofixed.json. Sets
# _ic_ok=false when the comments can't be listed.
load_outside_fixed() {
  _ic_ok=false
  printf '[]\n' >"$_tmp/ofixed.json"
  _ics="$(gh_post api --paginate "repos/$_repo/issues/$1/comments" 2>/dev/null)" || return 0
  # shellcheck disable=SC2016  # jq program, not shell
  if printf '%s' "$_ics" | jq -s -c --arg me "$_me" --arg fb "$_fb_login" '
      [ .[] | arrays | .[]
        | select((.body | type) == "string"
            and (if $me != "" then .user.login == $me
                 else (.user.type == "Bot" and ($fb == "" or .user.login == $fb)) end))
        | (.created_at // "") as $at
        | .body | [match("<!-- rc:outside-fixed ([A-Za-z0-9._:/@+-]{1,200}) -->"; "g") | .captures[0].string][]
        | {fp: ., at: $at} ]' >"$_tmp/ofixed.new" 2>/dev/null && [ -s "$_tmp/ofixed.new" ]; then
    mv "$_tmp/ofixed.new" "$_tmp/ofixed.json"
    _ic_ok=true
  fi
}

# resolve_thread <thread-id>: resolve one review thread (id charset-checked
# by the caller). Non-zero when GitHub refuses (e.g. the Actions token).
resolve_thread() {
  # shellcheck disable=SC2016  # GraphQL variables, not shell
  gh_post api graphql -f id="$1" \
    -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' >/dev/null 2>&1
}

# post_fixed_reply <comment-id> <resolved: true|false> <why-file> <default summary>:
# the "looks fixed" reply on our inline comment. <why-file> holds the model's
# {summary, points} (or null); every text goes through jq (REPLY_DEFS).
post_fixed_reply() {
  if ! jq -n --slurpfile w "$3" --arg short "$_short" --argjson r "$2" --arg who "$_who" --arg d "$4" \
    --arg re "$SECRET_RE" "$LEDGER_DEFS$REPLY_DEFS"'{body: fixedreply($w[0]; $short; $r; $who; $d)}' >"$_tmp/reply.raw" 2>/dev/null \
    || ! redact_file "$_tmp/reply.raw" "$_tmp/reply.json"; then
    echo "rc-post: could not compose the reply on inline comment $1" >&2
    return 1
  fi
  gh_post api "repos/$_repo/pulls/$_pr/comments/$1/replies" -X POST --input - <"$_tmp/reply.json" >/dev/null 2>&1 || {
    echo "rc-post: could not reply on inline comment $1" >&2
    return 1
  }
}

# dismiss_active <message>: dismiss each of our active reviews ($_active, a
# JSON array of ids). Adds to _n_dis.
dismiss_active() {
  printf '%s' "$_active" | jq -r '.[] | select(type == "number" and . == floor and . > 0)' >"$_tmp/dismiss.txt" 2>/dev/null || : >"$_tmp/dismiss.txt"
  jq -n --arg m "$1" '{event: "DISMISS", message: $m}' >"$_tmp/dismiss.json"
  while read -r _rid; do
    if gh_post api "repos/$_repo/pulls/$_pr/reviews/$_rid/dismissals" -X PUT --input - <"$_tmp/dismiss.json" >/dev/null 2>&1; then
      _n_dis=$((_n_dis + 1))
    else
      echo "rc-post: could not dismiss review $_rid" >&2
    fi
  done <"$_tmp/dismiss.txt"
}

# plan_out <posted: true|false>: the RC_PLAN_OUT side file (when set), for the
# recheck that follows a full run: the reviewed commit, the run status, whether
# it blocks, the tracked fingerprints it reported, and whether it was posted.
plan_out() {
  [ -n "${RC_PLAN_OUT:-}" ] || return 0
  if [ "$1" = true ]; then
    jq -c --arg h "${_local_head:-}" --arg s "${_status:-}" \
      '{head: $h, status: $s, block: (.block != false), reported: [.reported[]? | strings], posted: true}' \
      "$_tmp/plan.json" >"$RC_PLAN_OUT" 2>/dev/null
  else
    printf '{"head":"","status":"","block":true,"reported":[],"posted":false}\n' >"$RC_PLAN_OUT" 2>/dev/null
  fi || echo "rc-post: could not write RC_PLAN_OUT" >&2
}

# review <pr> <digest-file> <ledger> [envname] [recheck-file]
# recheck-file (optional, orchestrator-written): {"fixed": [<comment id>...],
# "covered": ["<fingerprint>"...], "why": {"<comment id>": {"summary", "points"}}}
# — `fixed` = stale comments the re-check found fixed (resolved here, if still
# stale); `covered` = new fingerprints an earlier comment already covers (not
# posted again); `why` (optional) = the re-check's reasons, shown in the reply.
do_review() {
  _pr="${1:?rc-post: review needs <pr-number>}"
  _body="${2:?rc-post: review needs <digest-file>}"
  _ledger="${3:?rc-post: review needs <ledger-file>}"
  _tokname="${4:-}"
  _recheck="${5:-}"
  # Until this run has posted, the side file says so (never a stale success).
  plan_out false

  [ -f "$_body" ] || {
    echo "rc-post: digest file not found: $_body" >&2
    return 1
  }
  grep -qF -- "$MARKER" "$_body" || {
    echo "rc-post: refusing to post — body is not a Review Council digest (missing $MARKER)" >&2
    return 1
  }
  review_setup || return 1

  _fixed='[]'
  _covered='[]'
  if [ -n "$_recheck" ]; then
    _fixed="$(jq -c '[.fixed[]? | select(type == "number" and . == floor and . > 0)]' "$_recheck" 2>/dev/null)" || _fixed='[]'
    _covered="$(jq -c '[.covered[]? | select(type == "string") | gsub("[^A-Za-z0-9._:/@+-]"; "-") | .[0:200] | select(length > 0)]' "$_recheck" 2>/dev/null)" || _covered='[]'
    [ -n "$_fixed" ] || _fixed='[]'
    [ -n "$_covered" ] || _covered='[]'
  fi

  # Run status from the digest's rc:state line (script-produced, line 2).
  _status="$(sed -n '2s/^<!-- rc:state \(.*\) -->$/\1/p' "$_body" | jq -r '.status // empty' 2>/dev/null)" || _status=""

  # The files that findings with location.code point at, as lines at the
  # reviewed commit (= local HEAD, checked by load_pr_state), for relocate.
  # Only files in the PR's diff; paths are git arguments, never shell code.
  printf '{}\n' >"$_tmp/src.json"
  if [ "$_inline" = true ]; then
    jq -r --slurpfile d "$_tmp/diff.json" '[.findings[]? | objects | select((.location.code | type) == "string")
        | .location.path | strings | select(. as $p | $d[0] | has($p))] | unique[]' "$_ledger" 2>/dev/null | head -n 50 |
      while IFS= read -r _p; do
        git show "HEAD:$_p" 2>/dev/null | head -c 2000000 | jq -Rs --arg p "$_p" '{($p): split("\n")}' 2>/dev/null
      done | jq -s 'add // {}' >"$_tmp/src.json" 2>/dev/null || printf '{}\n' >"$_tmp/src.json"
  fi

  if ! jq -n --slurpfile f "$_ledger" --slurpfile d "$_tmp/diff.json" --slurpfile ex "$_tmp/ours.json" \
    --slurpfile src "$_tmp/src.json" \
    --argjson inline "$_inline" --argjson maxn "$MAX_INLINE" --argjson cov "$_covered" --argjson res "$_fixed" \
    --arg re "$SECRET_RE" --arg footer "$_footer" \
    "$LEDGER_DEFS"' $f[0] | '"$PLAN_JQ" >"$_tmp/plan.json" 2>/dev/null; then
    echo "rc-post: could not place the findings; posting the digest only" >&2
    printf '{"block":false,"blocking":[],"reported":[],"kept":0,"new":[],"outside":[],"stale":[],"resolve":[],"held":[]}\n' >"$_tmp/plan.json"
  fi

  # Our reviews (REVIEWS_JQ): `active` = ours still requesting changes; `ack`
  # = blocking fingerprints a PERSON waved through (dismissed the review, or
  # resolved the comment's thread) — those never block again; only a new
  # critical/important finding does. A failed reviews listing must not look
  # like an empty one: then "unknown" — no new block, no dismissal.
  _active=""
  _ack='[]'
  load_reviews "$_pr"
  if [ "$_rv_ok" = true ]; then
    _active="$(jq -c '.active' "$_tmp/rv.json")"
    _ack="$(jq -c '.ack' "$_tmp/rv.json")"
  else
    echo "rc-post: could not read our earlier reviews; not requesting changes or dismissing this run" >&2
  fi
  # A thread a person resolved: only with a known identity (unknown = any
  # resolver could be us).
  if [ "$_known" = true ]; then
    if _ack2="$(jq -c --argjson a "$_ack" '$a + [.[] | select(.status == "resolved_by_person") | .fp] | unique' "$_tmp/ours.json" 2>/dev/null)" \
      && [ -n "$_ack2" ]; then
      _ack="$_ack2"
    fi
  fi
  _block="$(jq -r '.block' "$_tmp/plan.json")"
  # Raise a block only for a blocking finding a person hasn't already waved
  # through (an untracked fingerprint, "", always counts as new).
  _raise="$(jq -r --argjson ack "$_ack" '[.blocking[] | select(. == "" or (. as $f | $ack | index($f)) == null)] | length > 0' "$_tmp/plan.json")"
  _n_new="$(jq '.new | length' "$_tmp/plan.json")"
  _event=COMMENT
  # RC_PR_REQUEST_CHANGES=false: comments only, never "request changes".
  # Env-only (never config): a reviewed PR must not switch the block off.
  _rc_req="${RC_PR_REQUEST_CHANGES:-true}"
  case "$_rc_req" in
    true | false) ;;
    *)
      echo "rc-post: RC_PR_REQUEST_CHANGES must be true or false; treating it as true" >&2
      _rc_req=true
      ;;
  esac
  # Only on the reviewed head (_inline): never block or dismiss a commit we
  # didn't review.
  if [ "$_rc_req" = true ] && [ "$_inline" = true ] && [ "$_raise" = true ] && [ "$_active" = '[]' ]; then
    _event=REQUEST_CHANGES
  fi

  # 1. Resolve the stale comments the re-check found fixed; 2. dismiss our
  #    "request changes" when the run is clean. Neither on a degraded run.
  _n_res=0
  _n_dis=0
  _short="$(printf '%s' "$_pr_head" | cut -c1-7)"
  # Neither when the run is degraded, nor when we can't tell our own threads
  # and reviews from another bot's (_known=false).
  if [ "$_status" != degraded ] && [ "$_known" = true ]; then
    jq -r '.resolve[] | "\(.id) \(.thread)"' "$_tmp/plan.json" >"$_tmp/resolve.txt"
    # Resolve first, then one marked reply saying how it went. The marker makes
    # the comment never stale again, so a refused resolve (GitHub may refuse
    # the Actions token) costs one reply, not one per run. The re-check may
    # give its reasons (`why`); without them the reply says the finding is no
    # longer reported.
    while read -r _cid _tid; do
      if resolve_thread "$_tid"; then
        _n_res=$((_n_res + 1))
        _rok=true
      else
        echo "rc-post: could not resolve the thread of inline comment $_cid" >&2
        _rok=false
      fi
      printf 'null\n' >"$_tmp/why.json"
      if [ -n "$_recheck" ]; then
        jq -c --arg k "$_cid" 'if (.why | type) == "object" then .why[$k] else null end' "$_recheck" >"$_tmp/why.json" 2>/dev/null \
          || printf 'null\n' >"$_tmp/why.json"
      fi
      post_fixed_reply "$_cid" "$_rok" "$_tmp/why.json" "This finding is no longer reported." || true
    done <"$_tmp/resolve.txt"
    # Dismiss only on a run the rc:state line calls clean (no critical or
    # important finding), so an empty or unreadable ledger never lifts a block,
    # and never while one of our critical/important comments is still open
    # without the re-check finding it fixed, or reopened by a person.
    _held="$(jq '.held // [] | length' "$_tmp/plan.json" 2>/dev/null)" || _held=1
    if [ "$_inline" = true ] && [ "$_block" = false ] && [ "$_status" = clean ] \
      && [ "$_held" = 0 ] && [ -n "$_active" ] && [ "$_active" != '[]' ]; then
      dismiss_active "No critical or important findings in the Review Council review of $_short."
    fi
  fi

  # 3. One review per run carries everything: the summary (the digest), the
  #    findings outside the diff, and the inline comments. GitHub rejects the
  #    whole review on one bad line (and refuses "request changes" on a PR we
  #    authored), so retry as a comment, then without the inline comments
  #    (listed in the body instead). If no review is accepted, the summary
  #    goes to a PR comment instead.
  _review_url=""
  _posted=0
  _tries="$_event:true"
  [ "$_event" = COMMENT ] || _tries="$_tries COMMENT:true"
  if [ "$_n_new" -gt 0 ]; then
    _tries="$_tries $_event:false"
    [ "$_event" = COMMENT ] || _tries="$_tries COMMENT:false"
  fi
  for _try in $_tries; do
    _ev="${_try%%:*}"
    _withinline="${_try#*:}"
    compose_body "$_withinline" || return 1
    jq -n --rawfile b "$_tmp/body.md" --slurpfile p "$_tmp/plan.json" --arg ev "$_ev" \
      --arg sha "$([ "$_inline" = true ] && printf '%s' "$_pr_head")" --argjson wi "$_withinline" '
      {event: $ev,
       body: ($b + "\n\n<!-- rc:review -->"
              + (if $ev == "REQUEST_CHANGES"
                 then (if any($p[0].blocking[]; . == "") then "\n\n<!-- rc:blocking-untracked -->" else "" end)
                      + "\n\n<!-- rc:blocking " + ([$p[0].blocking[] | select(. != "")] | join(" ")) + " -->" else "" end)),
       comments: (if $wi then [$p[0].new[] | del(.outside)] else [] end)}
      + (if $sha != "" then {commit_id: $sha} else {} end)' >"$_tmp/review.raw"
    if redact_file "$_tmp/review.raw" "$_tmp/review.json" \
      && _review_url="$(gh_post api "repos/$_repo/pulls/$_pr/reviews" -X POST --input - <"$_tmp/review.json" 2>/dev/null \
        | jq -r '.html_url // empty' 2>/dev/null)" && [ -n "$_review_url" ]; then
      _posted=1
      _event="$_ev"
      [ "$_withinline" = true ] || _n_new=0
      break
    fi
    _review_url=""
    echo "rc-post: GitHub did not accept the review ($_ev, inline comments: $_withinline)" >&2
  done
  [ "$_RED_N" = 0 ] || echo "rc-post: redacted $_RED_N likely secret(s) before posting" >&2

  _n_out="$(jq '.outside | length' "$_tmp/plan.json")"
  if [ "$_posted" = 1 ]; then
    # A summary comment left by an earlier run (or an earlier fallback) would
    # go stale: point it at the latest review instead.
    jq -n --arg m "$MARKER" --arg u "$_review_url" --arg f "$_footer" \
      '{body: ($m + "\nReview Council posts its summary with each review. [Latest review](\($u)).\n\n" + $f)}' >"$_tmp/pointer.json"
    upsert_digest "$_pr" "$_tmp/pointer.json" update-only || true
    _action=review
    _url="$_review_url"
  else
    _n_new=0
    compose_body false || return 1
    if ! redact_file "$_tmp/body.md" "$_tmp/body.red" \
      || ! jq -Rs '{body: .}' "$_tmp/body.red" >"$_tmp/digest.json" 2>/dev/null; then
      echo "rc-post: could not scan the summary for secrets; not posting it" >&2
      return 1
    fi
    echo "rc-post: posting the summary as a PR comment instead" >&2
    upsert_digest "$_pr" "$_tmp/digest.json" || return 1
    _action=comment
    _url="$_DG_URL"
  fi

  plan_out true
  printf 'action=%s\nurl=%s\n' "$_action" "$_url"
  printf 'review_url=%s\nreview_event=%s\ninline_new=%s\nkept=%s\nresolved=%s\ndismissed=%s\noutside=%s\n' \
    "$_review_url" "$([ -n "$_review_url" ] && echo "$_event")" "$_n_new" "$(jq '.kept' "$_tmp/plan.json")" \
    "$_n_res" "$_n_dis" "$([ "$_n_new" = 0 ] && jq '.outside + .new | length' "$_tmp/plan.json" || echo "$_n_out")"
}

# ---------------------------------------------------------------------------
# open / recheck: re-check the council's open comments without a full run.
#
# `open` prints the state a recheck works from (one JSON object):
#   {head, inline_ok, known, active, blocking, ack, inline: [...], outside: [...]}
# inline_ok is false unless the checked-out commit is the PR head AND the
# threads, review comments, reviews and PR comments could all be read; known is
# false when we can't tell our own comments from another bot's. Either way the
# object is still printed, and the caller does nothing.
# inline[]: {id, fingerprint, severity, path, line, url, body, status} (status:
# see OURS_JQ). outside[]: {fingerprint, severity, review_id, url, path, line,
# title, text, status: open|fixed} (path/line null when unknown) — fixed when one of our PR comments carries
# `rc:outside-fixed <fp>` posted after the review that listed it; a fingerprint
# with an inline comment is left out. ack = fingerprints of reviews a person
# dismissed + of threads a person resolved.
#
# `recheck` acts on the verdicts (orchestrator-written, model-derived: DATA):
#   {"head", "degraded", "blocking_now", "reported": [fp], "checked": n,
#    "fixed": [{"kind": "inline", "id", "summary", "points"},
#              {"kind": "outside", "fingerprint", "summary", "points"}]}
# Nothing happens unless degraded and blocking_now are literally false (for
# the dismissal), the identity is known, inline_ok, and head is the PR head.
# Fixed inline comments that are still open: resolve the thread, then reply
# (marker `rc:fixed resolved` only when the resolve worked). Fixed outside
# findings that are still open: one PR comment. Then our "request changes" is
# dismissed when nothing blocking is left (see recheck_eval).
# ---------------------------------------------------------------------------

# load_state <pr>: everything `open` prints, into $_tmp/state.json (inline
# entries also carry `_thread`, the charset-checked thread id or null).
load_state() {
  case "$_pr" in
    '' | *[!0-9]*)
      echo "rc-post: invalid PR number '$_pr' (must be digits)" >&2
      return 1
      ;;
  esac
  _tmp="$(mktemp -d "${TMPDIR:-/tmp}/rc-review.XXXXXX")" || {
    echo "rc-post: could not create a temp dir" >&2
    return 1
  }
  trap 'rm -rf "$_tmp"' EXIT
  GH_POST_TOKEN="$(resolve_token "$_tokname")"
  _repo="$(gh repo view --json nameWithOwner 2>/dev/null | jq -r '.nameWithOwner // empty')"
  [ -n "$_repo" ] || {
    echo "rc-post: could not resolve owner/repo (gh not authenticated?)" >&2
    return 1
  }
  resolve_identity
  load_pr_state "$_pr" "$_tmp"
  load_reviews "$_pr"
  load_outside_fixed "$_pr"
  _inline_ok=false
  if [ "$_inline" = true ] && [ "$_threads_ok" = true ] && [ "$_rv_ok" = true ] && [ "$_ic_ok" = true ]; then
    _inline_ok=true
  fi
  # shellcheck disable=SC2016  # jq program, not shell
  jq -n --slurpfile ours "$_tmp/ours.json" --slurpfile rv "$_tmp/rv.json" --slurpfile of "$_tmp/ofixed.json" \
    --arg head "$_pr_head" --argjson ok "$_inline_ok" --argjson known "$_known" '
    $ours[0] as $in | $rv[0] as $r
    | ([$in[] | .fp]) as $infps
    | {head: $head, inline_ok: $ok, known: $known,
       active: $r.active, blocking: $r.blocking,
       ack: ($r.ack + (if $known then [$in[] | select(.status == "resolved_by_person") | .fp] else [] end) | unique),
       inline: [ $in[] | {id, fingerprint: .fp, severity, path, line, url, body, status,
                          _thread: (.thread.id? // null | if type == "string" and test("^[A-Za-z0-9_=-]+$") then . else null end)} ],
       outside: [ $r.outside[] | select(.fingerprint as $f | $infps | index($f) | not) | . as $o
                  | . + {status: (if any($of[0][]; .fp == $o.fingerprint and (.at | type) == "string"
                                         and .at > ($o.submitted_at // "")) then "fixed" else "open" end)}
                  | del(.submitted_at) ]}' >"$_tmp/state.json" 2>/dev/null || {
    echo "rc-post: could not assemble the PR state" >&2
    return 1
  }
}

# open <pr> [envname]
do_open() {
  _pr="${1:?rc-post: open needs <pr-number>}"
  _tokname="${2:-}"
  load_state || return 1
  jq '.inline |= map(del(._thread))' "$_tmp/state.json"
}

# recheck_out: the key=value summary of a recheck.
recheck_out() {
  printf 'checked=%s\nfixed_inline=%s\nresolved=%s\noutside_fixed=%s\ndismissed=%s\nheld=%s\n' \
    "$(int "$_checked")" "$(int "$_n_fi")" "$(int "$_n_res")" "$(int "$_n_of")" "$(int "$_n_dis")" "$(int "$_held")"
}

# int <value>: the value when it is a plain integer, else 0 (never empty).
int() {
  case "$1" in '' | *[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac
}

# recheck <pr> <verdicts-file> [envname]
do_recheck() {
  _pr="${1:?rc-post: recheck needs <pr-number>}"
  _verd="${2:?rc-post: recheck needs <verdicts-file>}"
  _tokname="${3:-}"
  _checked=0
  _n_fi=0
  _n_res=0
  _n_of=0
  _n_dis=0
  _held=0
  if ! jq -e 'type == "object"' "$_verd" >/dev/null 2>&1; then
    echo "rc-post: the verdicts are not a JSON object; nothing done" >&2
    recheck_out
    return 0
  fi
  load_state || return 1
  _checked="$(jq '.checked | if type == "number" and . >= 0 and . == floor then . else 0 end' "$_verd" 2>/dev/null)" || _checked=0
  _vhead="$(jq -r '.head | strings | select(test("^[0-9a-f]{40}$"))' "$_verd" 2>/dev/null)" || _vhead=""
  _why=""
  if ! jq -e '.degraded == false' "$_verd" >/dev/null 2>&1; then
    _why="the recheck is degraded"
  elif [ "$_known" != true ]; then
    _why="we can't tell our own comments from another bot's"
  elif [ "$_inline_ok" != true ]; then
    _why="the PR head or its comments, threads or reviews can't be read"
  elif [ -z "$_vhead" ] || [ "$_vhead" != "$_pr_head" ]; then
    _why="the checked commit is no longer the PR head (a newer push will recheck)"
  fi
  if [ -n "$_why" ]; then
    echo "rc-post: recheck: $_why; nothing done" >&2
    recheck_out
    return 0
  fi
  _short="$(printf '%s' "$_pr_head" | cut -c1-7)"
  _active="$(jq -c '.active' "$_tmp/state.json")"
  : >"$_tmp/done_inline.txt"
  : >"$_tmp/done_outside.txt"

  # 1. Inline: resolve, then reply. Only ids of our comments that are open.
  jq -r --slurpfile s "$_tmp/state.json" '
    [.fixed[]? | objects | select(.kind == "inline") | .id
     | select(type == "number" and . == floor and . > 0)] | unique | .[] as $id
    | $s[0].inline[] | select(.id == $id and .status == "open") | "\(.id) \(._thread // "-")"' \
    "$_verd" >"$_tmp/fix.txt" 2>/dev/null || : >"$_tmp/fix.txt"
  while read -r _cid _tid; do
    case "$_cid" in '' | *[!0-9]*) continue ;; esac
    jq -c --argjson id "$_cid" '[.fixed[]? | objects | select(.kind == "inline" and .id == $id)] | first' \
      "$_verd" >"$_tmp/why.json" 2>/dev/null || printf 'null\n' >"$_tmp/why.json"
    _rok=false
    if [ "$_tid" != - ]; then
      if resolve_thread "$_tid"; then
        _rok=true
        _n_res=$((_n_res + 1))
      else
        echo "rc-post: could not resolve the thread of inline comment $_cid" >&2
      fi
    fi
    if post_fixed_reply "$_cid" "$_rok" "$_tmp/why.json" "This looks fixed."; then
      _n_fi=$((_n_fi + 1))
      printf '%s\n' "$_cid" >>"$_tmp/done_inline.txt"
    elif [ "$_rok" = true ]; then
      # Resolved without our reply: no longer open either way.
      printf '%s\n' "$_cid" >>"$_tmp/done_inline.txt"
    fi
  done <"$_tmp/fix.txt"

  # 2. Outside the diff: one PR comment for every fixed finding still open.
  # shellcheck disable=SC2016  # jq program, not shell
  if jq -c --slurpfile s "$_tmp/state.json" --arg short "$_short" --arg who "$_who" --arg re "$SECRET_RE" \
    "$LEDGER_DEFS$REPLY_DEFS"'
    [ .fixed[]? | objects | select(.kind == "outside" and (.fingerprint | type) == "string") ] as $v
    | [ $v | map(.fingerprint) | unique | .[] as $f
        | ($s[0].outside[] | select(.fingerprint == $f and .status == "open")) as $o
        | {fp: $f, o: $o, why: ([$v[] | select(.fingerprint == $f)] | first)} ] as $ents
    | if ($ents | length) == 0 then empty else
      {fps: [$ents[].fp],
       body: (($ents | map(
                 ((.o.title // "" | rtext | gsub("[\\[\\]]"; "")) | if . == "" then "a finding" else . end) as $t
                 | (if (.o.url | type) == "string" and (.o.url | test("^https://[^\\s()<>\\[\\]]+$"))
                    then "[" + $t + "](" + .o.url + ")" else $t end) as $link
                 | "**Looks fixed** at `" + $short + "`: " + $link + " from an earlier review. "
                   + whysum(.why; "This looks fixed.") + whydetails(.why)
                   + "\n\n<!-- rc:outside-fixed " + .fp + " -->")
               | join("\n\n"))
              + "\n\n" + signoff($who) + "</sub>")} end' "$_verd" >"$_tmp/ofix.raw" 2>/dev/null; then
    if [ -s "$_tmp/ofix.raw" ]; then
      if jq -c '{body}' "$_tmp/ofix.raw" >"$_tmp/ofix.body" 2>/dev/null \
        && redact_file "$_tmp/ofix.body" "$_tmp/ofix.json" \
        && gh_post api "repos/$_repo/issues/$_pr/comments" -X POST --input - <"$_tmp/ofix.json" >/dev/null 2>&1; then
        jq -r '.fps[]' "$_tmp/ofix.raw" >"$_tmp/done_outside.txt"
        _n_of="$(jq '.fps | length' "$_tmp/ofix.raw")"
      else
        echo "rc-post: could not post the outside-the-diff recheck comment" >&2
      fi
    fi
  else
    echo "rc-post: could not compose the outside-the-diff recheck comment" >&2
  fi

  # 3. Dismiss our "request changes" when nothing blocking is left.
  recheck_eval >"$_tmp/eval.json" 2>/dev/null || printf '{"held":1,"dismiss":false}\n' >"$_tmp/eval.json"
  _held="$(jq '.held' "$_tmp/eval.json")"
  if [ "$(jq -r '.dismiss' "$_tmp/eval.json")" = true ]; then
    dismiss_active "Rechecked at $_short: $((_n_fi + _n_of)) of $_checked open findings look fixed; no critical or important finding is left open."
  fi
  recheck_out
}

# recheck_eval: {held, dismiss}. Dismiss only when the verdicts say nothing
# blocks now (blocking_now literally false), we have an active review, every
# fingerprint it blocks on is satisfied — acknowledged by a person, its
# inline comment fixed or resolved, its outside finding fixed, or still
# reported (but no longer blocking) — none is untracked (""), and no
# critical/important inline comment is open or reopened unless acknowledged.
# held = what keeps the block: those comments + the unsatisfied fingerprints.
recheck_eval() {
  jq -R -s 'split("\n") | map(select(test("^[0-9]+$")) | tonumber)' "$_tmp/done_inline.txt" >"$_tmp/di.json"
  jq -R -s 'split("\n") | map(select(. != ""))' "$_tmp/done_outside.txt" >"$_tmp/do.json"
  # shellcheck disable=SC2016  # jq program, not shell
  jq -c --slurpfile s "$_tmp/state.json" --slurpfile di "$_tmp/di.json" --slurpfile dout "$_tmp/do.json" '
    . as $v | $s[0] as $st | $di[0] as $di | $dout[0] as $dout
    | ([$v.reported[]? | strings | gsub("[^A-Za-z0-9._:/@+-]"; "-") | .[0:200] | select(length > 0)]) as $rep
    | ($st.inline | map(if (.id as $i | $di | index($i)) != null then .status = "fixed" else . end)) as $in
    | ($st.outside | map(if (.fingerprint as $f | $dout | index($f)) != null then .status = "fixed" else . end)) as $out
    | [ $in[] | select((.status == "open" or .status == "reopened")
                       and (.severity == "critical" or .severity == "important")
                       and (.fingerprint as $f | $st.ack | index($f)) == null) | .fingerprint ] as $hold
    | [ $st.blocking[] | . as $f
        | select(. == ""
            or ((($st.ack | index($f)) != null)
                or any($in[]; .fingerprint == $f and (.status == "fixed" or .status == "resolved_by_person" or .status == "resolved"))
                or any($out[]; .fingerprint == $f and .status == "fixed")
                or (($rep | index($f)) != null) | not)) ] as $unsat
    | {held: (($hold | length) + ([$unsat[] | select(. as $f | $hold | index($f) | not)] | length)),
       dismiss: ($v.blocking_now == false and ($st.active | length) > 0
                 and ($unsat | length) == 0 and ($hold | length) == 0)}' "$_verd"
}

# compose_body <with-inline>: the summary for this run's review (or the
# fallback comment) into $_tmp/body.md: the digest, the counts in place of its
# `rc:inline` line, the tags legend, the findings outside the diff (with the
# inline ones too when <with-inline> is false; each tracked one between
# `rc:outside-begin` and `rc:outside <fp>`), then the footer. Hidden-marker
# openers are neutralised everywhere except the rc:report line and a strict
# rc:state line, so only those and the lines this script writes are markers.
# Needs _tmp, _body, _n_res, _footer.
compose_body() {
  jq -n -r --rawfile dg "$_body" --slurpfile p "$_tmp/plan.json" --arg mark "$INLINE_MARK" \
    --argjson wi "$1" --argjson nr "$_n_res" --arg footer "$_footer" --arg mk "$MARKER" '
    def defuse: gsub("<!--"; "&lt;!--");
    ($dg | split("\n")) as $l
    # The state line is printed from model-filled values: keep it only in its
    # exact shape (no angle brackets inside), so it cannot carry a marker.
    | ($l[1] // "" | test("^<!-- rc:state \\{[^<>]*\\} -->$")) as $hasst
    | (if $hasst then $l[1] | capture("^<!-- rc:state (?<j>.*) -->$").j | fromjson? // {} else {} end) as $st
    | ([ ($l[0] // "" | if . == $mk then . else defuse end) ] + (if $hasst then [$l[1]] else [] end)
       | join("\n")) as $head
    # Only our markers stay markers: the model-written rest keeps the
    # rc:inline placeholder, and every other comment opener is neutralised.
    | ($l[(if $hasst then 2 else 1 end):] | join("\n") | split($mark) | map(defuse) | join($mark)) as $rest
    | (if $wi then $p[0].new | length else 0 end) as $nn
    # A tracked outside finding sits between `rc:outside-begin` and
    # `rc:outside <fp>` (the recheck finds it there); an untracked one has no
    # markers. Only this script writes them: every other opener is defused.
    | ([ ($p[0].outside + (if $wi then [] else [$p[0].new[].outside] end))[]
         | if (.fp | type) == "string" and (.fp | test("^[A-Za-z0-9._:/@+-]{1,200}$"))
           then "<!-- rc:outside-begin -->\n\n" + .md + "\n\n<!-- rc:outside " + .fp + " -->"
           else .md end ]) as $o
    | ([ ("critical", "important", "suggestion") as $k
         | ($st[$k] // 0) as $n | select(($n | type) == "number" and $n > 0)
         | "\($n) \($k)" + (if $k == "suggestion" and $n > 1 then "s" else "" end) ]
       | if length == 0 then "none" else join(" · ") end) as $tally
    | ([ (if $nn > 0 then "\($nn) inline comment" + (if $nn > 1 then "s" else "" end) + " below" else empty end),
         (if $p[0].kept > 0 then "\($p[0].kept) already commented" else empty end),
         (if $nr > 0 then "\($nr) resolved as fixed" else empty end),
         (if ($o | length) > 0 then "\($o | length) outside the diff" else empty end) ]
       | if length == 0 then "" else "**On the diff:** " + join(" · ") end) as $counts
    | ([ (if ($st | has("critical")) then "**Findings:** " + $tally else "" end), $counts ]
       | map(select(. != "")) | join(" · ")) as $line
    | ("<details>\n<summary>What the tags mean</summary>\n\n"
       + "- `[verified]` — backed by a tool: a secret or known-CVE scanner hit, or a lint/security rule a reviewer confirmed.\n"
       + "- `[cross-reviewed]` — raised by reviewers from two or more model families, or confirmed by a different family when double-checked.\n"
       + "- `[1 reviewer · unverified]` — only Claude-family reviewers ran, so no other family could check it.\n"
       + "- `[unverified]` — the double-check could not confirm or refute it (or ran out of time).\n"
       + "- `[tool-only:<rule>]` — a lint or security rule fired and no reviewer confirmed it.\n\n"
       + "</details>") as $legend
    # GitHub caps a review or comment body at 65,536 characters: keep the
    # findings that fit in about 60,000 and count the rest.
    | (60000 - ($dg | length) - ($line | length) - ($legend | length) - ($footer | length) - 300) as $room
    | (reduce $o[] as $x ({used: 0, kept: [], more: 0};
         if .more == 0 and .used + ($x | length) + 9 <= $room
         then .used += ($x | length) + 9 | .kept += [$x] else .more += 1 end)) as $fit
    | ((if $line != "" then $line + "\n\n" else "" end)
       + (if ($o | length) > 0
          then "### Outside the diff (\($o | length))\n\n" + ($fit.kept | join("\n\n---\n\n"))
               + (if $fit.more > 0 then "\n\n_\($fit.more) more not shown: too long for one review. The run'"'"'s report lists them._" else "" end)
               + "\n\n"
          else "" end)
       + $legend) as $sec
    # split/join, not index/rindex: jq 1.7 returns byte offsets for those,
    # which corrupts the splice as soon as the digest has non-ASCII text.
    | ($rest | split($mark)) as $parts
    | $head + "\n"
      + (if ($parts | length) > 1 then $parts[0] + $sec + ($parts[1:] | join("")) else $rest + "\n\n" + $sec end)
      + "\n\n" + $footer' >"$_tmp/body.md" || {
    echo "rc-post: could not compose the summary; not posting" >&2
    return 1
  }
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
  review) do_review "$@" ;;
  stale) do_stale "$@" ;;
  open) do_open "$@" ;;
  recheck) do_recheck "$@" ;;
  identity) do_identity "$@" ;;
  redact) do_redact "$@" ;;
  *)
    echo "usage: rc-post.sh <detect | open-draft | post <pr> <body-file> [envname] | review <pr> <digest-file> <ledger> [envname] [recheck-file] | stale <pr> <ledger> [envname] | open <pr> [envname] | recheck <pr> <verdicts-file> [envname] | identity [envname] | redact>" >&2
    exit 2
    ;;
esac
