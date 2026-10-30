#!/usr/bin/env sh
# rc-post.sh — deterministic plumbing for the Review Council PR-digest posting
# engine (Step 6.6 of skills/run/SKILL.md). Report-only by default; this script
# runs ONLY when the orchestrator has resolved `pr_comments.enabled=true` AND a
# human has confirmed the post.
#
# It performs the mechanical GitHub calls and NOTHING judgemental: the
# orchestrator composes the digest markdown (from the judge ledger + triage)
# and writes the ledger JSON; this script places each finding on the diff (or
# not), renders the inline comments, and creates/updates the single marked
# digest comment. No LLM here.
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
#   review <pr> <digest-file> <ledger> [envname] [recheck-file]
#                                   Post the run's findings as inline review
#                                   comments (one review; "request changes" on a
#                                   critical/important finding), resolve the
#                                   re-checked fixed ones, then upsert the digest
#                                   with the findings that are not on the diff.
#                                   See the `review / stale` section below.
#   stale <pr> <ledger> [envname]   Print (JSON) our open inline comments whose
#                                   finding this run no longer reports.
#   redact                          Read text on stdin, write it to stdout with
#                                   likely secrets replaced by [REDACTED]; the
#                                   count goes to stderr only. Non-zero exit (and
#                                   no stdout) if redaction itself fails. Same
#                                   implementation `post` uses.
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

# Likely-secret shapes redacted from the digest before it is posted (the body is
# model-composed from review context, which may quote a credential). One
# Oniguruma regex for jq: Anthropic sk-ant-, OpenRouter sk-or-, OpenAI
# sk-proj-/sk-svcacct-/sk-admin- and legacy sk-<32+ alnum>, GitHub
# ghp_/gho_/ghs_/ghu_/ghr_ and github_pat_, Perplexity pplx-, AWS access key ids
# AKIA/ASIA, Google AIza, Slack xox[abpr]-, Stripe sk_live_/rk_live_, and PEM
# private key blocks (the whole block when its END line is there). The
# lookbehind/lookahead keep it to whole tokens; `_` is NOT in the
# lookbehind so a token wrapped in markdown italics (`_sk-ant-..._`) is still
# caught. The length floors keep ordinary text ("sk-learn", a 40-hex SHA) out.
SECRET_RE='(?<![A-Za-z0-9-])(?:sk-(?:ant|or|proj|svcacct|admin)-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|pplx-[A-Za-z0-9]{32,}|(?:AKIA|ASIA)[0-9A-Z]{16}(?![0-9A-Za-z])|AIza[0-9A-Za-z_-]{35}|xox[abpr]-[A-Za-z0-9-]{10,}|[sr]k_live_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----(?:[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----)?)'
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
  upsert_digest "$_pr" "$_payload" || return 1
  printf 'action=%s\nurl=%s\n' "$_DG_ACTION" "$_DG_URL"
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
  fi
}

# ---------------------------------------------------------------------------
# upsert_digest <pr> <payload-file>: create or update the singleton digest
# comment from a ready ({"body": ...}, already redacted) payload. Needs _repo,
# _me, _fb_login. Sets _DG_ACTION (created|updated) and _DG_URL.
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
    echo "rc-post: could not update comment $_id; posting a fresh one" >&2
  fi

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
# Input is the judge's ledger (skills/run/SKILL.md §5.5): a JSON object in the
# `review-council/ledger` v1 shape, of which this script reads
#   .findings[] | {fingerprint, outcome, section, severity, badge, title, issue,
#                  why_it_matters, recommendation, how_to_verify, origins[].reviewer,
#                  location: {path, line, line_end}}
# Everything in it is model-composed, so it is DATA: this script decides where a
# finding goes, renders it, and builds every request with jq. A reported
# finding goes inline only when its path is a file in the PR's diff (GitHub's
# own list) and its line is a right-side line of one of that file's hunks;
# everything else goes to the digest's "Outside the diff" section (placeholder
# line `<!-- rc:inline -->`, else just above the footer).
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
# posted as "request changes" (once — not again while ours is still active);
# when none is, our earlier "request changes" reviews are dismissed. If a
# person dismisses ours, the findings it listed never request changes again.
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
# joined with their review thread ({id, resolved} from GraphQL, null if unknown).
# shellcheck disable=SC2016  # jq program, not shell
OURS_JQ='
  ([ $t[0][] | .data.repository.pullRequest.reviewThreads.nodes[]? ]
   | map({key: (.comments.nodes[0].databaseId | tostring), value: {id: .id, resolved: .isResolved}})
   | from_entries) as $th
  | [ .[] | arrays | .[]
      | select((.body | type) == "string"
          and (if $me != "" then .user.login == $me
               else (.user.type == "Bot" and ($fb == "" or .user.login == $fb)) end)) ] as $mine
  # Roots we already answered "looks fixed" (resolved or not): never stale
  # again, and a finding that comes back gets a new comment.
  | ([ $mine[] | select(.in_reply_to_id != null and (.body | contains("<!-- rc:fixed -->")))
       | .in_reply_to_id | tostring ]) as $fixed
  | [ $mine[] | select(.in_reply_to_id == null)
      | (.body | capture("<!-- rc:finding (?<fp>[A-Za-z0-9._:/@+-]{1,200}) -->\\s*$") .fp) as $fp
      | {id, fp: $fp, path, line: (.line // .original_line), body, thread: $th[.id | tostring],
         fixed: (.id | tostring | IN($fixed[]))} ]'

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
    | map(. + {
        path: (.location.path // null),
        line: (if (.location.line_end | posint) then .location.line_end else .location.line end),
        start_line: .location.line,
        tracked: ((.fingerprint | type) == "string" and (.fingerprint | test("^[A-Za-z0-9._:/@+-]{1,200}$")))});
'

# The plan: what to post, list outside the diff, and resolve.
# shellcheck disable=SC2016  # jq program, not shell
PLAN_JQ='
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
  # One comment per fingerprint: a repeated fingerprint is listed, not tracked.
  | reduce .[] as $x ({seen: {}, out: []};
      if $x.tracked and .seen[$x.fingerprint] then .out += [$x + {tracked: false}]
      elif $x.tracked then .seen[$x.fingerprint] = true | .out += [$x]
      else .out += [$x] end)
  | .out
  | map(. + {md: render, loc: loc})
  | ([$ex[0][] | select(.fixed | not) | .fp] + ($cov | map(tostring))) as $have
  | map(. as $x | . + {have: ($x.tracked and ($have | index($x.fingerprint)) != null)}) as $fs
  | [ $fs[] | select((.have | not) and .tracked) | . + {a: anchor} | select(.a != null) ] as $cand
  | ([$fs[] | select(.tracked) | .fingerprint]) as $fps
  | {
      block: any($fs[]; .severity == "critical" or .severity == "important"),
      blocking: [ $fs[] | select(.severity == "critical" or .severity == "important") | if .tracked then .fingerprint else "" end ],
      kept: ([$fs[] | select(.have)] | length),
      new: [ $cand[0:$maxn][] | .a + {path, body: (.md + "\n\n<!-- rc:finding " + .fingerprint + " -->"),
                                      outside: (.loc + "\n\n" + .md)} ],
      outside: ([ $fs[] | select(.have | not) | select(. as $x | any($cand[0:$maxn][]; .fingerprint == $x.fingerprint) | not)
                  | .loc + "\n\n" + .md ]),
      stale: [ $ex[0][] | select((.fp as $fp | $fps | index($fp)) == null and (.fixed | not)
                                 and .thread != null and .thread.resolved == false) ],
    }
  | .resolve = [ .stale[] | select(.id as $i | $res | index($i)) | select(.thread.id | test("^[A-Za-z0-9_=-]+$"))
                 | {id, thread: .thread.id} ]'

# load_pr_state <pr> <dir>: write <dir>/diff.json and <dir>/ours.json. Sets
# _inline=false (and empty files) when the reviewed commit is not the PR head
# or the PR's files / review comments can't be read — then every finding goes
# in the digest and nothing is resolved. Needs _repo, _me, _fb_login.
load_pr_state() {
  printf '{}\n' >"$2/diff.json"
  printf '[]\n' >"$2/ours.json"
  _inline=true
  _local_head="$(git rev-parse HEAD 2>/dev/null)" || _local_head=""
  _pr_head="$(gh_post api "repos/$_repo/pulls/$1" 2>/dev/null | jq -r '.head.sha // empty' 2>/dev/null)" || _pr_head=""
  if [ -z "$_pr_head" ] || [ "$_local_head" != "$_pr_head" ]; then
    echo "rc-post: the reviewed commit is not the PR head; listing every finding in the digest" >&2
    _inline=false
    return 0
  fi
  # A failed thread listing is not fatal: nothing gets resolved (threads unknown).
  # shellcheck disable=SC2016  # GraphQL variables, not shell
  _threads="$(gh_post api graphql --paginate -F owner="${_repo%%/*}" -F name="${_repo#*/}" -F number="$1" \
    -f query='query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) {
        reviewThreads(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes { id isResolved comments(first: 1) { nodes { databaseId } } } } } } }' 2>/dev/null)" || _threads=""
  printf '%s' "$_threads" | jq -s '.' >"$2/threads.json" 2>/dev/null || printf '[]\n' >"$2/threads.json"
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
  jq -n --slurpfile f "$_ledger" --slurpfile ex "$_tmp/ours.json" --arg re "$SECRET_RE" "$LEDGER_DEFS"'
    ($f[0] | reported | map(select(.tracked) | .fingerprint)) as $fps
    | [ $ex[0][] | select((.fp as $fp | $fps | index($fp)) == null and (.fixed | not)
                          and .thread != null and .thread.resolved == false)
        | {id, fingerprint: .fp, path, line, body} ]'
}

# review <pr> <digest-file> <ledger> [envname] [recheck-file]
# recheck-file (optional, orchestrator-written): {"fixed": [<comment id>...],
# "covered": ["<fingerprint>"...]} — `fixed` = stale comments the re-check found
# fixed (resolved here, if still stale); `covered` = new fingerprints an earlier
# comment already covers (not posted again).
do_review() {
  _pr="${1:?rc-post: review needs <pr-number>}"
  _body="${2:?rc-post: review needs <digest-file>}"
  _ledger="${3:?rc-post: review needs <ledger-file>}"
  _tokname="${4:-}"
  _recheck="${5:-}"

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
    _covered="$(jq -c '[.covered[]? | select(type == "string" and test("^[A-Za-z0-9._:/@+-]{1,200}$"))]' "$_recheck" 2>/dev/null)" || _covered='[]'
    [ -n "$_fixed" ] || _fixed='[]'
    [ -n "$_covered" ] || _covered='[]'
  fi

  # Run status from the digest's rc:state line (script-produced, line 2).
  _status="$(sed -n '2s/^<!-- rc:state \(.*\) -->$/\1/p' "$_body" | jq -r '.status // empty' 2>/dev/null)" || _status=""

  if ! jq -n --slurpfile f "$_ledger" --slurpfile d "$_tmp/diff.json" --slurpfile ex "$_tmp/ours.json" \
    --argjson inline "$_inline" --argjson maxn "$MAX_INLINE" --argjson cov "$_covered" --argjson res "$_fixed" \
    --arg re "$SECRET_RE" \
    "$LEDGER_DEFS"' $f[0] | '"$PLAN_JQ" >"$_tmp/plan.json" 2>/dev/null; then
    echo "rc-post: could not place the findings; posting the digest only" >&2
    printf '{"block":false,"blocking":[],"kept":0,"new":[],"outside":[],"stale":[],"resolve":[]}\n' >"$_tmp/plan.json"
  fi

  # Our reviews: `active` = ours still requesting changes; `ack` = blocking
  # fingerprints (from the hidden `rc:blocking` line of each "request changes"
  # review we posted) that a PERSON dismissed — those never block again; only
  # a new critical/important finding does. The dismisser comes from the PR
  # timeline; if it can't be read, every dismissed review of ours counts as a
  # person's (never re-raise by mistake). A failed reviews listing must not
  # look like an empty one: then "unknown" — no new block, no dismissal.
  _active=""
  _ack='[]'
  # Every review we post carries `<!-- rc:review -->`: another bot's (or
  # another workflow's) review is never ours to count or dismiss. The
  # timeline goes through a file, never argv (Linux caps one argument at
  # 128 KB, and a busy PR's timeline is bigger).
  if _revs="$(gh_post api --paginate "repos/$_repo/pulls/$_pr/reviews" 2>/dev/null)"; then
    printf 'null\n' >"$_tmp/tl.json"
    if _tlraw="$(gh_post api --paginate "repos/$_repo/issues/$_pr/timeline" 2>/dev/null)"; then
      printf '%s' "$_tlraw" | jq -s -c '.' >"$_tmp/tl.json" 2>/dev/null || printf 'null\n' >"$_tmp/tl.json"
    fi
    # shellcheck disable=SC2016  # jq program, not shell
    _rv="$(printf '%s' "$_revs" | jq -s -c --arg me "$_me" --arg fb "$_fb_login" --slurpfile tl "$_tmp/tl.json" '
        [ .[] | arrays | .[]
          | select((.body // "" | contains("<!-- rc:review -->"))
              and (if $me != "" then .user.login == $me
                   else (.user.type == "Bot" and ($fb == "" or .user.login == $fb)) end)) ] as $ours
        # A person = a User actor other than the identity we post as.
        | (if $tl[0] == null then null
           else [ $tl[0][] | arrays | .[]
                  | select(.event == "review_dismissed" and .actor.type == "User" and .actor.login != $me)
                  | .dismissed_review.review_id | tostring ] end) as $human
        | { active: [ $ours[] | select(.state == "CHANGES_REQUESTED") | .id ],
            ack: ([ $ours[] | select(.state == "DISMISSED") | . as $r
                    | select($human == null or ($r.id | tostring | IN($human[])))
                    | (.body // "") | capture("<!-- rc:blocking (?<l>[A-Za-z0-9._:/@+ -]*) -->").l
                    | split(" ")[] | select(. != "") ] | unique) }' 2>/dev/null)" || _rv=""
    if [ -n "$_rv" ]; then
      _active="$(printf '%s' "$_rv" | jq -c '.active')"
      _ack="$(printf '%s' "$_rv" | jq -c '.ack')"
    else
      echo "rc-post: could not read our earlier reviews; not requesting changes or dismissing this run" >&2
    fi
  fi
  _block="$(jq -r '.block' "$_tmp/plan.json")"
  # Raise a block only for a blocking finding a person hasn't already waved
  # through (an untracked fingerprint, "", always counts as new).
  _raise="$(jq -r --argjson ack "$_ack" '[.blocking[] | select(. == "" or (. as $f | $ack | index($f)) == null)] | length > 0' "$_tmp/plan.json")"
  _n_new="$(jq '.new | length' "$_tmp/plan.json")"

  # 1. One review: "request changes" when blocking findings exist and none of
  #    ours already blocks; else a plain comment, only if there is something
  #    to post inline. GitHub rejects the whole review on one bad line (and
  #    refuses "request changes" on a PR we authored), so a failed request
  #    retries as a comment, and a failed comment moves the inline findings
  #    to the digest.
  _event=COMMENT
  # Only on the reviewed head (_inline): never block or dismiss a commit we
  # didn't review.
  if [ "$_inline" = true ] && [ "$_raise" = true ] && [ "$_active" = '[]' ]; then _event=REQUEST_CHANGES; fi
  _review_url=""
  _posted=0
  for _ev in $_event COMMENT; do
    [ "$_ev" = REQUEST_CHANGES ] || [ "$_n_new" -gt 0 ] || break
    jq --arg sha "$_pr_head" --arg ev "$_ev" '{commit_id: $sha, event: $ev,
        body: ((if $ev == "REQUEST_CHANGES" then "Review Council found critical or important findings. Requesting changes. "
                else "" end)
               + "The summary comment on this PR has the full report.\n\n---\n\n<sub>Review done with [Review Council](https://github.com/deployhq/review-council/)</sub>"
               + "\n\n<!-- rc:review -->"
               + (if $ev == "REQUEST_CHANGES"
                  then "\n\n<!-- rc:blocking " + ([.blocking[] | select(. != "")] | join(" ")) + " -->" else "" end)),
        comments: [.new[] | del(.outside)]}' "$_tmp/plan.json" >"$_tmp/review.raw"
    if redact_file "$_tmp/review.raw" "$_tmp/review.json" \
      && _review_url="$(gh_post api "repos/$_repo/pulls/$_pr/reviews" -X POST --input - <"$_tmp/review.json" 2>/dev/null \
        | jq -r '.html_url // empty' 2>/dev/null)" && [ -n "$_review_url" ]; then
      _posted=1
      _event="$_ev"
      break
    fi
    _review_url=""
    echo "rc-post: GitHub did not accept the review as $_ev" >&2
    [ "$_ev" = COMMENT ] && break
  done
  if [ "$_posted" = 0 ] && [ "$_n_new" -gt 0 ]; then
    echo "rc-post: listing the inline findings in the digest instead" >&2
    jq '.outside += [.new[].outside] | .new = []' "$_tmp/plan.json" >"$_tmp/plan2.json" && mv "$_tmp/plan2.json" "$_tmp/plan.json"
    _n_new=0
  fi

  # 2. Resolve the stale comments the re-check found fixed; 3. dismiss our
  #    "request changes" when the run is clean. Neither on a degraded run.
  _n_res=0
  _n_dis=0
  _short="$(printf '%s' "$_pr_head" | cut -c1-7)"
  if [ "$_status" != degraded ]; then
    jq -r '.resolve[] | "\(.id) \(.thread)"' "$_tmp/plan.json" >"$_tmp/resolve.txt"
    # Resolve first, then one marked reply saying how it went. The marker makes
    # the comment never stale again, so a refused resolve (GitHub may refuse
    # the Actions token) costs one reply, not one per run.
    while read -r _cid _tid; do
      # shellcheck disable=SC2016  # GraphQL variables, not shell
      if gh_post api graphql -f id="$_tid" \
        -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' >/dev/null 2>&1; then
        _n_res=$((_n_res + 1))
        _rmsg="Re-checked at $_short: this looks fixed. Resolved."
      else
        echo "rc-post: could not resolve the thread of inline comment $_cid" >&2
        _rmsg="Re-checked at $_short: this looks fixed. (The thread could not be resolved automatically.)"
      fi
      jq -n --arg m "$_rmsg" '{body: ($m + "\n\n<!-- rc:fixed -->")}' >"$_tmp/reply.json"
      gh_post api "repos/$_repo/pulls/$_pr/comments/$_cid/replies" -X POST --input - <"$_tmp/reply.json" >/dev/null 2>&1 \
        || echo "rc-post: could not reply on inline comment $_cid" >&2
    done <"$_tmp/resolve.txt"
    # Dismiss only on a run the rc:state line calls clean (no critical or
    # important finding), so an empty or unreadable ledger never lifts a block.
    if [ "$_inline" = true ] && [ "$_block" = false ] && [ "$_status" = clean ] \
      && [ -n "$_active" ] && [ "$_active" != '[]' ]; then
      printf '%s' "$_active" | jq -r '.[]' >"$_tmp/dismiss.txt"
      while read -r _rid; do
        jq -n --arg s "$_short" '{event: "DISMISS", message: "No critical or important findings in the Review Council review of \($s)."}' >"$_tmp/dismiss.json"
        if gh_post api "repos/$_repo/pulls/$_pr/reviews/$_rid/dismissals" -X PUT --input - <"$_tmp/dismiss.json" >/dev/null 2>&1; then
          _n_dis=$((_n_dis + 1))
        else
          echo "rc-post: could not dismiss review $_rid" >&2
        fi
      done <"$_tmp/dismiss.txt"
    fi
  fi

  # 4. The digest, with the inline summary and the findings outside the diff.
  jq -n -r --rawfile dg "$_body" --slurpfile p "$_tmp/plan.json" --arg mark "$INLINE_MARK" \
    --arg url "$_review_url" --argjson nn "$_n_new" --argjson nr "$_n_res" '
    ($p[0].outside) as $o
    | ([ (if $nn > 0 then "\($nn) new inline comment(s) in [this review](\($url))" else empty end),
         (if $p[0].kept > 0 then "\($p[0].kept) already commented" else empty end),
         (if $nr > 0 then "\($nr) resolved as fixed" else empty end) ]
       | if length == 0 then "No inline comments on the diff." else "**On the diff:** " + join(" · ") + "." end) as $line
    | ("<details>\n<summary>What the tags mean</summary>\n\n"
       + "- `[verified]` — backed by a tool: a secret or known-CVE scanner hit, or a lint/security rule a reviewer confirmed.\n"
       + "- `[cross-reviewed]` — raised by reviewers from two or more model families, or confirmed by a different family when double-checked.\n"
       + "- `[1 reviewer · unverified]` — only Claude-family reviewers ran, so no other family could check it.\n"
       + "- `[unverified]` — the double-check could not confirm or refute it (or ran out of time).\n"
       + "- `[tool-only:<rule>]` — a lint or security rule fired and no reviewer confirmed it.\n\n"
       + "</details>") as $legend
    # GitHub caps a comment at 65,536 characters: keep the findings that fit
    # in about 60,000 and count the rest.
    | (60000 - ($dg | length) - ($line | length) - ($legend | length) - 200) as $room
    | (reduce $o[] as $x ({used: 0, kept: [], more: 0};
         if .more == 0 and .used + ($x | length) + 9 <= $room
         then .used += ($x | length) + 9 | .kept += [$x] else .more += 1 end)) as $fit
    | ($line + "\n\n" + $legend
       + (if ($o | length) > 0
          then "\n\n### Outside the diff (\($o | length))\n\n" + ($fit.kept | join("\n\n---\n\n"))
               + (if $fit.more > 0 then "\n\n_\($fit.more) more not shown: too long for one comment. The run'"'"'s report lists them._" else "" end)
          else "" end)) as $sec
    # split/join, not index/rindex: jq 1.7 returns byte offsets for those,
    # which corrupts the splice as soon as the digest has non-ASCII text.
    | ($dg | split($mark)) as $parts
    | if ($parts | length) > 1 then $parts[0] + $sec + ($parts[1:] | join($mark))
      else ($dg | split("\n---\n")) as $f
      | if ($f | length) > 1
        then ($f[:-1] | join("\n---\n")) + "\n\n" + $sec + "\n" + "\n---\n" + $f[-1]
        else $dg + "\n\n" + $sec + "\n" end
      end' >"$_tmp/digest.md" || {
    echo "rc-post: could not compose the digest; not posting it" >&2
    return 1
  }
  if ! redact_file "$_tmp/digest.md" "$_tmp/digest.red" \
    || ! jq -Rs '{body: .}' "$_tmp/digest.red" >"$_tmp/digest.json" 2>/dev/null; then
    echo "rc-post: could not scan the digest for secrets; not posting it" >&2
    return 1
  fi
  [ "$_RED_N" = 0 ] || echo "rc-post: redacted $_RED_N likely secret(s) from the digest before posting" >&2
  upsert_digest "$_pr" "$_tmp/digest.json" || return 1

  printf 'action=%s\nurl=%s\n' "$_DG_ACTION" "$_DG_URL"
  printf 'review_url=%s\nreview_event=%s\ninline_new=%s\nkept=%s\nresolved=%s\ndismissed=%s\noutside=%s\n' \
    "$_review_url" "$([ -n "$_review_url" ] && echo "$_event")" "$_n_new" "$(jq '.kept' "$_tmp/plan.json")" \
    "$_n_res" "$_n_dis" "$(jq '.outside | length' "$_tmp/plan.json")"
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
  redact) do_redact "$@" ;;
  *)
    echo "usage: rc-post.sh <detect | open-draft | post <pr> <body-file> [envname] | review <pr> <digest-file> <ledger> [envname] [recheck-file] | stale <pr> <ledger> [envname] | redact>" >&2
    exit 2
    ;;
esac
