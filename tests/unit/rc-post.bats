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
  for _c in sh env jq cat printf grep sed head tr mktemp rm; do
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
  : >"$GHLOG"
  printf '[]\n' >"$COMMENTS"      # default: no existing comments
  rm -f "$PRVIEW"                 # default: no PR (gh pr view exits 1)
  printf '<!-- rc:report -->\n## Digest\nhello\n' >"$BODY"

  # The test env must not leak a GH_TOKEN into the fake (would mask the
  # user-identity assertions).
  unset GH_TOKEN

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
  export GHLOG POSTBODY PATCHBODY COMMENTS PRVIEW
}

install_fake_git() {
  cat >"$FAKEDIR/git" <<'EOF'
#!/usr/bin/env sh
case "$*" in
  "rev-parse --abbrev-ref HEAD")        printf '%s\n' "${GIT_BRANCH:-feature}" ;;
  "rev-parse --abbrev-ref @{upstream}") [ "${GIT_HAS_UPSTREAM:-1}" = 1 ] && exit 0 || exit 1 ;;
  push*)                                exit 0 ;;
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
