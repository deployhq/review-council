#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Integration tests: the REAL scripts/rc-recheck.sh against the REAL
# scripts/rc-post.sh (issue #30). Only `gh` and `claude` are fakes.
#
# Each test first runs the real `rc-post.sh review` on a ledger, then
# "publishes" what it sent (the review body, its inline comments, one
# unresolved thread per comment) into the fake gh's state, so the recheck reads
# exactly what the full run wrote. The checkout is a real temp git repo whose
# HEAD is the fake PR's head.
#
# The fake gh is copied from tests/unit/rc-post.bats (it records argv to
# $GHLOG, reply bodies to $GHLOG.replies, dismissal bodies to $GHLOG.dismiss,
# PR-comment POST bodies to $POSTBODY / $POSTBODY.all). The fake claude is
# adapted from tests/unit/rc-recheck.bats: it answers FIXED for every finding
# whose title is listed in $D/fixed, STILL_PRESENT otherwise.
#
# Run: bats tests/unit/rc-recheck-integration.bats

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
RECHECK="$ROOT/scripts/rc-recheck.sh"
POST="$ROOT/scripts/rc-post.sh"

setup() {
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/bin" "$D/repo"
  (cd "$D/repo" && git init -q && git config user.email t@example.com && git config user.name t &&
    for i in $(seq 1 60); do echo "line $i"; done >a.rb &&
    for i in $(seq 1 60); do echo "leak $i"; done >b.rb &&
    git add a.rb b.rb && git commit -qm init)
  HEAD_SHA="$(git -C "$D/repo" rev-parse HEAD)"
  SHORT="${HEAD_SHA:0:7}"

  GHLOG="$D/ghlog"
  POSTBODY="$D/postbody"
  PATCHBODY="$D/patchbody"
  COMMENTS="$D/comments.json"
  REVIEWBODY="$D/reviewbody"
  FILES="$D/files.json"
  RCOMMENTS="$D/rcomments.json"
  REVIEWS="$D/reviews.json"
  THREADS="$D/threads.json"
  LEDGER="$D/ledger.json"
  BODY="$D/digest.md"
  : >"$GHLOG"
  printf '[]\n' >"$COMMENTS"
  printf '[]\n' >"$RCOMMENTS"
  printf '[]\n' >"$REVIEWS"
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}\n' >"$THREADS"
  # The PR's diff: a.rb lines 10-13 (so a.rb:11 and a.rb:12 go inline; b.rb is outside).
  printf '[{"filename":"a.rb","patch":"@@ -10,2 +10,4 @@\\n line 10\\n+line 11\\n+line 12\\n line 13"}]\n' >"$FILES"
  printf '<!-- rc:report -->\n<!-- rc:state {"v":1,"status":"findings"} -->\n## Digest\n<!-- rc:inline -->\n' >"$BODY"
  PR_HEAD="$HEAD_SHA"

  unset GH_TOKEN GITHUB_ACTIONS RC_PR_REQUEST_CHANGES RC_PR_BOT_TOKEN_ENV RC_RECHECK_MODEL \
    GITHUB_STEP_SUMMARY RC_POST_BIN RC_PLAN_OUT RESOLVE_FAIL
  export GHLOG POSTBODY PATCHBODY COMMENTS REVIEWBODY FILES RCOMMENTS REVIEWS THREADS PR_HEAD
  export RC_RECHECK_SUMMARY="$D/summary.md"
  install_fake_gh
  install_fake_claude
  : >"$D/fixed"
  export PATH="$D/bin:$PATH"
}

# Copied from tests/unit/rc-post.bats (POST bodies also appended to $POSTBODY.all).
install_fake_gh() {
  cat >"$D/bin/gh" <<'EOF'
#!/usr/bin/env sh
{ printf 'ARGS:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf ' TOKEN=[%s]\n' "${GH_TOKEN:-}"; } >>"$GHLOG"
[ -n "${POST_RESP:-}" ] || POST_RESP='{"html_url":"https://gh/created","id":999}'
[ -n "${PATCH_RESP:-}" ] || PATCH_RESP='{"html_url":"https://gh/updated"}'
_all="$*"
case "$1" in
  api)
    case "$_all" in
      *"pulls/5/reviews -X POST"*)
        cat >"$REVIEWBODY"
        printf '{"html_url":"https://gh/review"}\n' ;;
      *dismissals*)  cat >>"$GHLOG.dismiss"; printf '\n' >>"$GHLOG.dismiss"; printf '{}\n' ;;
      *"api graphql"*mutation*) [ -n "${RESOLVE_FAIL:-}" ] && exit 1; printf '{}\n' ;;
      *replies*)     cat >>"$GHLOG.replies"; printf '\n' >>"$GHLOG.replies"; printf '{}\n' ;;
      *"api graphql"*) cat "$THREADS" ;;
      *"pulls/5/reviews"*) cat "$REVIEWS" ;;
      *"issues/5/timeline"*) printf '[]\n' ;;
      *"pulls/5/files"*)   cat "$FILES" ;;
      *"pulls/5/comments"*) cat "$RCOMMENTS" ;;
      *"repos/owner/repo/pulls/5"*) printf '{"head":{"sha":"%s"}}\n' "$PR_HEAD" ;;
      *"-X POST"*)   cat >"$POSTBODY"; cat "$POSTBODY" >>"$POSTBODY.all"; printf '\n' >>"$POSTBODY.all"; printf '%s\n' "$POST_RESP" ;;
      *"-X PATCH"*)  cat >"$PATCHBODY"; printf '%s\n' "$PATCH_RESP" ;;
      *comments*)    cat "$COMMENTS" ;;
      *user*)        printf '{"login":"rc-bot"}\n' ;;
      *)             printf '{}\n' ;;
    esac
    ;;
  repo)
    case "$_all" in
      *defaultBranchRef*) printf '{"defaultBranchRef":{"name":"main"}}\n' ;;
      *)                  printf '{"nameWithOwner":"owner/repo"}\n' ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$D/bin/gh"
}

# Adapted from tests/unit/rc-recheck.bats: env -i drops our variables, so $D is
# baked in. FIXED for a title listed in $D/fixed, else STILL_PRESENT.
install_fake_claude() {
  printf '#!/bin/sh\nD=%s\n' "'$D'" >"$D/bin/claude"
  cat >>"$D/bin/claude" <<'EOF'
n=$(cat "$D/claude.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$D/claude.n"
cat >"$D/prompt.$n"
ans=$(awk '/^=== FINDING /{id=$3} /^title: /{sub(/^title: /, ""); print id "\t" $0}' "$D/prompt.$n" |
  while IFS='	' read -r id t; do
    if grep -qxF -- "$t" "$D/fixed"; then
      jq -nc --arg id "$id" '{id: $id, verdict: "FIXED", summary: "The nil guard is in place.",
        points: ["a.rb:12 returns early on nil", "a spec covers it"]}'
    else
      jq -nc --arg id "$id" '{id: $id, verdict: "STILL_PRESENT", summary: "", points: []}'
    fi
  done | jq -sc .)
jq -nc --arg r "$ans" '{type: "result", subtype: "success", is_error: false, result: $r,
  usage: {input_tokens: 100, cache_read_input_tokens: 0, cache_creation_input_tokens: 0, output_tokens: 7}}'
EOF
  chmod +x "$D/bin/claude"
}

# ledger <key...>: NIL (important, a.rb:12, inline), NAME (suggestion, a.rb:11,
# inline), LEAK (important, b.rb:40, outside the diff).
ledger() {
  jq -n --args '
    {NIL: {fingerprint: "a.rb::f::nil", outcome: "reported", section: "main", severity: "important",
           title: "Nil guard missing", issue: "It crashes on nil.", recommendation: "Guard it.",
           origins: [{reviewer: "claude"}], location: {path: "a.rb", line: 12}},
     NAME: {fingerprint: "a.rb::f::name", outcome: "reported", section: "main", severity: "suggestion",
           title: "Rename it", issue: "The name is vague.", location: {path: "a.rb", line: 11}},
     LEAK: {fingerprint: "b.rb::g::leak", outcome: "reported", section: "main", severity: "important",
           title: "Handle leak", issue: "The handle leaks.", location: {path: "b.rb", line: 40}}} as $f
    | {schema: "review-council/ledger", version: 1, findings: [$ARGS.positional[] | $f[.]]}' "$@" >"$LEDGER"
}

# full_review <key...>: the real `rc-post.sh review` posts the run; then the
# fake GitHub holds it: review 300 (CHANGES_REQUESTED when it requested
# changes), inline comments 70, 71, … with one unresolved thread each. The gh
# logs are cleared afterwards.
full_review() {
  ledger "$@"
  run --separate-stderr bash -c 'cd "$1" && shift && bash "$@"' _ "$D/repo" "$POST" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ] || { echo "review failed: $output $stderr"; return 1; }
  jq '[{id: 300, state: (if .event == "REQUEST_CHANGES" then "CHANGES_REQUESTED" else "COMMENTED" end),
        user: {login: "rc-bot", type: "User"}, html_url: "https://gh/r/300",
        submitted_at: "2026-01-01T00:00:00Z", body: .body}]' "$REVIEWBODY" >"$REVIEWS"
  jq '[.comments // [] | to_entries[] | {id: (70 + .key), in_reply_to_id: null,
        user: {login: "rc-bot", type: "User"}, path: .value.path, line: .value.line,
        html_url: "https://gh/c/\(70 + .key)", created_at: "2026-01-01T00:00:00Z", body: .value.body}]' \
    "$REVIEWBODY" >"$RCOMMENTS"
  threads
  : >"$GHLOG"
  rm -f "$GHLOG.replies" "$GHLOG.dismiss" "$POSTBODY" "$POSTBODY.all"
}

# threads [<id>=<resolvedBy-or-open>...]: one thread per root comment;
# unresolved unless named (e.g. 70=alice).
threads() {
  jq -n --slurpfile c "$RCOMMENTS" --args '
    ($ARGS.positional | map(split("=") | {(.[0]): .[1]}) | add // {}) as $by
    | {data: {repository: {pullRequest: {reviewThreads: {nodes: [
        $c[0][] | select(.in_reply_to_id == null) | ($by[.id | tostring] // "open") as $b
        | {id: "PRRT_\(.id)", isResolved: ($b != "open"), resolvedBy: (if $b == "open" then null else {login: $b} end),
           comments: {nodes: [{databaseId: .id}]}} ]}}}}}' "$@" >"$THREADS"
}

# cid <fingerprint>: the id of our inline comment for it.
cid() { jq -r --arg f "$1" '.[] | select(.body | contains("<!-- rc:finding \($f) -->")) | .id' "$RCOMMENTS"; }

recheck() { run --separate-stderr bash -c 'cd "$1" && shift && bash "$@"' _ "$D/repo" "$RECHECK" "$@"; }
calls() { cat "$D/claude.n" 2>/dev/null || echo 0; }
has() { printf '%s\n' "$output" | grep -qxF -- "$1" || { echo "missing: $1"; echo "--$output--"; echo "--$stderr--"; return 1; }; }
reply_body() { jq -r .body "$GHLOG.replies"; }
nreplies() { if [ -f "$GHLOG.replies" ]; then jq -s length "$GHLOG.replies"; else echo 0; fi; }

FOOT='<sub>Recheck by [Review Council](https://github.com/deployhq/review-council/) · posted by @rc-bot (not a personal comment)'

@test "integration: important FIXED + suggestion still present -> resolved reply in the new format, review dismissed" {
  full_review NIL NAME
  [ "$(jq -r '.[0].state' "$REVIEWS")" = CHANGES_REQUESTED ]
  [ "$(jq length "$RCOMMENTS")" = 2 ]
  nil="$(cid a.rb::f::nil)"
  echo "Nil guard missing" >"$D/fixed"
  recheck 5
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  [ "$(calls)" -eq 1 ]
  [ "$(grep -c '^=== FINDING ' "$D/prompt.1")" -eq 2 ]
  ! grep -qF 'Prompt for AI agents' "$D/prompt.1" || return 1
  grep -qF 'location: a.rb:12' "$D/prompt.1"
  has "fixed_inline=1"
  has "resolved=1"
  has "dismissed=1"
  # resolved the right thread, replied on the right comment, only there
  grep -qF "[id=PRRT_$nil]" "$GHLOG"
  [ "$(grep -c 'mutation' "$GHLOG")" -eq 1 ]
  grep -qF "pulls/5/comments/$nil/replies" "$GHLOG"
  [ "$(nreplies)" -eq 1 ]
  r="$(reply_body)"
  [ "$(printf '%s\n' "$r" | head -1)" = "**Looks fixed** at \`$SHORT\` · rechecked by Review Council" ]
  printf '%s\n' "$r" | grep -qxF 'The nil guard is in place.'
  printf '%s\n' "$r" | grep -qxF '<details>'
  printf '%s\n' "$r" | grep -qxF "<summary>Why we think it's fixed</summary>"
  printf '%s\n' "$r" | grep -qxF -- '- a.rb:12 returns early on nil'
  printf '%s\n' "$r" | grep -qxF -- '- a spec covers it'
  printf '%s\n' "$r" | grep -qxF '</details>'
  printf '%s\n' "$r" | grep -qxF "$FOOT · Disagree? Unresolve this conversation and the council will treat it as still open.</sub>"
  [ "$(printf '%s\n' "$r" | tail -1)" = '<!-- rc:fixed resolved -->' ]
  # dismissal
  grep -qF 'reviews/300/dismissals' "$GHLOG"
  [ "$(jq -r .message "$GHLOG.dismiss")" = "Rechecked at $SHORT: 1 of 2 open findings look fixed; no critical or important finding is left open." ]
  [ "$(jq -r .event "$GHLOG.dismiss")" = DISMISS ]
  [ ! -f "$POSTBODY" ]
  grep -qF '| 2 | 1 | 1 | 0 | 1 | 1 |' "$D/summary.md"

  # Round trip: the reply GitHub now holds reads back as fixed (we resolved it).
  jq --argjson to "$nil" --slurpfile r "$GHLOG.replies" \
    '. + [{id: 200, in_reply_to_id: $to, user: {login: "rc-bot", type: "User"}, body: $r[0].body}]' \
    "$RCOMMENTS" >"$RCOMMENTS.t" && mv "$RCOMMENTS.t" "$RCOMMENTS"
  threads "$nil=rc-bot"
  run --separate-stderr bash -c 'cd "$1" && shift && bash "$@"' _ "$D/repo" "$POST" open 5
  [ "$(printf '%s' "$output" | jq -r --argjson i "$nil" '.inline[] | select(.id == $i) | .status')" = fixed ]
}

@test "integration: a refused resolve -> plain rc:fixed reply with 'Reply here', still dismissed" {
  full_review NIL NAME
  nil="$(cid a.rb::f::nil)"
  echo "Nil guard missing" >"$D/fixed"
  RESOLVE_FAIL=1 recheck 5
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  has "fixed_inline=1"
  has "resolved=0"
  has "dismissed=1"
  [ "$(nreplies)" -eq 1 ]
  r="$(reply_body)"
  printf '%s\n' "$r" | grep -qxF "<summary>Why we think it's fixed</summary>"
  printf '%s\n' "$r" | grep -qxF "$FOOT · Disagree? Reply here and the council will treat it as still open.</sub>"
  [ "$(printf '%s\n' "$r" | tail -1)" = '<!-- rc:fixed -->' ]
  [ "$(jq -r .message "$GHLOG.dismiss")" = "Rechecked at $SHORT: 1 of 2 open findings look fixed; no critical or important finding is left open." ]

  # Round trip: a person replying after our plain rc:fixed reopens it.
  jq --argjson to "$nil" --slurpfile r "$GHLOG.replies" \
    '. + [{id: 200, in_reply_to_id: $to, user: {login: "rc-bot", type: "User"}, body: $r[0].body},
          {id: 201, in_reply_to_id: $to, user: {login: "alice", type: "User"}, body: "Still broken."}]' \
    "$RCOMMENTS" >"$RCOMMENTS.t" && mv "$RCOMMENTS.t" "$RCOMMENTS"
  run --separate-stderr bash -c 'cd "$1" && shift && bash "$@"' _ "$D/repo" "$POST" open 5
  [ "$(printf '%s' "$output" | jq -r --argjson i "$nil" '.inline[] | select(.id == $i) | .status')" = reopened ]
}

@test "integration: STILL_PRESENT -> nothing posted, no resolve, no dismissal" {
  full_review NIL NAME
  recheck 5
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  [ "$(calls)" -eq 1 ]
  has "fixed_inline=0"
  has "dismissed=0"
  has "held=1"
  [ "$(nreplies)" -eq 0 ]
  [ ! -f "$GHLOG.dismiss" ]
  [ ! -f "$POSTBODY" ]
  ! grep -qF mutation "$GHLOG" || return 1
}

@test "integration: an outside-the-diff finding judged FIXED -> one grouped PR comment, review dismissed" {
  full_review LEAK
  jq -r '.[0].body' "$REVIEWS" | grep -qxF '<!-- rc:outside-begin -->'
  jq -r '.[0].body' "$REVIEWS" | grep -qxF '<!-- rc:outside b.rb::g::leak -->'
  [ "$(jq length "$RCOMMENTS")" = 0 ]
  echo "Handle leak" >"$D/fixed"
  recheck 5
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  # the model saw its location and the code window around it
  [ "$(grep -c '^=== FINDING ' "$D/prompt.1")" -eq 1 ]
  grep -qxF 'title: Handle leak' "$D/prompt.1"
  grep -qxF 'location: b.rb:40' "$D/prompt.1"
  grep -qF 'The handle leaks.' "$D/prompt.1"
  grep -qE '^ +40\| leak 40$' "$D/prompt.1"
  grep -qE '^ +20\| leak 20$' "$D/prompt.1"
  has "outside_fixed=1"
  has "dismissed=1"
  [ "$(jq -s length "$POSTBODY.all")" -eq 1 ]
  grep -qF 'issues/5/comments' "$GHLOG"
  b="$(jq -r .body "$POSTBODY")"
  printf '%s\n' "$b" | grep -qF "**Looks fixed** at \`$SHORT\`: [Handle leak](https://gh/r/300) from an earlier review. The nil guard is in place."
  printf '%s\n' "$b" | grep -qxF "<summary>Why we think it's fixed</summary>"
  printf '%s\n' "$b" | grep -qxF '<!-- rc:outside-fixed b.rb::g::leak -->'
  [ "$(printf '%s\n' "$b" | tail -1)" = "$FOOT</sub>" ]
  [ "$(nreplies)" -eq 0 ]
  [ "$(jq -r .message "$GHLOG.dismiss")" = "Rechecked at $SHORT: 1 of 1 open findings look fixed; no critical or important finding is left open." ]

  # Round trip: once GitHub holds that comment, open reports it fixed and a
  # second recheck sends nothing to the model.
  jq --slurpfile p "$POSTBODY" '[{id: 900, user: {login: "rc-bot", type: "User"}, created_at: "2026-02-01T00:00:00Z", body: $p[0].body}]' \
    "$COMMENTS" >"$COMMENTS.t" && mv "$COMMENTS.t" "$COMMENTS"
  recheck 5
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  [ "$(jq -s length "$POSTBODY.all")" -eq 1 ]
}

@test "integration: every thread resolved by a person -> claude not called, review dismissed" {
  full_review NIL NAME
  threads "$(cid a.rb::f::nil)=alice" "$(cid a.rb::f::name)=alice"
  recheck 5
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  [ "$(calls)" -eq 0 ]
  has "candidates=0"
  has "dismissed=1"
  [ "$(nreplies)" -eq 0 ]
  ! grep -qF mutation "$GHLOG" || return 1
  [ "$(jq -r .message "$GHLOG.dismiss")" = "Rechecked at $SHORT: 0 of 0 open findings look fixed; no critical or important finding is left open." ]
}

@test "integration: --after-run with the real plan file -> the fingerprints it reported are not sent" {
  full_review NIL NAME
  # The next full run reports only the nil finding again (the plan comes from
  # the real RC_PLAN_OUT); the GitHub state stays the first run's.
  ledger NIL
  RC_PLAN_OUT="$D/plan.json" run --separate-stderr bash -c 'cd "$1" && shift && bash "$@"' _ "$D/repo" "$POST" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  jq -e '.posted == true and .reported == ["a.rb::f::nil"] and .block == true' "$D/plan.json"
  : >"$GHLOG"
  rm -f "$GHLOG.replies" "$GHLOG.dismiss" "$POSTBODY" "$POSTBODY.all"
  echo "Rename it" >"$D/fixed"
  recheck 5 --after-run "$D/plan.json"
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  [ "$(calls)" -eq 1 ]
  [ "$(grep -c '^=== FINDING ' "$D/prompt.1")" -eq 1 ]
  grep -qxF 'title: Rename it' "$D/prompt.1"
  ! grep -qF 'Nil guard missing' "$D/prompt.1" || return 1
  has "fixed_inline=1"
  grep -qF "pulls/5/comments/$(cid a.rb::f::name)/replies" "$GHLOG"
  # the run still blocks (block: true): no dismissal
  has "dismissed=0"
  [ ! -f "$GHLOG.dismiss" ]
}

@test "integration: a reopened comment is never sent to claude and keeps the block" {
  full_review NIL NAME
  nil="$(cid a.rb::f::nil)"
  echo "Nil guard missing" >"$D/fixed"
  recheck 5
  [ "$status" -eq 0 ]
  has "dismissed=1"
  # GitHub now holds our reply; a person unresolved the thread we resolved,
  # and the review is requesting changes again (a later full run).
  jq --argjson to "$nil" --slurpfile r "$GHLOG.replies" \
    '. + [{id: 200, in_reply_to_id: $to, user: {login: "rc-bot", type: "User"}, body: $r[0].body}]' \
    "$RCOMMENTS" >"$RCOMMENTS.t" && mv "$RCOMMENTS.t" "$RCOMMENTS"
  threads
  : >"$GHLOG"
  rm -f "$GHLOG.replies" "$GHLOG.dismiss" "$D/claude.n" "$D/prompt.1"
  printf 'Nil guard missing\nRename it\n' >"$D/fixed"
  recheck 5
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  [ "$(calls)" -eq 1 ]
  [ "$(grep -c '^=== FINDING ' "$D/prompt.1")" -eq 1 ]
  ! grep -qF 'Nil guard missing' "$D/prompt.1" || return 1
  grep -qxF 'title: Rename it' "$D/prompt.1"
  has "fixed_inline=1"
  ! grep -qF "pulls/5/comments/$nil/replies" "$GHLOG" || return 1
  has "dismissed=0"
  has "held=1"
  [ ! -f "$GHLOG.dismiss" ]
  grep -qF '| 1 | 1 | 0 | 1 |' "$D/summary.md"
}
