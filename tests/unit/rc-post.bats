#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for scripts/rc-post.sh — the deterministic PR-digest posting engine.
#
# Uses a FAKE `gh` (and, for open-draft, a fake `git`) on a sandboxed PATH
# ($FAKEDIR:$SYSBIN) so no network / real GitHub is touched. The fakes record
# their argv (and the GH_TOKEN they saw) to $GHLOG, capture POST/PATCH request
# bodies, and return canned JSON from files/env the test sets. `jq` is the real
# one (symlinked into $SYSBIN).
#
# Run: bats tests/unit/rc-post.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/rc-post.sh"

setup() {
  FAKEDIR="$BATS_TEST_TMPDIR/fakebin"
  SYSBIN="$BATS_TEST_TMPDIR/sysbin"
  mkdir -p "$FAKEDIR" "$SYSBIN"
  for _c in sh env jq cat printf grep sed head tr mktemp rm mv cut cp wc; do
    _p="$(command -v "$_c" 2>/dev/null || true)"
    [ -n "$_p" ] && ln -sf "$_p" "$SYSBIN/$_c"
  done
  SANDBOX="$FAKEDIR:$SYSBIN"

  GHLOG="$BATS_TEST_TMPDIR/ghlog"
  POSTBODY="$BATS_TEST_TMPDIR/postbody"
  PATCHBODY="$BATS_TEST_TMPDIR/patchbody"
  COMMENTS="$BATS_TEST_TMPDIR/comments.json"
  PRVIEW="$BATS_TEST_TMPDIR/prview.json"
  BODY="$BATS_TEST_TMPDIR/digest.md"
  # review / stale fixtures (pull-request review API)
  REVIEWBODY="$BATS_TEST_TMPDIR/reviewbody"
  FILES="$BATS_TEST_TMPDIR/files.json"
  RCOMMENTS="$BATS_TEST_TMPDIR/rcomments.json"
  REVIEWS="$BATS_TEST_TMPDIR/reviews.json"
  THREADS="$BATS_TEST_TMPDIR/threads.json"
  LEDGER="$BATS_TEST_TMPDIR/ledger.json"
  printf '[]\n' >"$RCOMMENTS"
  printf '[]\n' >"$REVIEWS"
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}\n' >"$THREADS"
  : >"$GHLOG"
  printf '[]\n' >"$COMMENTS"      # default: no existing comments
  rm -f "$PRVIEW"                 # default: no PR (gh pr view exits 1)
  printf '<!-- rc:report -->\n## Digest\nhello\n' >"$BODY"

  # The test env must not leak a GH_TOKEN into the fake (would mask the
  # user-identity assertions).
  unset GH_TOKEN
  # Nor GITHUB_ACTIONS (set when this suite itself runs in Actions): it narrows
  # the bot-fallback match, so tests opt in to it explicitly.
  unset GITHUB_ACTIONS
  # Nor the request-changes switch: each test sets it when it needs it.
  unset RC_PR_REQUEST_CHANGES

  install_fake_gh
}

# has_line <needle>: substring match against $output.
has() { printf '%s\n' "$output" | grep -qF -- "$1" || { echo "missing: $1"; echo "--$output--"; return 1; }; }
logged() { grep -qF -- "$1" "$GHLOG" || { echo "not in gh log: $1"; cat "$GHLOG"; return 1; }; }

install_fake_gh() {
  cat >"$FAKEDIR/gh" <<'EOF'
#!/usr/bin/env sh
{ printf 'ARGS:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf ' TOKEN=[%s]\n' "${GH_TOKEN:-}"; } >>"$GHLOG"
# Defaults via plain conditional — `${VAR:-{...}}` would swallow a brace.
[ -n "${POST_RESP:-}" ] || POST_RESP='{"html_url":"https://gh/created","id":999}'
[ -n "${PATCH_RESP:-}" ] || PATCH_RESP='{"html_url":"https://gh/updated"}'
_all="$*"
case "$1" in
  api)
    case "$_all" in
      # --- pull-request review API (review / stale) ---
      *"pulls/5/reviews -X POST"*)
        cat >"$REVIEWBODY"
        cp "$REVIEWBODY" "$REVIEWBODY.$(jq -r .event "$REVIEWBODY")"
        [ -n "${REVIEW_FAIL:-}" ] && exit 1
        [ -n "${REVIEW_FAIL_RC:-}" ] && grep -qF REQUEST_CHANGES "$REVIEWBODY" && exit 1
        printf '{"html_url":"https://gh/review"}\n' ;;
      *dismissals*)  cat >>"$GHLOG.dismiss"; printf '\n' >>"$GHLOG.dismiss"; printf '{}\n' ;;
      *"api graphql"*mutation*) [ -n "${RESOLVE_FAIL:-}" ] && exit 1; printf '{}\n' ;;
      *replies*)     cat >>"$GHLOG.replies"; printf '\n' >>"$GHLOG.replies"; printf '{}\n' ;;
      *"api graphql"*) [ -n "${THREADS_FAIL:-}" ] && exit 1; cat "$THREADS" ;;
      *"pulls/5/reviews"*) [ -n "${REVIEWS_FAIL:-}" ] && exit 1; cat "$REVIEWS" ;;
      *"issues/5/timeline"*) [ -n "${TIMELINE_FAIL:-}" ] && exit 1; cat "${TIMELINE:-/dev/null}" 2>/dev/null || printf '[]\n' ;;
      *"pulls/5/files"*)   cat "$FILES" ;;
      *"pulls/5/comments"*) cat "$RCOMMENTS" ;;
      *"repos/owner/repo/pulls/5"*) printf '{"head":{"sha":"%s"}}\n' "${PR_HEAD:-1111111111111111111111111111111111111111}" ;;
      # --- issue comments (the digest) ---
      *"-X POST"*)   cat >"$POSTBODY";  printf '%s\n' "$POST_RESP" ;;
      *"-X PATCH"*)  cat >"$PATCHBODY"; printf '%s\n' "$PATCH_RESP" ;;
      *comments*)    [ -n "${LIST_FAIL:-}" ] && exit 3; cat "$COMMENTS" ;;
      *user*)        [ -n "${USER_FAIL:-}" ] && exit 1; printf '{"login":"rc-bot"}\n' ;;
      *)             printf '{}\n' ;;
    esac
    ;;
  pr)
    case "$2" in
      view)   cat "$PRVIEW" 2>/dev/null || exit 1 ;;
      create) printf 'https://github.com/owner/repo/pull/7\n' ;;
    esac
    ;;
  repo)
    case "$_all" in
      *defaultBranchRef*) printf '{"defaultBranchRef":{"name":"main"}}\n' ;;
      *)                  printf '{"nameWithOwner":"owner/repo"}\n' ;;
    esac
    ;;
esac
EOF
  chmod +x "$FAKEDIR/gh"
  export GHLOG POSTBODY PATCHBODY COMMENTS PRVIEW REVIEWBODY FILES RCOMMENTS REVIEWS THREADS
}

install_fake_git() {
  cat >"$FAKEDIR/git" <<'EOF'
#!/usr/bin/env sh
case "$*" in
  "rev-parse --abbrev-ref HEAD")        printf '%s\n' "${GIT_BRANCH:-feature}" ;;
  "rev-parse HEAD")                     printf '%s\n' "${GIT_HEAD:-1111111111111111111111111111111111111111}" ;;
  "rev-parse --abbrev-ref @{upstream}") [ "${GIT_HAS_UPSTREAM:-1}" = 1 ] && exit 0 || exit 1 ;;
  push*)                                exit 0 ;;
  "show HEAD:"*)                        f="${GIT_SHOW_DIR:-/nonexistent}/${2#HEAD:}"
                                        [ -f "$f" ] && cat "$f" || exit 128 ;;
  *)                                    exit 0 ;;
esac
EOF
  chmod +x "$FAKEDIR/git"
}

# ---- post: create / update ------------------------------------------------

@test "post: creates a new comment when none is marked" {
  PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  has "action=created"
  has "url=https://gh/created"
  logged "[POST]"
  ! grep -qF -- "[PATCH]" "$GHLOG"
}

@test "post: sends the digest body verbatim (jq -Rs envelope)" {
  PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  # the captured POST payload is {"body": "<file contents>"}
  run jq -r '.body' "$POSTBODY"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF '<!-- rc:report -->'
  printf '%s\n' "$output" | grep -qF 'hello'
  # ...followed by the shared footer.
  [ "$(printf '%s\n' "$output" | grep -v '^$' | tail -1)" = '<sub>Review done with [Review Council](https://github.com/deployhq/review-council/) · posted by @rc-bot (not a personal comment)</sub>' ]
}

@test "post: updates the marked comment in place (idempotent singleton)" {
  printf '[{"id":11,"user":{"login":"rc-bot"},"body":"noise"},{"id":42,"user":{"login":"rc-bot"},"body":"x <!-- rc:report --> y"}]\n' >"$COMMENTS"
  PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  has "action=updated"
  logged "issues/comments/42"
  logged "[PATCH]"
  ! grep -qF -- "[POST]" "$GHLOG"
}

@test "post: picks the most-recent marked comment when several exist" {
  # Out of id order on purpose — selection must be by id (max), not array position.
  printf '[{"id":77,"user":{"login":"rc-bot"},"body":"new <!-- rc:report -->"},{"id":42,"user":{"login":"rc-bot"},"body":"old <!-- rc:report -->"}]\n' >"$COMMENTS"
  PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  logged "issues/comments/77"
  ! grep -qF -- "issues/comments/42" "$GHLOG"
}

@test "post: a failed update falls back to creating a fresh comment" {
  printf '[{"id":42,"user":{"login":"rc-bot"},"body":"<!-- rc:report -->"}]\n' >"$COMMENTS"
  # PATCH returns no html_url -> treated as failure -> POST fallback
  PATCH_RESP='{}' PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  has "action=created"
  logged "[PATCH]"
  logged "[POST]"
}

@test "post: a marked comment authored by someone else is NOT touched (no hijack)" {
  # The marker is a public string; a third party planting it must not get their
  # comment edited under our token. We author as 'rc-bot' (the fake's gh api user).
  printf '[{"id":42,"user":{"login":"attacker"},"body":"<!-- rc:report --> pwn"}]\n' >"$COMMENTS"
  PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  has "action=created"
  ! grep -qF -- "issues/comments/42" "$GHLOG"
}

@test "post: unresolved identity (App token) matches only a BOT-authored marked comment" {
  # gh api user fails (installation token) -> _me empty -> fall back to Bot-typed.
  printf '[{"id":42,"user":{"login":"review-council[bot]","type":"Bot"},"body":"<!-- rc:report -->"}]\n' >"$COMMENTS"
  USER_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  has "action=updated"
  logged "issues/comments/42"
}

@test "post: unresolved identity ignores a USER-authored marked comment (no hijack)" {
  # A human attacker plants a marked comment (type User); with _me empty it must
  # NOT be selected — we create our own instead.
  printf '[{"id":42,"user":{"login":"attacker","type":"User"},"body":"<!-- rc:report --> pwn"}]\n' >"$COMMENTS"
  USER_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  has "action=created"
  ! grep -qF -- "issues/comments/42" "$GHLOG"
}

@test "post: CI GITHUB_TOKEN (gh api user 403) re-run UPDATES the github-actions[bot] digest" {
  # In GitHub Actions the GITHUB_TOKEN cannot call /user (403) -> _me empty ->
  # Bot-authored matching. A re-run must PATCH the existing bot digest, not add
  # a second one, and must leave a human's marked comment alone.
  printf '[{"id":7,"user":{"login":"someone","type":"User"},"body":"<!-- rc:report --> quoted"},{"id":42,"user":{"login":"github-actions[bot]","type":"Bot"},"body":"<!-- rc:report --> old"}]\n' >"$COMMENTS"
  GITHUB_ACTIONS=true GH_TOKEN=ghs_ci USER_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  has "action=updated"
  logged "issues/comments/42"
  ! grep -qF -- "issues/comments/7" "$GHLOG" || return 1
  ! grep -qF -- "[POST]" "$GHLOG" || return 1
}

@test "post: unresolved identity ignores a Bot comment that only CONTAINS the marker" {
  # The fallback requires the body to START with the marker; another bot quoting
  # it mid-text must not be hijacked.
  printf '[{"id":42,"user":{"login":"other[bot]","type":"Bot"},"body":"see <!-- rc:report --> quoted"}]\n' >"$COMMENTS"
  USER_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  has "action=created"
  ! grep -qF -- "issues/comments/42" "$GHLOG" || return 1
}

@test "post: under GITHUB_ACTIONS (no bot token) only github-actions[bot] is matched" {
  printf '[{"id":50,"user":{"login":"other[bot]","type":"Bot"},"body":"<!-- rc:report --> theirs"},{"id":42,"user":{"login":"github-actions[bot]","type":"Bot"},"body":"<!-- rc:report --> old"}]\n' >"$COMMENTS"
  GITHUB_ACTIONS=true USER_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  has "action=updated"
  logged "issues/comments/42"
  ! grep -qF -- "issues/comments/50" "$GHLOG" || return 1
}

@test "post: under GITHUB_ACTIONS another bot's marked comment alone is not updated" {
  printf '[{"id":50,"user":{"login":"other[bot]","type":"Bot"},"body":"<!-- rc:report --> theirs"}]\n' >"$COMMENTS"
  GITHUB_ACTIONS=true USER_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  has "action=created"
  ! grep -qF -- "issues/comments/50" "$GHLOG" || return 1
}

@test "post: GITHUB_ACTIONS with a bot token keeps the any-Bot fallback" {
  # Posting as a custom bot (App token) in Actions: the login is not
  # github-actions[bot], so the narrowing must not apply.
  printf '[{"id":42,"user":{"login":"review-council[bot]","type":"Bot"},"body":"<!-- rc:report --> old"}]\n' >"$COMMENTS"
  RC_BOT_TOKEN=tok GITHUB_ACTIONS=true USER_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY" RC_BOT_TOKEN
  [ "$status" -eq 0 ]
  has "action=updated"
  logged "issues/comments/42"
}

@test "post: a failed comment listing does NOT create a duplicate (fail-soft)" {
  # If we can't read existing comments we must not POST a new one — that would
  # duplicate an existing digest. Expect a hard non-zero, no POST.
  LIST_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -ne 0 ]
  ! grep -qF -- "[POST]" "$GHLOG"
}

@test "post: a failed create is reported as a non-zero exit (fail-soft)" {
  POST_RESP='{}' PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -ne 0 ]
  printf '%s\n' "$stderr" 2>/dev/null | grep -qiF 'failed' || printf '%s\n' "$output" | grep -qiF 'failed'
}

@test "post: a null-body comment in the list is skipped without a jq error" {
  printf '[{"id":9,"user":{"login":"rc-bot"},"body":null},{"id":42,"user":{"login":"rc-bot"},"body":"<!-- rc:report -->"}]\n' >"$COMMENTS"
  PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  has "action=updated"
  logged "issues/comments/42"
}

# ---- post: guards ---------------------------------------------------------

@test "post: refuses a body that is not a digest (missing marker)" {
  printf 'just some text, no marker\n' >"$BODY"
  PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -ne 0 ]
  ! grep -qF -- "[POST]" "$GHLOG"
}

@test "post: refuses a non-numeric PR number (path safety)" {
  PATH="$SANDBOX" run "$SCRIPT" post "5/../foo" "$BODY"
  [ "$status" -ne 0 ]
  ! grep -qF -- "[POST]" "$GHLOG"
}

@test "post: refuses a missing body file" {
  PATH="$SANDBOX" run "$SCRIPT" post 5 "$BATS_TEST_TMPDIR/nope.md"
  [ "$status" -ne 0 ]
}

# ---- post: identity -------------------------------------------------------

@test "post: no envname -> posts as the gh user (no GH_TOKEN)" {
  PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  grep -qF 'TOKEN=[]' "$GHLOG"
  ! grep -qF 'TOKEN=[secret-tok]' "$GHLOG"
}

@test "post: a set bot-token env var -> posts as the bot (GH_TOKEN applied)" {
  MY_BOT=secret-tok PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY" MY_BOT
  [ "$status" -eq 0 ]
  grep -qF 'TOKEN=[secret-tok]' "$GHLOG"
}

@test "post: named env var unset -> falls back to the gh user, not a failure" {
  PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY" RC_PR_BOT_TOKEN
  [ "$status" -eq 0 ]
  grep -qF 'TOKEN=[]' "$GHLOG"
}

@test "post: an invalid envname is refused before indirect expansion" {
  run env PATH="$SANDBOX" "$SCRIPT" post 5 "$BODY" "BAD;id"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'action=' || true   # still posts (as user)
  grep -qF 'TOKEN=[]' "$GHLOG"
}

# ---- detect ---------------------------------------------------------------

@test "detect: reports an open PR" {
  printf '{"number":5,"url":"https://gh/pr/5","headRefOid":"abc123","state":"OPEN"}\n' >"$PRVIEW"
  PATH="$SANDBOX" run "$SCRIPT" detect
  [ "$status" -eq 0 ]
  has "pr=5"
  has "url=https://gh/pr/5"
  has "head=abc123"
}

@test "detect: no PR -> pr= (empty), exit 0" {
  PATH="$SANDBOX" run "$SCRIPT" detect
  [ "$status" -eq 0 ]
  has "pr="
  ! printf '%s\n' "$output" | grep -qE 'pr=[0-9]'
}

@test "detect: a closed PR is not a post target" {
  printf '{"number":5,"url":"u","headRefOid":"h","state":"CLOSED"}\n' >"$PRVIEW"
  PATH="$SANDBOX" run "$SCRIPT" detect
  [ "$status" -eq 0 ]
  has "pr="
  ! printf '%s\n' "$output" | grep -qE 'pr=[0-9]'
}

# ---- open-draft -----------------------------------------------------------

@test "open-draft: refuses on the default branch" {
  install_fake_git
  GIT_BRANCH=main PATH="$SANDBOX" run "$SCRIPT" open-draft
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qiF 'default branch' || printf '%s\n' "$stderr" 2>/dev/null | grep -qiF 'default branch'
}

@test "open-draft: opens a draft PR from a feature branch" {
  install_fake_git
  GIT_BRANCH=feature PATH="$SANDBOX" run "$SCRIPT" open-draft
  [ "$status" -eq 0 ]
  has "url=https://github.com/owner/repo/pull/7"
  logged "[pr] [create]"
}

# ---- dispatch -------------------------------------------------------------

@test "unknown subcommand -> usage, exit 2" {
  PATH="$SANDBOX" run "$SCRIPT" frobnicate
  [ "$status" -eq 2 ]
}

# ---- post: secret redaction ------------------------------------------------
# Fixtures are built by string concatenation so no full token literal ever sits
# in this (public) file; the values are obviously fake but match the shapes.

FAKE32="FAKEfakeFAKEfakeFAKEfakeFAKEfake"

# post_body <text>: post a digest containing <text>; leaves the sent body in $sent.
post_body() {
  printf '<!-- rc:report -->\n## Digest\n%s\n' "$1" >"$BODY"
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  sent="$(jq -r '.body' "$POSTBODY")"
}

redacts() {
  _tok="$1"
  post_body "leaked: $_tok here"
  printf '%s' "$sent" | grep -qF 'leaked: [REDACTED] here' || { echo "not redacted: $sent"; return 1; }
  ! printf '%s' "$sent" | grep -qF -- "$_tok" || return 1
  printf '%s' "$stderr" | grep -qF 'redacted 1 likely secret(s)'
  # the note never echoes the value
  ! printf '%s' "$stderr" | grep -qF -- "$_tok" || return 1
}

@test "redact: Anthropic sk-ant- key" { redacts "sk-ant-""api03-$FAKE32"; }
@test "redact: OpenRouter sk-or- key" { redacts "sk-or-""v1-$FAKE32"; }
@test "redact: OpenAI sk-proj- key" { redacts "sk-proj-""$FAKE32"; }
@test "redact: OpenAI legacy sk- key" { redacts "sk-""${FAKE32}1234"; }
@test "redact: GitHub ghp_ token" { redacts "ghp_""${FAKE32}0000"; }
@test "redact: GitHub gho_ token" { redacts "gho_""${FAKE32}0000"; }
@test "redact: GitHub ghs_ token" { redacts "ghs_""${FAKE32}0000"; }
@test "redact: GitHub github_pat_ token" { redacts "github_pat_""11FAKE_${FAKE32}"; }
@test "redact: AWS AKIA access key id" { redacts "AKIA""FAKEFAKEFAKEFAKE"; }
@test "redact: Perplexity pplx- key" { redacts "pplx-""$FAKE32"; }

@test "redact: a token in markdown italics (leading underscore) is caught" {
  _tok="sk-ant-""api03-$FAKE32"
  post_body "leaked: _${_tok}_ here"
  printf '%s' "$sent" | grep -qF 'leaked: _[REDACTED] here' || { echo "not redacted: $sent"; return 1; }
  ! printf '%s' "$sent" | grep -qF -- "$_tok" || return 1
}

@test "redact: counts several secrets, keeps the marker, still posts" {
  post_body "a $(printf '%s' "ghp_""${FAKE32}0000") b $(printf '%s' "AKIA""FAKEFAKEFAKEFAKE")"
  has "action=created"
  printf '%s' "$sent" | grep -qF '<!-- rc:report -->'
  [ "$(printf '%s' "$sent" | grep -oF '[REDACTED]' | wc -l | tr -d ' ')" -eq 2 ]
  printf '%s' "$stderr" | grep -qF 'redacted 2 likely secret(s)'
}

@test "redact: redacts the PATCH (update) body too" {
  printf '[{"id":42,"user":{"login":"rc-bot"},"body":"<!-- rc:report -->"}]\n' >"$COMMENTS"
  printf '<!-- rc:report -->\nkey %s\n' "sk-ant-""api03-$FAKE32" >"$BODY"
  PATH="$SANDBOX" run "$SCRIPT" post 5 "$BODY"
  [ "$status" -eq 0 ]
  has "action=updated"
  jq -r '.body' "$PATCHBODY" | grep -qF 'key [REDACTED]'
}

@test "redact: no false positive on ordinary text (sk-learn, a SHA, prose)" {
  _txt="uses sk-learn and scikit-learn; sk-learn-compatible-transformer-pipeline; commit 0123456789abcdef0123456789abcdef01234567; AKIAshort; the ghp_ prefix; task-ant-runner"
  post_body "$_txt"
  printf '%s' "$sent" | grep -qF -- "$_txt"
  ! printf '%s' "$sent" | grep -qF '[REDACTED]' || return 1
  ! printf '%s' "$stderr" | grep -qF 'redacted' || return 1
}

# ---- redact subcommand -----------------------------------------------------

@test "redact subcommand: stdin -> redacted stdout, count on stderr only" {
  _tok="pplx-""$FAKE32"
  _in="$(printf 'line one\nkey %s and %s\nend' "$_tok" "ghp_""${FAKE32}0000")"
  PATH="$SANDBOX" run --separate-stderr sh -c 'printf "%s" "$1" | "$2" redact' _ "$_in" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'line one\nkey [REDACTED] and [REDACTED]\nend')" ]
  [[ "$stderr" == *"redacted 2 likely secret(s)"* ]] || false
  [[ "$output" != *"redacted"* ]] || false
  [[ "$stderr" != *"$_tok"* ]] || false
}

@test "redact subcommand: clean text passes through byte-for-byte" {
  _in="sk-learn; commit 0123456789abcdef0123456789abcdef01234567; no trailing newline"
  printf '%s' "$_in" >"$BATS_TEST_TMPDIR/in.txt"
  PATH="$SANDBOX" run --separate-stderr sh -c '"$1" redact <"$2" >"$3"' _ "$SCRIPT" "$BATS_TEST_TMPDIR/in.txt" "$BATS_TEST_TMPDIR/out.txt"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/in.txt" "$BATS_TEST_TMPDIR/out.txt"
  [[ "$stderr" == *"redacted 0 likely secret(s)"* ]] || false
}

@test "redact subcommand: a redaction failure exits non-zero with no stdout" {
  # A jq that always fails stands in for a broken redaction.
  printf '#!/bin/sh\nexit 5\n' >"$FAKEDIR/jq"
  chmod +x "$FAKEDIR/jq"
  PATH="$SANDBOX" run --separate-stderr sh -c 'printf "secret text" | "$1" redact' _ "$SCRIPT"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"redaction failed"* ]] || false
}

# ---- review / stale: inline comments ----------------------------------------
# A PR whose a.sh hunk covers right-side lines 1-4; b.sh is not in the diff.
# The ledger has: a critical on a.sh:3, an important on a.sh:2-3, a suggestion
# on b.sh:100 (outside the diff).

review_fixtures() {
  install_fake_git
  printf '[{"filename":"a.sh","patch":"@@ -1,2 +1,4 @@\\n line1\\n+line2\\n+line3\\n line4"}]\n' >"$FILES"
  printf '<!-- rc:report -->\n<!-- rc:state {"v":1,"status":"%s"} -->\n## Digest\n<!-- rc:inline -->\n\n---\n\n<sub>footer</sub>\n' \
    "${1:-findings}" >"$BODY"
  cat >"$LEDGER" <<'EOF'
{"schema":"review-council/ledger","version":1,"findings":[
 {"fingerprint":"a.sh::f::bug","outcome":"reported","section":"main","severity":"critical","badge":"[cross-reviewed]",
  "title":"Crash on empty input","issue":"It crashes.","recommendation":"Guard it.","origins":[{"reviewer":"codex"},{"reviewer":"claude"}],
  "location":{"path":"a.sh","line":3}},
 {"fingerprint":"a.sh::f::range","outcome":"reported","section":"main","severity":"important",
  "title":"Range issue","issue":"Two lines.","location":{"path":"a.sh","line":2,"line_end":3}},
 {"fingerprint":"b.sh::g::style","outcome":"reported","section":"main","severity":"suggestion",
  "title":"Style nit","issue":"Rename it.","location":{"path":"b.sh","line":100}},
 {"fingerprint":"a.sh::f::dropped","outcome":"dropped-refuted","severity":"critical",
  "title":"Refuted","location":{"path":"a.sh","line":3}}
]}
EOF
}

# only_suggestions: rewrite the ledger to the b.sh suggestion plus an a.sh suggestion.
only_suggestions() {
  jq '.findings = [.findings[2], (.findings[0] | .severity = "suggestion")]' "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
}

# The summary that went out: the review body, or the PR comment it fell back to.
digest_sent() { if [ -f "$POSTBODY" ]; then jq -r '.body' "$POSTBODY"; else jq -r '.body' "$REVIEWBODY"; fi; }

@test "review: in-diff findings go inline as one review; out-of-diff ones to the digest" {
  review_fixtures
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "inline_new=2"
  has "outside=1"
  has "review_url=https://gh/review"
  run jq -r '.comments | length' "$REVIEWBODY"
  [ "$output" = 2 ]
  run jq -c '[.comments[] | {path, line, start_line}]' "$REVIEWBODY"
  [ "$output" = '[{"path":"a.sh","line":3,"start_line":null},{"path":"a.sh","line":3,"start_line":2}]' ]
  jq -r '.comments[0].body' "$REVIEWBODY" | grep -qF '<!-- rc:finding a.sh::f::bug -->'
  jq -r '.comments[0].body' "$REVIEWBODY" | grep -qF 'found by claude, codex'
  jq -r '.comments[0].body' "$REVIEWBODY" | grep -qF '`[cross-reviewed]`'
  digest_sent | grep -qF 'What the tags mean'
  jq -r '.comments[0].body' "$REVIEWBODY" | grep -qF 'Prompt for AI agents'
  [ "$(jq -r .commit_id "$REVIEWBODY")" = 1111111111111111111111111111111111111111 ]
  digest_sent | grep -qF 'Outside the diff (1)'
  digest_sent | grep -qF '`b.sh:100`'
  ! digest_sent | grep -qF '<!-- rc:inline -->' || return 1
  ! digest_sent | grep -qF 'Refuted' || return 1
}

# with_code <index> <line> <line_end|null> <code>: give ledger finding <index> a
# location with the exact text of its line; a.sh at HEAD is line1..line4.
with_code() {
  export GIT_SHOW_DIR="$BATS_TEST_TMPDIR/src"
  mkdir -p "$GIT_SHOW_DIR"
  printf 'line1\n  line2 = x\nline3\nline4\n' >"$GIT_SHOW_DIR/a.sh"
  jq --argjson i "$1" --argjson l "$2" --argjson e "$3" --arg c "$4" \
    '.findings[$i].location = {path: "a.sh", line: $l, line_end: $e, code: $c}' "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
}

@test "review: a finding whose code is on another line is moved there" {
  review_fixtures
  with_code 0 2 null 'line3'
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  run jq -c '[.comments[] | select(.body | contains("rc:finding a.sh::f::bug")) | {line, start_line}]' "$REVIEWBODY"
  [ "$output" = '[{"line":3,"start_line":null}]' ]
  jq -r '.comments[0].body' "$REVIEWBODY" | grep -qF '`a.sh:3`'
}

@test "review: a range moves with its first line's code, whitespace ignored" {
  review_fixtures
  with_code 1 1 2 'line2   =  x'
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  run jq -c '[.comments[] | select(.body | contains("rc:finding a.sh::f::range")) | {line, start_line}]' "$REVIEWBODY"
  [ "$output" = '[{"line":3,"start_line":2}]' ]
}

@test "review: a finding whose code is already on its line stays put" {
  review_fixtures
  with_code 0 3 null 'line3'
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  run jq -c '[.comments[] | select(.body | contains("rc:finding a.sh::f::bug")) | .line]' "$REVIEWBODY"
  [ "$output" = '[3]' ]
}

@test "review: a finding whose code is not in the file goes to the digest, without a line" {
  review_fixtures
  with_code 0 3 null 'nowhere(in, the, file)'
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "inline_new=1"
  has "outside=2"
  ! jq -r '.comments[].body' "$REVIEWBODY" | grep -qF 'rc:finding a.sh::f::bug' || return 1
  digest_sent | grep -qF 'Crash on empty input'
  ! digest_sent | grep -qF '`a.sh:3`' || return 1
}

@test "review: when the code matches several lines, the nearest one wins" {
  review_fixtures
  with_code 0 4 null 'line'
  printf 'line\nline1\nline2\nline3\nline\n' >"$GIT_SHOW_DIR/a.sh"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  # "line" matches lines 1 and 5 exactly (an exact match beats the substring
  # matches on 2-4); 5 is nearer to 4. Line 5 is outside the hunk (1-4), so
  # the finding is listed in the digest at a.sh:5.
  ! jq -r '.comments[].body' "$REVIEWBODY" | grep -qF 'rc:finding a.sh::f::bug' || return 1
  digest_sent | grep -qF '`a.sh:5`'
}

@test "review: a critical or important finding requests changes" {
  review_fixtures
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=REQUEST_CHANGES"
  [ "$(jq -r .event "$REVIEWBODY")" = REQUEST_CHANGES ]
}

@test "review: RC_PR_REQUEST_CHANGES=false posts a critical finding as a plain COMMENT" {
  review_fixtures
  RC_PR_REQUEST_CHANGES=false PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=COMMENT"
  [ "$(jq -r .event "$REVIEWBODY")" = COMMENT ]
  [ ! -f "$REVIEWBODY.REQUEST_CHANGES" ]
  ! jq -r .body "$REVIEWBODY" | grep -qF 'rc:blocking' || return 1
}

@test "review: RC_PR_REQUEST_CHANGES=true still requests changes" {
  review_fixtures
  RC_PR_REQUEST_CHANGES=true PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=REQUEST_CHANGES"
}

@test "review: an invalid RC_PR_REQUEST_CHANGES is noted and treated as true" {
  review_fixtures
  RC_PR_REQUEST_CHANGES=nope PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "RC_PR_REQUEST_CHANGES"
  has "review_event=REQUEST_CHANGES"
}

@test "review: with RC_PR_REQUEST_CHANGES=false a clean run still dismisses our earlier request-changes" {
  review_fixtures clean
  only_suggestions
  printf '[{"id":300,"state":"CHANGES_REQUESTED","user":{"login":"rc-bot"},"body":"x <!-- rc:review -->"}]\n' >"$REVIEWS"
  RC_PR_REQUEST_CHANGES=false PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "dismissed=1"
}

@test "review: suggestions only -> a plain COMMENT review" {
  review_fixtures
  only_suggestions
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=COMMENT"
}

@test "review: blocking but nothing new inline still posts a request-changes review" {
  review_fixtures
  jq '.findings = [.findings[2] | .severity = "critical"]' "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=REQUEST_CHANGES"
  [ "$(jq '.comments | length' "$REVIEWBODY")" = 0 ]
}

@test "review: no second request-changes while ours is still active" {
  review_fixtures
  printf '[{"id":300,"state":"CHANGES_REQUESTED","user":{"login":"rc-bot"},"body":"x <!-- rc:review -->"}]\n' >"$REVIEWS"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=COMMENT"
  ! grep -qF dismissals "$GHLOG" || return 1
}

@test "review: request-changes refused (e.g. our own PR) -> retried as COMMENT" {
  review_fixtures
  REVIEW_FAIL_RC=1 PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=COMMENT"
  has "inline_new=2"
  [ -f "$REVIEWBODY.REQUEST_CHANGES" ]
}

@test "review: a rejected review moves the inline findings to the digest" {
  review_fixtures
  REVIEW_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "inline_new=0"
  has "outside=3"
  has "review_url="
  digest_sent | grep -qF 'Outside the diff (3)'
}

@test "review: no blocking finding -> our earlier request-changes is dismissed" {
  review_fixtures clean
  only_suggestions
  printf '[{"id":300,"state":"CHANGES_REQUESTED","user":{"login":"rc-bot"},"body":"x <!-- rc:review -->"},{"id":301,"state":"CHANGES_REQUESTED","user":{"login":"someone"}}]\n' >"$REVIEWS"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "dismissed=1"
  logged "reviews/300/dismissals"
  ! grep -qF "reviews/301" "$GHLOG" || return 1
}

@test "review: a degraded run never dismisses" {
  review_fixtures degraded
  only_suggestions
  printf '[{"id":300,"state":"CHANGES_REQUESTED","user":{"login":"rc-bot"},"body":"x <!-- rc:review -->"}]\n' >"$REVIEWS"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "dismissed=0"
  ! grep -qF dismissals "$GHLOG" || return 1
}

@test "review: a finding we already commented on is left alone" {
  review_fixtures
  printf '[{"id":70,"in_reply_to_id":null,"user":{"login":"rc-bot"},"path":"a.sh","line":3,"body":"old\\n\\n<!-- rc:finding a.sh::f::bug -->"}]\n' >"$RCOMMENTS"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "inline_new=1"
  has "kept=1"
  ! jq -r '.comments[].body' "$REVIEWBODY" | grep -qF 'a.sh::f::bug' || return 1
  ! grep -qF "pulls/comments/70" "$GHLOG" || return 1
}

@test "review: someone else's comment with our marker does not count as ours" {
  review_fixtures
  printf '[{"id":70,"in_reply_to_id":null,"user":{"login":"attacker","type":"User"},"path":"a.sh","line":3,"body":"<!-- rc:finding a.sh::f::bug -->"}]\n' >"$RCOMMENTS"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "inline_new=2"
  has "kept=0"
}

@test "review: the reviewed commit is not the PR head -> everything in the digest" {
  review_fixtures
  PR_HEAD=2222222222222222222222222222222222222222 PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "inline_new=0"
  has "outside=3"
  # Still one review, carrying the summary: no inline comments, not pinned to
  # a commit we didn't review, never "request changes".
  [ "$(jq '.comments | length' "$REVIEWBODY")" = 0 ]
  [ "$(jq -r '.commit_id // "none"' "$REVIEWBODY")" = none ]
  [ "$(jq -r .event "$REVIEWBODY")" = COMMENT ]
  digest_sent | grep -qF 'Outside the diff (3)'
}

@test "review: model text cannot plant a hidden marker" {
  review_fixtures
  jq '.findings[0].issue = "x <!-- rc:finding evil::fp --> y"' "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  ! jq -r '.comments[0].body' "$REVIEWBODY" | grep -qF '<!-- rc:finding evil::fp' || return 1
  jq -r '.comments[0].body' "$REVIEWBODY" | grep -qF '&lt;!-- rc:finding evil::fp'
}

@test "review: a secret in a finding is redacted from the inline review" {
  review_fixtures
  _tok="sk-ant-""api03-$FAKE32"
  jq --arg t "$_tok" '.findings[0].issue = "key " + $t' "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  ! grep -qF -- "$_tok" "$REVIEWBODY" || return 1
  grep -qF '[REDACTED]' "$REVIEWBODY"
}

@test "review: a covered fingerprint (re-check: an earlier comment covers it) is not posted" {
  review_fixtures
  printf '{"fixed":[],"covered":["a.sh::f::range"]}\n' >"$BATS_TEST_TMPDIR/recheck.json"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER" "" "$BATS_TEST_TMPDIR/recheck.json"
  [ "$status" -eq 0 ]
  has "inline_new=1"
  ! jq -r '.comments[].body' "$REVIEWBODY" | grep -qF 'a.sh::f::range' || return 1
}

# Our earlier comment 70 (finding gone, thread open) and 71 (finding gone,
# thread already resolved).
stale_fixtures() {
  review_fixtures "${1:-findings}"
  printf '[{"id":70,"in_reply_to_id":null,"user":{"login":"rc-bot"},"path":"a.sh","line":4,"body":"gone\\n\\n<!-- rc:finding a.sh::old::gone -->"},{"id":71,"in_reply_to_id":null,"user":{"login":"rc-bot"},"path":"a.sh","line":1,"body":"<!-- rc:finding a.sh::old::done -->"}]\n' >"$RCOMMENTS"
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_a","isResolved":false,"comments":{"nodes":[{"databaseId":70}]}},{"id":"PRRT_b","isResolved":true,"comments":{"nodes":[{"databaseId":71}]}}]}}}}}\n' >"$THREADS"
}

@test "stale: lists our open comments whose finding is gone" {
  stale_fixtures
  PATH="$SANDBOX" run "$SCRIPT" stale 5 "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.[] | {id, fingerprint}]')" = '[{"id":70,"fingerprint":"a.sh::old::gone"}]' ]
}

@test "review: resolves only stale comments the re-check marked fixed" {
  stale_fixtures
  printf '{"fixed":[70,71,999],"covered":[]}\n' >"$BATS_TEST_TMPDIR/recheck.json"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER" "" "$BATS_TEST_TMPDIR/recheck.json"
  [ "$status" -eq 0 ]
  has "resolved=1"
  logged "pulls/5/comments/70/replies"
  logged "[id=PRRT_a]"
  ! grep -qF "comments/71/replies" "$GHLOG" || return 1
  ! grep -qF "999" "$GHLOG" || return 1
}

@test "review: a clean run keeps our request-changes while a blocking comment is still present" {
  stale_fixtures clean
  only_suggestions
  # Comment 70 was an important finding; this run doesn't report it and the
  # re-check left it open (STILL_PRESENT): the block stays.
  jq '.[0].body = "**🟠 Important** · found by claude\n\n**Bug**\n\n<!-- rc:finding a.sh::old::gone -->"' "$RCOMMENTS" >"$RCOMMENTS.t" && mv "$RCOMMENTS.t" "$RCOMMENTS"
  printf '[{"id":300,"state":"CHANGES_REQUESTED","user":{"login":"rc-bot"},"body":"x <!-- rc:review -->"}]\n' >"$REVIEWS"
  printf '{"fixed":[],"covered":[]}\n' >"$BATS_TEST_TMPDIR/recheck.json"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER" "" "$BATS_TEST_TMPDIR/recheck.json"
  [ "$status" -eq 0 ]
  has "dismissed=0"
  ! grep -qF dismissals "$GHLOG" || return 1
}

@test "review: a clean run keeps our request-changes when the review threads can't be listed" {
  stale_fixtures clean
  only_suggestions
  # Comment 70 was an important finding; the thread listing fails, so its
  # thread state is unknown and the re-check never ran on it: the block stays.
  jq '.[0].body = "**🟠 Important** · found by claude\n\n**Bug**\n\n<!-- rc:finding a.sh::old::gone -->"' "$RCOMMENTS" >"$RCOMMENTS.t" && mv "$RCOMMENTS.t" "$RCOMMENTS"
  printf '[{"id":300,"state":"CHANGES_REQUESTED","user":{"login":"rc-bot"},"body":"x <!-- rc:review -->"}]\n' >"$REVIEWS"
  THREADS_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "dismissed=0"
  ! grep -qF dismissals "$GHLOG" || return 1
}

@test "review: a blocking comment whose thread is resolved does not hold the block" {
  stale_fixtures clean
  only_suggestions
  # Comment 71's thread is resolved: an Important body there must not hold.
  jq '.[1].body = "**🟠 Important** · found by claude\n\n**Bug**\n\n<!-- rc:finding a.sh::old::done -->"' "$RCOMMENTS" >"$RCOMMENTS.t" && mv "$RCOMMENTS.t" "$RCOMMENTS"
  printf '[{"id":300,"state":"CHANGES_REQUESTED","user":{"login":"rc-bot"},"body":"x <!-- rc:review -->"}]\n' >"$REVIEWS"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "dismissed=1"
}

@test "review: a clean run dismisses once the re-check marks the blocking comment fixed" {
  stale_fixtures clean
  only_suggestions
  jq '.[0].body = "**🔴 Critical** · found by claude\n\n**Bug**\n\n<!-- rc:finding a.sh::old::gone -->"' "$RCOMMENTS" >"$RCOMMENTS.t" && mv "$RCOMMENTS.t" "$RCOMMENTS"
  printf '[{"id":300,"state":"CHANGES_REQUESTED","user":{"login":"rc-bot"},"body":"x <!-- rc:review -->"}]\n' >"$REVIEWS"
  printf '{"fixed":[70],"covered":[]}\n' >"$BATS_TEST_TMPDIR/recheck.json"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER" "" "$BATS_TEST_TMPDIR/recheck.json"
  [ "$status" -eq 0 ]
  has "resolved=1"
  has "dismissed=1"
  logged "reviews/300/dismissals"
}

@test "review: a still-present suggestion does not hold the block" {
  stale_fixtures clean
  only_suggestions
  jq '.[0].body = "**🟡 Suggestion**\n\n**Nit**\n\n<!-- rc:finding a.sh::old::gone -->"' "$RCOMMENTS" >"$RCOMMENTS.t" && mv "$RCOMMENTS.t" "$RCOMMENTS"
  printf '[{"id":300,"state":"CHANGES_REQUESTED","user":{"login":"rc-bot"},"body":"x <!-- rc:review -->"}]\n' >"$REVIEWS"
  printf '{"fixed":[],"covered":[]}\n' >"$BATS_TEST_TMPDIR/recheck.json"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER" "" "$BATS_TEST_TMPDIR/recheck.json"
  [ "$status" -eq 0 ]
  has "dismissed=1"
}

@test "review: without a re-check nothing is resolved" {
  stale_fixtures
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "resolved=0"
  ! grep -qF replies "$GHLOG" || return 1
}

@test "review: a degraded run never resolves" {
  stale_fixtures degraded
  printf '{"fixed":[70]}\n' >"$BATS_TEST_TMPDIR/recheck.json"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER" "" "$BATS_TEST_TMPDIR/recheck.json"
  [ "$status" -eq 0 ]
  has "resolved=0"
  ! grep -qF mutation "$GHLOG" || return 1
}

@test "review: refuses a digest without the marker" {
  review_fixtures
  printf 'no marker\n' >"$BODY"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -ne 0 ]
  [ ! -f "$REVIEWBODY" ]
}

@test "review: an unreadable ledger never dismisses a block (rc:state not clean)" {
  review_fixtures findings
  printf '{"findings":"garbage"}\n' >"$LEDGER"
  printf '[{"id":300,"state":"CHANGES_REQUESTED","user":{"login":"rc-bot"},"body":"x <!-- rc:review -->"}]\n' >"$REVIEWS"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "dismissed=0"
  ! grep -qF dismissals "$GHLOG" || return 1
}

@test "review: a failed reviews listing never requests changes a second time" {
  review_fixtures
  REVIEWS_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=COMMENT"
  [ ! -f "$REVIEWBODY.REQUEST_CHANGES" ]
}

# Our earlier "request changes" (id 300) listed both blocking fingerprints.
dismissed_fixtures() {
  review_fixtures
  printf '[{"id":300,"state":"DISMISSED","user":{"login":"rc-bot"},"body":"x <!-- rc:review -->\\n\\n<!-- rc:blocking a.sh::f::bug a.sh::f::range -->"}]\n' >"$REVIEWS"
  TIMELINE="$BATS_TEST_TMPDIR/timeline.json"
  export TIMELINE
}

@test "review: the request-changes review lists its blocking fingerprints" {
  review_fixtures
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  jq -r .body "$REVIEWBODY.REQUEST_CHANGES" | grep -qF '<!-- rc:blocking a.sh::f::bug a.sh::f::range -->'
}

@test "review: findings in a review a person dismissed never request changes again" {
  dismissed_fixtures
  printf '[{"event":"review_dismissed","actor":{"login":"alice","type":"User"},"dismissed_review":{"review_id":300}}]\n' >"$TIMELINE"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=COMMENT"
  [ ! -f "$REVIEWBODY.REQUEST_CHANGES" ]
}

@test "review: a new blocking finding after a person's dismissal requests changes again" {
  dismissed_fixtures
  printf '[{"event":"review_dismissed","actor":{"login":"alice","type":"User"},"dismissed_review":{"review_id":300}}]\n' >"$TIMELINE"
  jq '.findings[2].severity = "critical"' "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=REQUEST_CHANGES"
}

@test "review: our own dismissal (a clean run) does not count as a person's" {
  dismissed_fixtures
  printf '[{"event":"review_dismissed","actor":{"login":"github-actions[bot]","type":"Bot"},"dismissed_review":{"review_id":300}}]\n' >"$TIMELINE"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=REQUEST_CHANGES"
}

@test "review: an unreadable timeline treats our dismissed reviews as a person's" {
  dismissed_fixtures
  TIMELINE_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=COMMENT"
}

# ---- review: regressions from the pre-trial reviews --------------------------

@test "review: another bot's request-changes review is never ours (not dismissed, not blocking ours)" {
  review_fixtures clean
  only_suggestions
  printf '[{"id":400,"state":"CHANGES_REQUESTED","user":{"login":"github-actions[bot]","type":"Bot"},"body":"reviewdog: lint errors"}]\n' >"$REVIEWS"
  GITHUB_ACTIONS=true USER_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  ! grep -qF "reviews/400/dismissals" "$GHLOG" || return 1
}

@test "review: a foreign active review does not stop ours from requesting changes" {
  review_fixtures
  printf '[{"id":400,"state":"CHANGES_REQUESTED","user":{"login":"rc-bot"},"body":"some other tool"}]\n' >"$REVIEWS"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=REQUEST_CHANGES"
  jq -r .body "$REVIEWBODY.REQUEST_CHANGES" | grep -qF '<!-- rc:review -->'
}

@test "review: our own dismissal as a User identity (local / machine user) is not a person's" {
  dismissed_fixtures
  printf '[{"event":"review_dismissed","actor":{"login":"rc-bot","type":"User"},"dismissed_review":{"review_id":"300"}}]\n' >"$TIMELINE"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=REQUEST_CHANGES"
}

@test "review: a person's dismissal is recognised when review_id is a string" {
  dismissed_fixtures
  printf '[{"event":"review_dismissed","actor":{"login":"alice","type":"User"},"dismissed_review":{"review_id":"300"}}]\n' >"$TIMELINE"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=COMMENT"
}

@test "review: a timeline over 128 KB still works (never passed as an argument)" {
  dismissed_fixtures
  jq -n '[range(0;400) | {event:"commented", actor:{login:"alice",type:"User"}, body:("x" * 400)}]
         + [{event:"review_dismissed", actor:{login:"alice",type:"User"}, dismissed_review:{review_id:300}}]' >"$TIMELINE"
  [ "$(wc -c <"$TIMELINE")" -gt 131072 ]
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=COMMENT"
}

@test "review: non-ASCII text before the placeholder is spliced correctly" {
  review_fixtures
  printf '<!-- rc:report -->\n<!-- rc:state {"v":1,"status":"findings"} -->\n## Digest 🔴 Critical — café\n| a | b |\n<!-- rc:inline -->\nTAIL-KEEP\n\n---\n\n<sub>footer · bot</sub>\n' >"$BODY"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  digest_sent >"$BATS_TEST_TMPDIR/d.md"
  ! grep -qF '<!-- rc:inline' "$BATS_TEST_TMPDIR/d.md" || return 1
  grep -qF '**On the diff:** 2 inline comments below · 1 outside the diff' "$BATS_TEST_TMPDIR/d.md"
  grep -qF 'TAIL-KEEP' "$BATS_TEST_TMPDIR/d.md"
  grep -qF 'café' "$BATS_TEST_TMPDIR/d.md"
}

@test "review: without a placeholder the section goes at the end, before our footer, non-ASCII safe" {
  review_fixtures
  printf '<!-- rc:report -->\n<!-- rc:state {"v":1,"status":"findings"} -->\n## Digest — 🔴\n' >"$BODY"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(digest_sent | grep -v '^$' | grep -v '^<!-- rc:' | tail -1)" = '<sub>Review done with [Review Council](https://github.com/deployhq/review-council/) · posted by @rc-bot (not a personal comment)</sub>' ]
  digest_sent | grep -qF 'Outside the diff (1)'
  digest_sent | grep -qF 'Digest — 🔴'
}

@test "review: a secret at the start of a line in a finding is redacted inline" {
  review_fixtures
  _tok="sk-ant-""api03-$FAKE32"
  jq --arg t "$_tok" '.findings[0].issue = "first line\n" + $t' "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  ! grep -qF -- "$_tok" "$REVIEWBODY" || return 1
}

@test "redact: newer shapes (Google, Slack, Stripe, JWT, PEM private key block)" {
  redacts "AIza""FAKEfakeFAKEfakeFAKEfakeFAKEfake123"
  redacts "eyJ""hbGciOiJIUzI1NiJ9.eyJ""zdWIiOiJmYWtlZmFrZSJ9.FAKEfakeFAKEfake123"
  redacts "xoxb-""1234567890-FAKEfake"
  redacts "sk_live_""$FAKE32"
  post_body "$(printf 'key:\n-----BEGIN RSA PRIVATE KEY-----\nMIIFAKEFAKE\n-----END RSA PRIVATE KEY-----\nafter')"
  ! printf '%s' "$sent" | grep -qF 'MIIFAKEFAKE' || return 1
  printf '%s' "$sent" | grep -qF 'after'
}

@test "review: @mentions in finding text never ping (outside code spans)" {
  review_fixtures
  jq '.findings[0].issue = "ask @alice and @org/team; keep `@types/node` as is"' "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  _b="$(jq -r '.comments[0].body' "$REVIEWBODY")"
  ! printf '%s' "$_b" | grep -qF 'ask @alice' || return 1
  printf '%s' "$_b" | grep -qF '`@types/node`'
}

@test "review: a refused resolve still replies once, marked, and is never stale again" {
  stale_fixtures
  printf '{"fixed":[70]}\n' >"$BATS_TEST_TMPDIR/recheck.json"
  RESOLVE_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER" "" "$BATS_TEST_TMPDIR/recheck.json"
  [ "$status" -eq 0 ]
  has "resolved=0"
  grep -qF 'Reply here' "$GHLOG.replies"
  grep -qF '<!-- rc:fixed -->' "$GHLOG.replies"
  ! grep -qF 'rc:fixed resolved' "$GHLOG.replies" || return 1
  # next run: our marked reply is there -> 70 is not stale
  printf '[{"id":70,"in_reply_to_id":null,"user":{"login":"rc-bot"},"path":"a.sh","line":4,"body":"gone\\n\\n<!-- rc:finding a.sh::old::gone -->"},{"id":72,"in_reply_to_id":70,"user":{"login":"rc-bot"},"body":"looks fixed\\n\\n<!-- rc:fixed -->"}]\n' >"$RCOMMENTS"
  PATH="$SANDBOX" run "$SCRIPT" stale 5 "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "review: a finding we marked fixed that comes back gets a new comment" {
  review_fixtures
  printf '[{"id":70,"in_reply_to_id":null,"user":{"login":"rc-bot"},"path":"a.sh","line":3,"body":"old\\n\\n<!-- rc:finding a.sh::f::bug -->"},{"id":72,"in_reply_to_id":70,"user":{"login":"rc-bot"},"body":"x\\n\\n<!-- rc:fixed -->"}]\n' >"$RCOMMENTS"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "inline_new=2"
  jq -r '.comments[].body' "$REVIEWBODY" | grep -qF 'a.sh::f::bug'
}

@test "review: a finding whose thread a person resolved is left alone" {
  review_fixtures
  printf '[{"id":70,"in_reply_to_id":null,"user":{"login":"rc-bot"},"path":"a.sh","line":3,"body":"old\\n\\n<!-- rc:finding a.sh::f::bug -->"}]\n' >"$RCOMMENTS"
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_a","isResolved":true,"comments":{"nodes":[{"databaseId":70}]}}]}}}}}\n' >"$THREADS"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "kept=1"
  ! jq -r '.comments[].body' "$REVIEWBODY" | grep -qF 'a.sh::f::bug' || return 1
}

@test "review: head moved during the run -> no request changes, no dismissal" {
  review_fixtures clean
  printf '[{"id":300,"state":"CHANGES_REQUESTED","user":{"login":"rc-bot"},"body":"x <!-- rc:review -->"}]\n' >"$REVIEWS"
  only_suggestions
  PR_HEAD=2222222222222222222222222222222222222222 PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  ! grep -qF dismissals "$GHLOG" || return 1
  [ ! -f "$REVIEWBODY.REQUEST_CHANGES" ]
}

@test "review: the digest stays under GitHub's size limit and counts what it left out" {
  review_fixtures
  jq '.findings = [range(0;40) as $i | {fingerprint: "b.sh::g::f\($i)", outcome: "reported", section: "main",
        severity: "suggestion", title: "T\($i)", issue: ("y" * 3000), location: {path: "b.sh", line: 100}}]' \
    "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(digest_sent | wc -m | tr -d ' ')" -lt 65536 ]
  digest_sent | grep -qE '[0-9]+ more not shown'
}

@test "review: a bot token with unknown login never resolves or dismisses" {
  stale_fixtures clean
  only_suggestions
  printf '[{"id":300,"state":"CHANGES_REQUESTED","user":{"login":"x[bot]","type":"Bot"},"body":"<!-- rc:review -->"}]\n' >"$REVIEWS"
  printf '{"fixed":[70]}\n' >"$BATS_TEST_TMPDIR/recheck.json"
  sed -i.bak 's/"login":"rc-bot"/"login":"x[bot]","type":"Bot"/g' "$RCOMMENTS"
  MYTOK=t USER_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER" MYTOK "$BATS_TEST_TMPDIR/recheck.json"
  [ "$status" -eq 0 ]
  has "resolved=0"
  has "dismissed=0"
  ! grep -qF mutation "$GHLOG" || return 1
  MYTOK=t USER_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" stale 5 "$LEDGER" MYTOK
  [ "$output" = "[]" ]
}

@test "review: RC_PR_BOT_LOGIN names the bot, so only its comments count and it can resolve" {
  stale_fixtures
  printf '{"fixed":[70]}\n' >"$BATS_TEST_TMPDIR/recheck.json"
  sed -i.bak 's/"login":"rc-bot"/"login":"my-app[bot]","type":"Bot"/g' "$RCOMMENTS"
  RC_PR_BOT_LOGIN='my-app[bot]' MYTOK=t USER_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER" MYTOK "$BATS_TEST_TMPDIR/recheck.json"
  [ "$status" -eq 0 ]
  has "resolved=1"
  # another bot's marked comment is not ours under a named login
  sed -i.bak 's/"login":"my-app\[bot\]"/"login":"other[bot]"/g' "$RCOMMENTS"
  RC_PR_BOT_LOGIN='my-app[bot]' MYTOK=t USER_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" stale 5 "$LEDGER" MYTOK
  [ "$output" = "[]" ]
}

@test "review: a fingerprint outside the marker charset is normalised and still tracked" {
  review_fixtures
  jq '.findings[0].fingerprint = "a.sh::f(x)::bug #1"' "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "inline_new=2"
  jq -r '.comments[0].body' "$REVIEWBODY" | grep -qF '<!-- rc:finding a.sh::f-x-::bug--1 -->'
  jq -r .body "$REVIEWBODY.REQUEST_CHANGES" | grep -qF 'a.sh::f-x-::bug--1'
}

@test "review: a multi-line RC_PR_BOT_LOGIN is ignored" {
  stale_fixtures
  RC_PR_BOT_LOGIN="$(printf 'my-app[bot]\nx')" MYTOK=t USER_FAIL=1 PATH="$SANDBOX" run --separate-stderr "$SCRIPT" stale 5 "$LEDGER" MYTOK
  [ "$output" = "[]" ]
  printf '%s' "$stderr" | grep -qF 'invalid RC_PR_BOT_LOGIN'
}

# ---- one review per run: the summary lives in the review --------------------

FOOTER_LOCAL='<sub>Review done with [Review Council](https://github.com/deployhq/review-council/) · posted by @rc-bot (not a personal comment)</sub>'

@test "review: the summary goes in the review, with no separate comment" {
  review_fixtures
  printf '<!-- rc:report -->\n<!-- rc:state {"v":1,"status":"findings","critical":1,"important":1,"suggestion":1} -->\n## Review Council\n<!-- rc:inline -->\n' >"$BODY"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "action=review"
  has "url=https://gh/review"
  [ ! -f "$POSTBODY" ]
  digest_sent | grep -qF '## Review Council'
  digest_sent | grep -qF '**Findings:** 1 critical · 1 important · 1 suggestion · **On the diff:** 2 inline comments below · 1 outside the diff'
  digest_sent | grep -qF "$FOOTER_LOCAL"
  # Our markers come after the footer.
  [ "$(digest_sent | grep -v '^$' | tail -2 | head -1)" = '<!-- rc:review -->' ]
  digest_sent | tail -1 | grep -q '^<!-- rc:blocking a.sh::f::bug a.sh::f::range -->$'
}

@test "review: each inline comment ends with the footer, then its marker" {
  review_fixtures
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  jq -r '.comments[0].body' "$REVIEWBODY" | grep -v '^$' | tail -2 >"$BATS_TEST_TMPDIR/tail.txt"
  [ "$(head -1 "$BATS_TEST_TMPDIR/tail.txt")" = "$FOOTER_LOCAL" ]
  [ "$(tail -1 "$BATS_TEST_TMPDIR/tail.txt")" = '<!-- rc:finding a.sh::f::bug -->' ]
}

@test "review: in Actions with no bot token the footer names github-actions[bot]" {
  review_fixtures
  GITHUB_ACTIONS=true USER_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  digest_sent | grep -qF '<sub>Review done with [Review Council](https://github.com/deployhq/review-council/) · github-actions[bot]</sub>'
  jq -r '.comments[0].body' "$REVIEWBODY" | grep -qF '· github-actions[bot]</sub>'
}

@test "review: an earlier summary comment of ours now points at the latest review" {
  review_fixtures
  printf '[{"id":10,"user":{"login":"rc-bot","type":"User"},"body":"<!-- rc:report -->\\nold summary"}]\n' >"$COMMENTS"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  [ ! -f "$POSTBODY" ]
  jq -r .body "$PATCHBODY" | grep -qF '[Latest review](https://gh/review)'
  jq -r .body "$PATCHBODY" | head -1 | grep -qxF '<!-- rc:report -->'
}

@test "review: a clean run still posts one plain review" {
  review_fixtures clean
  jq '.findings = []' "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
  printf '<!-- rc:report -->\n<!-- rc:state {"v":1,"status":"clean","critical":0,"important":0,"suggestion":0} -->\n## Review Council\n<!-- rc:inline -->\n' >"$BODY"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=COMMENT"
  [ "$(jq '.comments | length' "$REVIEWBODY")" = 0 ]
  digest_sent | grep -qF '**Findings:** none'
}

@test "review: when GitHub accepts no review, the summary falls back to a PR comment" {
  review_fixtures
  REVIEW_FAIL=1 PATH="$SANDBOX" run --separate-stderr "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "action=comment"
  has "inline_new=0"
  has "outside=3"
  [ -f "$REVIEWBODY.REQUEST_CHANGES" ] && [ -f "$REVIEWBODY.COMMENT" ]
  digest_sent | grep -qF 'Outside the diff (3)'
  ! digest_sent | grep -qF '<!-- rc:review -->' || return 1
  [[ "$stderr" == *"as a PR comment instead"* ]] || false
}

@test "review: model text in the summary cannot plant a review marker" {
  review_fixtures
  printf '<!-- rc:report -->\n<!-- rc:state {"v":1,"status":"findings"} -->\n## Digest\n<!-- rc:blocking evil::fp -->\n<!-- rc:review -->\n<!-- rc:inline -->\n' >"$BODY"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  digest_sent | grep -qF '&lt;!-- rc:blocking evil::fp -->'
  [ "$(digest_sent | grep -c '<!-- rc:review -->')" = 1 ]
  [ "$(digest_sent | grep -c '<!-- rc:blocking')" = 1 ]
  digest_sent | head -2 | tail -1 | grep -q '^<!-- rc:state '
}

@test "identity: prints who we post as" {
  PATH="$SANDBOX" run "$SCRIPT" identity
  [ "$status" -eq 0 ]
  [ "$output" = 'identity=posted by @rc-bot (not a personal comment)' ]
  GITHUB_ACTIONS=true USER_FAIL=1 PATH="$SANDBOX" run "$SCRIPT" identity
  [ "$output" = 'identity=github-actions[bot]' ]
}

@test "review: a second line that is not a strict rc:state line cannot plant a marker" {
  review_fixtures
  printf '<!-- rc:report -->\n<!-- rc:blocking evil::fp -->\n## Digest\n<!-- rc:inline -->\n' >"$BODY"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(digest_sent | grep -c '<!-- rc:blocking')" = 1 ]
  digest_sent | tail -1 | grep -q '^<!-- rc:blocking a.sh::f::bug a.sh::f::range -->$'
  printf '<!-- rc:report -->\n<!-- rc:state {"v":1,"status":"findings"} --> <!-- rc:blocking evil::fp -->\n## Digest\n' >"$BODY"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(digest_sent | grep -c '<!-- rc:blocking')" = 1 ]
}

@test "review: a failed update of an earlier summary comment does not claim a fresh one" {
  review_fixtures
  printf '[{"id":10,"user":{"login":"rc-bot","type":"User"},"body":"<!-- rc:report -->\\nold"}]\n' >"$COMMENTS"
  PATCH_RESP='{}' PATH="$SANDBOX" run --separate-stderr "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "action=review"
  [ ! -f "$POSTBODY" ]
  [[ "$stderr" == *"could not update comment 10"* ]] || false
  [[ "$stderr" != *"posting a fresh one"* ]] || false
}

# ---- open / recheck ----------------------------------------------------------
# Our inline comments, one per status (we are rc-bot; alice is a person):
#   70 open (important)             71 fixed: we resolved, `rc:fixed resolved`
#   72 reopened: we resolved, alice unresolved   73 reopened: alice replied after us
#   74 resolved_by_person (important)            75 legacy `rc:fixed` reply (a bot
#      replied after: still fixed)
#   76 we resolved, alice replied, thread resolved: fixed (on a thread we resolved
#      only the thread state counts)             77 resolved by us, no reply
#   78 we resolved; resolvedBy names another login (bot token): fixed, no ack
#   79 plain `rc:fixed`, alice replied, then resolved: resolved_by_person
#   80 we resolved, alice replied, thread unresolved: reopened
open_fixtures() {
  install_fake_git
  printf '[]\n' >"$FILES"
  jq -n '
    def root($id; $sev; $fp): {id: $id, in_reply_to_id: null, user: {login: "rc-bot", type: "User"}, path: "a.sh",
      line: 3, html_url: "https://gh/c/\($id)", body: "**\($sev)** · found by claude\n\n**T\($id)**\n\n<!-- rc:finding \($fp) -->"};
    def reply($id; $to; $who; $type; $body): {id: $id, in_reply_to_id: $to, user: {login: $who, type: $type}, body: $body};
    [ root(70; "🟠 Important"; "fp70"), root(71; "🟠 Important"; "fp71"), root(72; "🔴 Critical"; "fp72"),
      root(73; "🟠 Important"; "fp73"), root(74; "🟠 Important"; "fp74"), root(75; "🟡 Suggestion"; "fp75"),
      root(76; "🟠 Important"; "fp76"), root(77; "🟠 Important"; "fp77"),
      root(78; "🟠 Important"; "fp78"), root(79; "🟠 Important"; "fp79"), root(80; "🟠 Important"; "fp80"),
      reply(90; 80; "rc-bot"; "User"; "Looks fixed\n\n<!-- rc:fixed resolved -->"),
      reply(100; 80; "alice"; "User"; "thanks"),
      reply(88; 78; "rc-bot"; "User"; "Looks fixed\n\n<!-- rc:fixed resolved -->"),
      reply(89; 79; "rc-bot"; "User"; "Looks fixed\n\n<!-- rc:fixed -->"),
      reply(99; 79; "alice"; "User"; "not fixed"),
      reply(81; 71; "rc-bot"; "User"; "Looks fixed\n\n<!-- rc:fixed resolved -->"),
      reply(82; 72; "rc-bot"; "User"; "Looks fixed\n\n<!-- rc:fixed resolved -->"),
      reply(83; 73; "rc-bot"; "User"; "Looks fixed\n\n<!-- rc:fixed -->"),
      reply(93; 73; "alice"; "User"; "No, still broken"),
      reply(85; 75; "rc-bot"; "User"; "Re-checked at abc: this looks fixed. Resolved.\n\n<!-- rc:fixed -->"),
      reply(95; 75; "other[bot]"; "Bot"; "bot noise"),
      reply(86; 76; "rc-bot"; "User"; "Looks fixed\n\n<!-- rc:fixed resolved -->"),
      reply(96; 76; "alice"; "User"; "not fixed") ]' >"$RCOMMENTS"
  jq -n '
    def th($n; $res; $by): {id: "PRRT_\($n)", isResolved: $res, resolvedBy: (if $by then {login: $by} else null end),
      comments: {nodes: [{databaseId: $n}]}};
    {data: {repository: {pullRequest: {reviewThreads: {nodes: [
      th(70; false; null), th(71; true; "rc-bot"), th(72; false; null), th(73; false; null),
      th(74; true; "alice"), th(75; false; null), th(76; true; "alice"), th(77; true; null),
      th(78; true; "other-app[bot]"), th(79; true; "alice"), th(80; false; null) ]}}}}}' >"$THREADS"
  printf '[]\n' >"$REVIEWS"
  VERD="$BATS_TEST_TMPDIR/verdicts.json"
}

# active <blocking-line-or-empty> [extra-body]: our active request-changes review 300.
active() {
  jq -n --arg b "$1" --arg x "${2:-}" '[{id: 300, state: "CHANGES_REQUESTED", user: {login: "rc-bot", type: "User"},
    html_url: "https://gh/r/300", submitted_at: "2026-01-01T00:00:00Z",
    body: ("digest\n\n<!-- rc:review -->" + $x + (if $b == "" then "" else "\n\n<!-- rc:blocking " + $b + " -->" end))}]' >"$REVIEWS"
}

# verdicts <jq-object-merge>: head = the PR head, not degraded, nothing blocking now.
verdicts() {
  jq -n "{head: \"1111111111111111111111111111111111111111\", degraded: false, blocking_now: false,
          reported: [], checked: 3, fixed: []} + ($1)" >"$VERD"
}

@test "open: every inline status, and ack from person-resolved threads" {
  open_fixtures
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" open 5
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.inline[] | {(.id | tostring): .status}] | add')" = \
    '{"70":"open","71":"fixed","72":"reopened","73":"reopened","74":"resolved_by_person","75":"fixed","76":"fixed","77":"resolved","78":"fixed","79":"resolved_by_person","80":"reopened"}' ]
  [ "$(printf '%s' "$output" | jq -c '.ack')" = '["fp74","fp79"]' ]
  [ "$(printf '%s' "$output" | jq -c '[.inline_ok, .known, .head]')" = '[true,true,"1111111111111111111111111111111111111111"]' ]
  [ "$(printf '%s' "$output" | jq -c '.inline[0] | {fingerprint, severity, path, line, url}')" = \
    '{"fingerprint":"fp70","severity":"important","path":"a.sh","line":3,"url":"https://gh/c/70"}' ]
  ! printf '%s' "$output" | jq -e '.inline[0] | has("_thread")' >/dev/null || return 1
}

@test "open: unreadable threads -> inline_ok false, still prints the object" {
  open_fixtures
  THREADS_FAIL=1 PATH="$SANDBOX" run --separate-stderr "$SCRIPT" open 5
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.inline_ok')" = false ]
  [ "$(printf '%s' "$output" | jq -r '.inline[] | select(.id == 70) | .status')" = open ]
}

@test "open: head moved -> inline_ok false" {
  open_fixtures
  PR_HEAD=2222222222222222222222222222222222222222 PATH="$SANDBOX" run --separate-stderr "$SCRIPT" open 5
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.inline_ok')" = false ]
}

@test "open: unreadable timeline -> inline_ok false (unknown dismissals never count as acknowledged)" {
  open_fixtures
  TIMELINE_FAIL=1 PATH="$SANDBOX" run --separate-stderr "$SCRIPT" open 5
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.inline_ok')" = false ]
}

@test "open: blocking from the active reviews ('' for untracked or no line)" {
  open_fixtures
  active "fp70 fp72"
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" open 5
  [ "$(printf '%s' "$output" | jq -c '[.active, .blocking]')" = '[[300],["fp70","fp72"]]' ]
  active "fp70" $'\n\n<!-- rc:blocking-untracked -->'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" open 5
  [ "$(printf '%s' "$output" | jq -c '.blocking')" = '["","fp70"]' ]
  active ""
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" open 5
  [ "$(printf '%s' "$output" | jq -c '.blocking')" = '[""]' ]
}

# outside_round_trip: post a review whose b.sh finding is outside the diff, then
# make that review ours on the PR (review 300, submitted 2026-01-01).
outside_round_trip() {
  review_fixtures
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  jq '[{id: 300, state: "CHANGES_REQUESTED", user: {login: "rc-bot", type: "User"}, html_url: "https://gh/r/300",
        submitted_at: "2026-01-01T00:00:00Z", body: .body}]' "$REVIEWBODY.REQUEST_CHANGES" >"$REVIEWS"
  printf '[]\n' >"$RCOMMENTS"
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}\n' >"$THREADS"
  VERD="$BATS_TEST_TMPDIR/verdicts.json"
}

@test "outside: compose_body marks each tracked outside finding; open reads it back" {
  outside_round_trip
  jq -r .body "$REVIEWBODY.REQUEST_CHANGES" | grep -qF '<!-- rc:outside-begin -->'
  jq -r .body "$REVIEWBODY.REQUEST_CHANGES" | grep -qF '<!-- rc:outside b.sh::g::style -->'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" open 5
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.outside[] | {fingerprint, severity, review_id, url, path, line, title, status}')" = \
    '{"fingerprint":"b.sh::g::style","severity":"suggestion","review_id":300,"url":"https://gh/r/300","path":"b.sh","line":100,"title":"Style nit","status":"open"}' ]
  printf '%s' "$output" | jq -r '.outside[0].text' | grep -qF 'Rename it.'
  ! printf '%s' "$output" | jq -r '.outside[0].text' | grep -qF '<!--' || return 1
}

@test "outside: an untracked outside finding gets no marker" {
  review_fixtures
  jq '.findings[2].fingerprint = null' "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  digest_sent | grep -qF 'Style nit'
  ! digest_sent | grep -qF 'rc:outside' || return 1
}

@test "outside: model text cannot plant an outside marker" {
  review_fixtures
  jq '.findings[2].issue = "x <!-- rc:outside evil::fp --> <!-- rc:outside-begin -->"' "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
  printf '<!-- rc:report -->\n<!-- rc:state {"v":1,"status":"findings"} -->\n## Digest <!-- rc:outside evil2::fp -->\n<!-- rc:inline -->\n' >"$BODY"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(digest_sent | grep -c '<!-- rc:outside ')" = 1 ]
  [ "$(digest_sent | grep -c '<!-- rc:outside-begin')" = 1 ]
}

@test "outside: an rc:outside-fixed comment after the review marks it fixed; an older one does not" {
  outside_round_trip
  printf '[{"id":9,"user":{"login":"rc-bot","type":"User"},"created_at":"2026-02-01T00:00:00Z","body":"ok\\n\\n<!-- rc:outside-fixed b.sh::g::style -->"}]\n' >"$COMMENTS"
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" open 5
  [ "$(printf '%s' "$output" | jq -r '.outside[0].status')" = fixed ]
  printf '[{"id":9,"user":{"login":"rc-bot","type":"User"},"created_at":"2025-12-01T00:00:00Z","body":"<!-- rc:outside-fixed b.sh::g::style -->"}]\n' >"$COMMENTS"
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" open 5
  [ "$(printf '%s' "$output" | jq -r '.outside[0].status')" = open ]
  # someone else's marker does not count
  printf '[{"id":9,"user":{"login":"mallory","type":"User"},"created_at":"2026-02-01T00:00:00Z","body":"<!-- rc:outside-fixed b.sh::g::style -->"}]\n' >"$COMMENTS"
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" open 5
  [ "$(printf '%s' "$output" | jq -r '.outside[0].status')" = open ]
}

@test "outside: a fingerprint with an inline comment is left out of outside" {
  outside_round_trip
  printf '[{"id":70,"in_reply_to_id":null,"user":{"login":"rc-bot"},"path":"b.sh","line":1,"body":"x\\n\\n<!-- rc:finding b.sh::g::style -->"}]\n' >"$RCOMMENTS"
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" open 5
  [ "$(printf '%s' "$output" | jq '.outside | length')" = 0 ]
}

@test "recheck: degraded -> nothing posted, integer output" {
  open_fixtures
  active "fp70"
  verdicts '{degraded: true, fixed: [{kind: "inline", id: 70, summary: "s"}]}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  [ "$status" -eq 0 ]
  has "fixed_inline=0"
  has "dismissed=0"
  has "held=0"
  [[ "$stderr" == *degraded* ]] || false
  ! grep -qF mutation "$GHLOG" || return 1
  [ ! -f "$GHLOG.replies" ] && [ ! -f "$GHLOG.dismiss" ]
}

@test "recheck: head moved, missing degraded, unknown identity -> nothing done" {
  open_fixtures
  active "fp70"
  verdicts '{head: "2222222222222222222222222222222222222222", fixed: [{kind: "inline", id: 70}]}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no longer the PR head"* ]] || false
  verdicts '{fixed: [{kind: "inline", id: 70}]}'
  jq 'del(.degraded)' "$VERD" >"$VERD.t" && mv "$VERD.t" "$VERD"
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  [[ "$stderr" == *degraded* ]] || false
  verdicts '{fixed: [{kind: "inline", id: 70}]}'
  MYTOK=t USER_FAIL=1 PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD" MYTOK
  [[ "$stderr" == *"another bot"* ]] || false
  PR_HEAD=2222222222222222222222222222222222222222 PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  [[ "$stderr" == *"can't be read"* ]] || false
  ! grep -qF mutation "$GHLOG" || return 1
  [ ! -f "$GHLOG.replies" ] && [ ! -f "$GHLOG.dismiss" ]
}

@test "recheck: resolves then replies 'rc:fixed resolved' with the reasons" {
  open_fixtures
  verdicts '{fixed: [{kind: "inline", id: 70, summary: "The guard is there now.", points: ["a.sh:3 checks it", "tests cover it"]}]}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  [ "$status" -eq 0 ]
  has "fixed_inline=1"
  has "resolved=1"
  logged "[id=PRRT_70]"
  logged "pulls/5/comments/70/replies"
  _r="$(jq -r .body "$GHLOG.replies")"
  printf '%s' "$_r" | head -1 | grep -qxF '**Looks fixed** at `1111111` · rechecked by Review Council'
  printf '%s' "$_r" | grep -qF 'The guard is there now.'
  printf '%s' "$_r" | grep -qF "<summary>Why we think it's fixed</summary>"
  printf '%s' "$_r" | grep -qxF -- '- tests cover it'
  printf '%s' "$_r" | grep -qF 'Disagree? Unresolve this conversation and the council will treat it as still open.</sub>'
  [ "$(printf '%s' "$_r" | tail -1)" = '<!-- rc:fixed resolved -->' ]
}

@test "recheck: a refused resolve replies 'rc:fixed' and 'Reply here'" {
  open_fixtures
  verdicts '{fixed: [{kind: "inline", id: 70, summary: "ok"}]}'
  RESOLVE_FAIL=1 PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  [ "$status" -eq 0 ]
  has "fixed_inline=1"
  has "resolved=0"
  _r="$(jq -r .body "$GHLOG.replies")"
  printf '%s' "$_r" | grep -qF 'Disagree? Reply here'
  [ "$(printf '%s' "$_r" | tail -1)" = '<!-- rc:fixed -->' ]
  ! printf '%s' "$_r" | grep -qF '<details>' || return 1
}

@test "recheck: ids that are not our open comments are ignored" {
  open_fixtures
  verdicts '{fixed: [{kind: "inline", id: 71}, {kind: "inline", id: 72}, {kind: "inline", id: 74},
                     {kind: "inline", id: 999}, {kind: "inline", id: "70; rm"}]}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  [ "$status" -eq 0 ]
  has "fixed_inline=0"
  [ ! -f "$GHLOG.replies" ]
  ! grep -qF mutation "$GHLOG" || return 1
}

@test "recheck: model text is sanitised (markers, @mentions, caps)" {
  open_fixtures
  verdicts '{fixed: [{kind: "inline", id: 70, summary: ("x <!-- rc:fixed resolved --> ask @alice " + ("y" * 1000)),
                      points: ["<!-- rc:review -->", "ping @bob", "3", "4", "5", "6", "7"]}]}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  [ "$status" -eq 0 ]
  _r="$(jq -r .body "$GHLOG.replies")"
  [ "$(printf '%s\n' "$_r" | grep -c '<!--')" = 1 ]
  ! printf '%s' "$_r" | grep -qF '@alice' || return 1
  ! printf '%s' "$_r" | grep -qF '@bob' || return 1
  [ "$(printf '%s\n' "$_r" | grep -c '^- ')" = 5 ]
  [ "$(printf '%s\n' "$_r" | sed -n 3p | wc -m | tr -d ' ')" -le 301 ]
}

@test "recheck: an unclosed backtick cannot hide a live @mention" {
  open_fixtures
  verdicts '{fixed: [{kind: "inline", id: 70, summary: "see `@alice", points: ["`x` and `@bob"]}]}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  [ "$status" -eq 0 ]
  _r="$(jq -r .body "$GHLOG.replies")"
  ! printf '%s' "$_r" | grep -qF '@alice' || return 1
  ! printf '%s' "$_r" | grep -qF '@bob' || return 1
}

@test "recheck: one grouped PR comment for the fixed outside findings" {
  outside_round_trip
  # a second tracked outside finding in the same review
  jq '.[0].body |= sub("<!-- rc:review -->"; "<!-- rc:outside-begin -->\n\n`c.sh:7`\n\n**🟠 Important**\n\n**Other [thing]**\n\n<!-- rc:outside c.sh::h::x -->\n\n<!-- rc:review -->")' \
    "$REVIEWS" >"$REVIEWS.t" && mv "$REVIEWS.t" "$REVIEWS"
  verdicts '{fixed: [{kind: "outside", fingerprint: "b.sh::g::style", summary: "Renamed.", points: ["see b.sh"]},
                     {kind: "outside", fingerprint: "c.sh::h::x", summary: "Gone."},
                     {kind: "outside", fingerprint: "nope::fp", summary: "x"}]}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  [ "$status" -eq 0 ]
  has "outside_fixed=2"
  [ "$(grep -c 'issues/5/comments.*POST' "$GHLOG")" = 1 ]
  _b="$(jq -r .body "$POSTBODY")"
  printf '%s' "$_b" | grep -qF '**Looks fixed** at `1111111`: [Style nit](https://gh/r/300) from an earlier review. Renamed.'
  printf '%s' "$_b" | grep -qF '[Other thing](https://gh/r/300) from an earlier review. Gone.'
  printf '%s' "$_b" | grep -qxF '<!-- rc:outside-fixed b.sh::g::style -->'
  printf '%s' "$_b" | grep -qxF '<!-- rc:outside-fixed c.sh::h::x -->'
  ! printf '%s' "$_b" | grep -qF 'nope::fp' || return 1
  [ "$(printf '%s' "$_b" | tail -1)" = '<sub>Recheck by [Review Council](https://github.com/deployhq/review-council/) · posted by @rc-bot (not a personal comment)</sub>' ]
}

@test "recheck: dismisses once every blocker is satisfied" {
  open_fixtures
  # fp70 fixed now, fp74 resolved by a person (ack), fp71 fixed earlier, rep reported again (not blocking)
  active "fp70 fp71 fp74 rep"
  # the two reopened important/critical comments are acknowledged elsewhere? no: drop them for this case
  jq '[.[] | select(.id != 72 and .id != 73 and .id != 80 and .in_reply_to_id != 72 and .in_reply_to_id != 73 and .in_reply_to_id != 80)]' "$RCOMMENTS" >"$RCOMMENTS.t" && mv "$RCOMMENTS.t" "$RCOMMENTS"
  verdicts '{reported: ["rep"], fixed: [{kind: "inline", id: 70, summary: "ok"}]}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  [ "$status" -eq 0 ]
  has "dismissed=1"
  has "held=0"
  logged "reviews/300/dismissals"
  [ "$(jq -r .message "$GHLOG.dismiss")" = 'Rechecked at 1111111: 1 of 3 open findings look fixed; no critical or important finding is left open.' ]
}

@test "recheck: no dismissal while a reopened comment holds" {
  open_fixtures
  active "fp70"
  verdicts '{fixed: [{kind: "inline", id: 70, summary: "ok"}]}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  [ "$status" -eq 0 ]
  has "fixed_inline=1"
  has "dismissed=0"
  has "held=3"
  [ ! -f "$GHLOG.dismiss" ]
}

# dismissable: only comment 70 (open, important), our review 300 blocks on fp70.
dismissable() {
  open_fixtures
  jq '[.[] | select(.id == 70)]' "$RCOMMENTS" >"$RCOMMENTS.t" && mv "$RCOMMENTS.t" "$RCOMMENTS"
  active "${1:-fp70}" "${2:-}"
}

@test "recheck: blocking_now keeps the block" {
  dismissable
  verdicts '{blocking_now: true, fixed: [{kind: "inline", id: 70}]}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  has "fixed_inline=1"
  has "dismissed=0"
}

@test "recheck: an untracked blocker keeps the block" {
  dismissable fp70 $'\n\n<!-- rc:blocking-untracked -->'
  verdicts '{fixed: [{kind: "inline", id: 70}]}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  has "dismissed=0"
  has "held=1"
}

@test "recheck: a still-open blocker keeps the block; still reported but not blocking satisfies it" {
  dismissable "fp70 other"
  verdicts '{fixed: [{kind: "inline", id: 70}]}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  has "dismissed=0"
  verdicts '{reported: ["other"], fixed: [{kind: "inline", id: 70}]}'
  rm -f "$GHLOG.replies"
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  has "dismissed=1"
}

@test "recheck: an open important comment not re-checked fixed holds the block" {
  dismissable "fp70"
  verdicts '{}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  has "dismissed=0"
  has "held=1"
}

@test "recheck: nothing open (all resolved by people) -> no model needed, dismissed" {
  open_fixtures
  jq '[.[] | select(.id == 74)]' "$RCOMMENTS" >"$RCOMMENTS.t" && mv "$RCOMMENTS.t" "$RCOMMENTS"
  active "fp74"
  verdicts '{checked: 0}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  [ "$status" -eq 0 ]
  has "checked=0"
  has "dismissed=1"
}

@test "recheck: a fixed outside blocker satisfies the block" {
  outside_round_trip
  jq '.[0].body |= sub("<!-- rc:blocking [^>]*-->"; "<!-- rc:blocking b.sh::g::style -->")' "$REVIEWS" >"$REVIEWS.t" && mv "$REVIEWS.t" "$REVIEWS"
  verdicts '{fixed: [{kind: "outside", fingerprint: "b.sh::g::style", summary: "Renamed."}]}'
  PATH="$SANDBOX" run --separate-stderr "$SCRIPT" recheck 5 "$VERD"
  [ "$status" -eq 0 ]
  has "outside_fixed=1"
  has "dismissed=1"
}

# ---- review path: recheck-era changes -----------------------------------------

@test "review: the looks-fixed reply uses the new format, with the re-check's reasons" {
  stale_fixtures
  printf '{"fixed":[70],"why":{"70":{"summary":"Removed in this push.","points":["gone from a.sh"]}}}\n' >"$BATS_TEST_TMPDIR/recheck.json"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER" "" "$BATS_TEST_TMPDIR/recheck.json"
  [ "$status" -eq 0 ]
  _r="$(jq -r .body "$GHLOG.replies")"
  printf '%s' "$_r" | grep -qF 'Removed in this push.'
  printf '%s' "$_r" | grep -qxF -- '- gone from a.sh'
  [ "$(printf '%s' "$_r" | tail -1)" = '<!-- rc:fixed resolved -->' ]
}

@test "review: without reasons the reply says the finding is no longer reported" {
  stale_fixtures
  printf '{"fixed":[70]}\n' >"$BATS_TEST_TMPDIR/recheck.json"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER" "" "$BATS_TEST_TMPDIR/recheck.json"
  [ "$status" -eq 0 ]
  _r="$(jq -r .body "$GHLOG.replies")"
  printf '%s' "$_r" | grep -qxF 'This finding is no longer reported.'
  ! printf '%s' "$_r" | grep -qF '<details>' || return 1
}

@test "review: a reopened blocking comment holds the block and is never stale" {
  stale_fixtures clean
  only_suggestions
  jq '.[0].body = "**🟠 Important**\n\n**Bug**\n\n<!-- rc:finding a.sh::old::gone -->"
      | . + [{id: 80, in_reply_to_id: 70, user: {login: "rc-bot"}, body: "x\n\n<!-- rc:fixed resolved -->"}]' "$RCOMMENTS" >"$RCOMMENTS.t" && mv "$RCOMMENTS.t" "$RCOMMENTS"
  printf '[{"id":300,"state":"CHANGES_REQUESTED","user":{"login":"rc-bot"},"body":"x <!-- rc:review -->"}]\n' >"$REVIEWS"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "dismissed=0"
  PATH="$SANDBOX" run "$SCRIPT" stale 5 "$LEDGER"
  [ "$output" = "[]" ]
}

@test "review: a finding whose thread a person resolved never requests changes again" {
  review_fixtures
  jq '.findings = [.findings[0]]' "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
  printf '[{"id":70,"in_reply_to_id":null,"user":{"login":"rc-bot"},"path":"a.sh","line":3,"body":"**🔴 Critical**\\n\\n<!-- rc:finding a.sh::f::bug -->"}]\n' >"$RCOMMENTS"
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_a","isResolved":true,"resolvedBy":{"login":"alice"},"comments":{"nodes":[{"databaseId":70}]}}]}}}}}\n' >"$THREADS"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  has "review_event=COMMENT"
  # resolved by us (or by nobody we know) is not an acknowledgement
  sed -i.bak 's/"login":"alice"/"login":"rc-bot"/' "$THREADS"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  has "review_event=REQUEST_CHANGES"
}

@test "review: an untracked blocking finding is recorded for the recheck" {
  review_fixtures
  jq '.findings[2].fingerprint = null | .findings[2].severity = "critical"' "$LEDGER" >"$LEDGER.t" && mv "$LEDGER.t" "$LEDGER"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  jq -r .body "$REVIEWBODY.REQUEST_CHANGES" | grep -qxF '<!-- rc:blocking-untracked -->'
  jq -r .body "$REVIEWBODY.REQUEST_CHANGES" | tail -1 | grep -qxF '<!-- rc:blocking a.sh::f::bug a.sh::f::range -->'
}

@test "review: RC_PLAN_OUT gets the run's plan, posted false until it posts" {
  review_fixtures
  export RC_PLAN_OUT="$BATS_TEST_TMPDIR/plan-out.json"
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BODY" "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$RC_PLAN_OUT")" = '{"head":"1111111111111111111111111111111111111111","status":"findings","block":true,"reported":["a.sh::f::bug","a.sh::f::range","b.sh::g::style"],"posted":true}' ]
  PATH="$SANDBOX" run "$SCRIPT" review x "$BODY" "$LEDGER"
  [ "$status" -ne 0 ]
  [ "$(jq -c .posted "$RC_PLAN_OUT")" = false ]
  PATH="$SANDBOX" run "$SCRIPT" review 5 "$BATS_TEST_TMPDIR/missing.md" "$LEDGER"
  [ "$status" -ne 0 ]
  [ "$(jq -c .posted "$RC_PLAN_OUT")" = false ]
  unset RC_PLAN_OUT
}
