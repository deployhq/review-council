#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for scripts/rc-invoke-provider.sh — the Google-slot
# (agy primary -> gemini fallback) invocation state machine.
#
# Uses fake CLI binaries (small POSIX sh scripts named "agy" and "gemini",
# since basename drives both command-profile selection and TOOL label
# routing in the script under test) whose behavior is switched per-call via
# env vars. No network, no real agy/gemini required.
#
# Run: bats tests/unit/rc-invoke-provider.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/rc-invoke-provider.sh"

setup() {
  FAKEDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKEDIR"

  PROMPT_FILE="$BATS_TEST_TMPDIR/prompt.txt"
  printf 'Please review this change and report your Findings.\n' >"$PROMPT_FILE"

  # --- fake agy -------------------------------------------------------
  # Modes (AGY_MODE, or AGY_MODE_1 / AGY_MODE_2 to vary per call):
  #   ok          -> valid review, exit 0
  #   empty       -> nothing, exit 0
  #   empty-slow  -> sleep $AGY_SLEEP then nothing, exit 0
  #   ok-authish  -> valid review whose body mentions login/oauth/429/503
  #   auth        -> auth error, exit 1
  #   quota       -> quota error, exit 1
  #   overload    -> 503 / high demand error, exit 1
  #   authish-prose -> inline (non-heading) Findings/Overall Assessment + auth
  #                    error; must classify AUTH, not OK
  #   hang        -> sleep $AGY_SLEEP (default 999s) to force a wrapper kill
  #   hang-notrap -> trap '' TERM then sleep; only SIGKILL can stop it
  # Bookkeeping (set only if the env var is exported by the test):
  #   AGY_CALLS      -> one "call" line appended per invocation (call counting)
  #   AGY_ARGS       -> one space-joined line of this call's argv appended
  #   AGY_PROMPT_OUT -> the exact value of the arg following -p, written raw
  #                     (byte-for-byte) so a test can prove the prompt arrived
  #                     as a SINGLE intact argument (no word-split/newline-mangle)
  cat >"$FAKEDIR/agy" <<'AGY_EOF'
#!/usr/bin/env sh
call_n=1
if [ -n "${AGY_CALLS:-}" ]; then
  echo call >>"$AGY_CALLS"
  call_n=$(wc -l <"$AGY_CALLS" | tr -d ' ')
fi

if [ -n "${AGY_ARGS:-}" ]; then
  {
    printf '==CALL %s==\n' "$call_n"
    for a in "$@"; do printf '%s ' "$a"; done
    printf '\n'
  } >>"$AGY_ARGS"
fi

if [ -n "${AGY_PROMPT_OUT:-}" ]; then
  # Capture the single argument that immediately follows -p, exactly as
  # received. If the prompt were word-split, this would be only the first
  # token; if the newline were mangled, it would differ byte-for-byte.
  _prev=""
  for a in "$@"; do
    if [ "$_prev" = "-p" ]; then
      printf '%s' "$a" >"$AGY_PROMPT_OUT"
      break
    fi
    _prev="$a"
  done
fi

case "$call_n" in
  1) mode="${AGY_MODE_1:-${AGY_MODE:-ok}}" ;;
  2) mode="${AGY_MODE_2:-${AGY_MODE:-ok}}" ;;
  *) mode="${AGY_MODE:-ok}" ;;
esac

case "$mode" in
  ok)
    cat <<'REVIEW_EOF'
Findings:
- [P2] Example finding from agy.

What's Good:
- Solid structure.

Overall Assessment: Looks fine.
REVIEW_EOF
    exit 0
    ;;
  ok-authish)
    # A VALID review whose body legitimately mentions auth/quota/overload
    # words — must still classify as OK (regression guard for Fix B).
    cat <<'REVIEW_EOF'
Findings:
- [P2] The login handler should reject an expired oauth token.
- [P3] The API returns 429 on rate limits and 503 under high demand;
  add backoff.

What's Good:
- Clear separation of concerns.

Overall Assessment: Solid change, minor nits above.
REVIEW_EOF
    exit 0
    ;;
  empty)
    exit 0
    ;;
  empty-slow)
    sleep "${AGY_SLEEP:-1}"
    exit 0
    ;;
  auth)
    echo "Error: not authenticated. Please login to continue." >&2
    exit 1
    ;;
  quota)
    echo "Error: 429 Too Many Requests -- TerminalQuotaError" >&2
    exit 1
    ;;
  overload)
    echo "Error: 503 Service Unavailable - high demand" >&2
    exit 1
    ;;
  authish-prose)
    # "Findings" and "Overall Assessment" appear ONLY as inline prose (never as
    # heading-shaped lines), alongside an auth error. Must classify AUTH (and
    # fall back), NOT be mistaken for a valid review (regression guard for Fix D).
    echo "Authentication failed: not authenticated. I could not generate the Findings section or the Overall Assessment for this review." >&2
    exit 1
    ;;
  hang)
    sleep "${AGY_SLEEP:-999}"
    exit 0
    ;;
  hang-notrap)
    # Ignore SIGTERM so ONLY the SIGKILL escalation can stop it — proves the
    # cap is HARD, not merely a polite TERM.
    trap '' TERM
    sleep "${AGY_SLEEP:-40}"
    exit 0
    ;;
esac
AGY_EOF
  chmod +x "$FAKEDIR/agy"

  # --- fake gemini ------------------------------------------------------
  # Same mode vocabulary as agy, plus "dasher" for the Workspace-ineligible
  # auth flavor (still classified as AUTH by the script under test).
  cat >"$FAKEDIR/gemini" <<'GEM_EOF'
#!/usr/bin/env sh
call_n=1
if [ -n "${GEM_CALLS:-}" ]; then
  echo call >>"$GEM_CALLS"
  call_n=$(wc -l <"$GEM_CALLS" | tr -d ' ')
fi

if [ -n "${GEM_ARGS:-}" ]; then
  {
    printf '==CALL %s==\n' "$call_n"
    for a in "$@"; do printf '%s ' "$a"; done
    printf '\n'
  } >>"$GEM_ARGS"
fi

case "$call_n" in
  1) mode="${GEM_MODE_1:-${GEM_MODE:-ok}}" ;;
  *) mode="${GEM_MODE:-ok}" ;;
esac

case "$mode" in
  ok)
    cat <<'REVIEW_EOF'
Findings:
- [P3] Example finding from gemini.

What's Good:
- Reasonable approach.

Overall Assessment: Fine overall.
REVIEW_EOF
    exit 0
    ;;
  empty)
    exit 0
    ;;
  auth)
    echo "Error: not authenticated. Please login to continue." >&2
    exit 1
    ;;
  dasher)
    echo "IneligibleTierError: reasonCode DASHER_USER, not eligible for Gemini Code Assist for individuals" >&2
    exit 1
    ;;
  quota)
    echo "Error: 429 Too Many Requests -- TerminalQuotaError" >&2
    exit 1
    ;;
esac
GEM_EOF
  chmod +x "$FAKEDIR/gemini"

  # --- fake codex -------------------------------------------------------
  # Codex has NO CLI fallback, so it is invoked as
  #   rc-invoke-provider.sh <codex> "" <prompt-file>.
  # The prompt reaches `codex exec` as a POSITIONAL arg (for codex, -p is
  # --profile, not the prompt), so unlike agy/gemini this fake ignores -p and
  # just records its full argv for the codex-profile-argv assertion.
  # Modes (CDX_MODE, or CDX_MODE_1 / CDX_MODE_2 to vary per call):
  #   ok          -> valid review, exit 0
  #   empty       -> nothing, exit 0
  #   empty-slow  -> sleep $CDX_SLEEP then nothing, exit 0
  #   auth        -> auth error, exit 1
  #   quota       -> quota error, exit 1
  #   timeout     -> sleep $CDX_SLEEP (default 999s) to force a wrapper kill
  # Bookkeeping (set only if the env var is exported by the test):
  #   CDX_CALLS -> one "call" line appended per invocation (call counting)
  #   CDX_ARGS  -> one space-joined line of this call's argv appended
  cat >"$FAKEDIR/codex" <<'CDX_EOF'
#!/usr/bin/env sh
call_n=1
if [ -n "${CDX_CALLS:-}" ]; then
  echo call >>"$CDX_CALLS"
  call_n=$(wc -l <"$CDX_CALLS" | tr -d ' ')
fi

if [ -n "${CDX_ARGS:-}" ]; then
  {
    printf '==CALL %s==\n' "$call_n"
    for a in "$@"; do printf '%s ' "$a"; done
    printf '\n'
  } >>"$CDX_ARGS"
fi

case "$call_n" in
  1) mode="${CDX_MODE_1:-${CDX_MODE:-ok}}" ;;
  2) mode="${CDX_MODE_2:-${CDX_MODE:-ok}}" ;;
  *) mode="${CDX_MODE:-ok}" ;;
esac

case "$mode" in
  ok)
    cat <<'REVIEW_EOF'
Findings:
- [P2] Example finding from codex.

What's Good:
- Reasonable structure.

Overall Assessment: Looks fine.
REVIEW_EOF
    exit 0
    ;;
  empty)
    exit 0
    ;;
  empty-slow)
    sleep "${CDX_SLEEP:-1}"
    exit 0
    ;;
  auth)
    echo "Error: not authenticated. Please login to continue." >&2
    exit 1
    ;;
  quota)
    echo "Error: 429 Too Many Requests -- TerminalQuotaError" >&2
    exit 1
    ;;
  timeout)
    sleep "${CDX_SLEEP:-999}"
    exit 0
    ;;
esac
CDX_EOF
  chmod +x "$FAKEDIR/codex"

  AGY="$FAKEDIR/agy"
  GEMINI="$FAKEDIR/gemini"
  CODEX="$FAKEDIR/codex"

  AGY_CALLS="$BATS_TEST_TMPDIR/agy_calls"
  AGY_ARGS="$BATS_TEST_TMPDIR/agy_args"
  GEM_CALLS="$BATS_TEST_TMPDIR/gem_calls"
  GEM_ARGS="$BATS_TEST_TMPDIR/gem_args"
  CDX_CALLS="$BATS_TEST_TMPDIR/cdx_calls"
  CDX_ARGS="$BATS_TEST_TMPDIR/cdx_args"
  export AGY_CALLS AGY_ARGS GEM_CALLS GEM_ARGS CDX_CALLS CDX_ARGS
}

# call_count <file>: prints 0 if the bookkeeping file doesn't exist yet.
call_count() {
  if [ -f "$1" ]; then
    wc -l <"$1" | tr -d ' '
  else
    echo 0
  fi
}

@test "success: primary agy returns a valid review" {
  AGY_MODE=ok run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Antigravity"*) : ;;
  *) echo "expected output to start with TOOL: Antigravity" && return 1 ;;
  esac
  echo "$output" | grep -qi 'findings'
  echo "$stderr" | grep -q 'ELAPSED:'
}

@test "ok-review-with-authish-words: valid review mentioning login/oauth/429/503 classifies OK, gemini not called" {
  AGY_MODE=ok-authish run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Antigravity"*) : ;;
  *) echo "expected TOOL: Antigravity (review must not be discarded for auth-ish words)" && return 1 ;;
  esac
  # sanity: the auth-ish words really are present in the accepted review body
  echo "$output" | grep -q 'oauth'
  echo "$output" | grep -q '429'
  [ "$(call_count "$GEM_CALLS")" -eq 0 ]
}

@test "inline-prose-not-headings: Findings/Overall Assessment as prose + auth error -> AUTH, falls back (not OK)" {
  # If OK-detection used bare substrings, this auth-error response (whose body
  # merely mentions the words inline) would false-positive as a valid review
  # and be returned as TOOL: Antigravity. Anchoring to heading lines makes it
  # classify AUTH, so the slot falls back to gemini instead.
  AGY_MODE=authish-prose GEM_MODE=ok run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Gemini"*) : ;;
  *) echo "expected TOOL: Gemini (inline-prose agy output must NOT be accepted as OK)" && return 1 ;;
  esac
  [ "$(call_count "$AGY_CALLS")" -eq 1 ]
  [ "$(call_count "$GEM_CALLS")" -eq 1 ]
}

@test "fast-empty-then-retry-success: primary empty fast, retry succeeds, gemini never called" {
  RC_REVIEWER_TIMEOUT=6 AGY_MODE_1=empty AGY_MODE_2=ok run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Antigravity"*) : ;;
  *) echo "expected TOOL: Antigravity" && return 1 ;;
  esac
  [ "$(call_count "$AGY_CALLS")" -eq 2 ]
  [ "$(call_count "$GEM_CALLS")" -eq 0 ]
}

@test "fast-empty-then-retry-auth-fail: SKIPPED note reflects the retry's auth failure, not 'empty output'" {
  # First agy call: fast empty -> triggers the one retry. Retry: auth-fails.
  # No fallback. The note must carry the retry's REAL class (auth), not be
  # flattened to "empty output after retry" (regression guard for Fix E).
  RC_REVIEWER_TIMEOUT=6 AGY_MODE_1=empty AGY_MODE_2=auth run --separate-stderr "$SCRIPT" "$AGY" "" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 1 ]
  case "$output" in
  "SKIPPED: Google (Antigravity) unavailable — agy: auth failure on retry"*) : ;;
  *) echo "expected SKIPPED note to reflect the auth failure on retry" && return 1 ;;
  esac
  # must NOT be flattened to the generic empty note
  ! echo "$output" | grep -q 'empty output after retry'
  [ "$(call_count "$AGY_CALLS")" -eq 2 ]
  [ "$(call_count "$GEM_CALLS")" -eq 0 ]
}

@test "slow-empty-no-retry-fallback: primary empty but slow (>= T/3), no retry, falls back to gemini" {
  RC_REVIEWER_TIMEOUT=6 AGY_MODE=empty-slow AGY_SLEEP=3 GEM_MODE=ok run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Gemini"*) : ;;
  *) echo "expected TOOL: Gemini" && return 1 ;;
  esac
  [ "$(call_count "$AGY_CALLS")" -eq 1 ]
  [ "$(call_count "$GEM_CALLS")" -eq 1 ]
}

@test "auth-fail-fallback (a): primary auth-fails, gemini fallback succeeds" {
  AGY_MODE=auth GEM_MODE=ok run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Gemini"*) : ;;
  *) echo "expected TOOL: Gemini" && return 1 ;;
  esac
  [ "$(call_count "$AGY_CALLS")" -eq 1 ]
}

@test "auth-fail-fallback (b): primary auth-fails, gemini also auth-fails -> SKIPPED leads with Antigravity" {
  AGY_MODE=auth GEM_MODE=dasher run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 1 ]
  case "$output" in
  "SKIPPED: Google (Antigravity) unavailable"*) : ;;
  *) echo "expected SKIPPED to lead with Google (Antigravity)" && return 1 ;;
  esac
  # Attribution is the most load-bearing requirement — assert the EXACT
  # per-tool wording, not just the label substrings.
  echo "$output" | grep -qF 'agy: auth failure'
  echo "$output" | grep -qF 'gemini fallback: ineligible (auth/DASHER)'
}

@test "quota-fail: primary quota error, no retry, fallback path taken" {
  AGY_MODE=quota GEM_MODE=ok run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Gemini"*) : ;;
  *) echo "expected TOOL: Gemini" && return 1 ;;
  esac
  [ "$(call_count "$AGY_CALLS")" -eq 1 ]
}

@test "overload-fail: primary 503/high-demand error, no retry, fallback gemini succeeds" {
  AGY_MODE=overload GEM_MODE=ok run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Gemini"*) : ;;
  *) echo "expected TOOL: Gemini" && return 1 ;;
  esac
  [ "$(call_count "$AGY_CALLS")" -eq 1 ]
  [ "$(call_count "$GEM_CALLS")" -eq 1 ]
}

@test "timeout: primary hangs, wrapper kills it (TIMEOUT), no retry, fallback attempted" {
  _t_start=$(date +%s)
  RC_REVIEWER_TIMEOUT=2 AGY_MODE=hang AGY_SLEEP=40 GEM_MODE=ok run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  _t_elapsed=$(( $(date +%s) - _t_start ))
  echo "status=$status wall=${_t_elapsed}s"
  echo "output=<<$output>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Gemini"*) : ;;
  *) echo "expected TOOL: Gemini" && return 1 ;;
  esac
  [ "$(call_count "$AGY_CALLS")" -eq 1 ]
  echo "$stderr" | grep -q 'ELAPSED:'
  # Bounded: cap 2 + KILL grace 3 + gemini ~instant. Must NOT wait the 40s
  # sleep — a generous <10s window proves the cap fired.
  [ "$_t_elapsed" -lt 10 ]
}

@test "hard-cap: TERM-resistant primary is KILLed at the cap, fallback succeeds, bounded elapsed" {
  # hang-notrap ignores SIGTERM, so only the SIGKILL escalation can stop it.
  # This is what actually proves the cap is HARD (not a polite TERM).
  _hc_start=$(date +%s)
  RC_REVIEWER_TIMEOUT=2 AGY_MODE=hang-notrap AGY_SLEEP=40 GEM_MODE=ok run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  _hc_elapsed=$(( $(date +%s) - _hc_start ))
  echo "status=$status wall=${_hc_elapsed}s"
  echo "output=<<$output>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Gemini"*) : ;;
  *) echo "expected TOOL: Gemini" && return 1 ;;
  esac
  [ "$(call_count "$AGY_CALLS")" -eq 1 ]
  echo "$stderr" | grep -q 'ELAPSED:'
  # cap 2 + KILL grace 3 = ~5s worst case; generous <10s window, non-flaky.
  # Without the KILL escalation this would hang ~40s (the sleep) and fail.
  [ "$_hc_elapsed" -lt 10 ]
}

@test "no-fallback-skipped: primary auth-fails, no fallback bin given -> SKIPPED attributed to agy" {
  AGY_MODE=auth run --separate-stderr "$SCRIPT" "$AGY" "" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 1 ]
  case "$output" in
  "SKIPPED: Google (Antigravity) unavailable — agy: auth failure"*) : ;;
  *) echo "expected SKIPPED attributed to agy/Antigravity with no fallback clause" && return 1 ;;
  esac
  # no fallback clause at all
  ! echo "$output" | grep -q 'fallback:'
  [ "$(call_count "$GEM_CALLS")" -eq 0 ]
}

@test "print-timeout-unit-suffix: agy argv carries --print-timeout with an s-suffixed value" {
  AGY_MODE=ok run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  [ "$status" -eq 0 ]
  [ -f "$AGY_ARGS" ]
  echo "agy argv: $(cat "$AGY_ARGS")"
  grep -qE -- '--print-timeout [0-9][0-9]*s' "$AGY_ARGS"
}

@test "env-passthrough: RC_GOOGLE_ADD_DIR/RC_GOOGLE_MODEL appended (and absent when unset)" {
  # (a) both env knobs set -> both flags appear in agy's argv.
  ARGS_WITH="$BATS_TEST_TMPDIR/args_with"
  AGY_MODE=ok AGY_ARGS="$ARGS_WITH" \
    RC_GOOGLE_ADD_DIR=/tmp/somedir RC_GOOGLE_MODEL=some-model \
    run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "argv(with)=<<$(cat "$ARGS_WITH")>>"
  [ "$status" -eq 0 ]
  grep -qF -- '--add-dir /tmp/somedir' "$ARGS_WITH"
  grep -qF -- '--model some-model' "$ARGS_WITH"

  # (b) neither env knob set -> neither flag appears.
  ARGS_WITHOUT="$BATS_TEST_TMPDIR/args_without"
  AGY_MODE=ok AGY_ARGS="$ARGS_WITHOUT" \
    run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "argv(without)=<<$(cat "$ARGS_WITHOUT")>>"
  [ "$status" -eq 0 ]
  ! grep -qF -- '--add-dir' "$ARGS_WITHOUT"
  ! grep -qF -- '--model' "$ARGS_WITHOUT"
}

@test "prompt-arg-integrity: multi-line prompt with spaces reaches the CLI as one intact -p arg" {
  # Prompt with embedded spaces AND a newline, NO trailing newline (command
  # substitution in the script strips trailing newlines, so this makes the
  # captured -p value byte-comparable to the source file).
  SPACEY_PROMPT="$BATS_TEST_TMPDIR/spacey_prompt.txt"
  printf 'first line has several spaces here\nsecond line also has some spaces' >"$SPACEY_PROMPT"

  CAPTURED_PROMPT="$BATS_TEST_TMPDIR/captured_prompt.txt"
  AGY_MODE=ok AGY_PROMPT_OUT="$CAPTURED_PROMPT" \
    run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$SPACEY_PROMPT"
  echo "status=$status"
  echo "captured=<<$(cat "$CAPTURED_PROMPT")>>"
  [ "$status" -eq 0 ]
  # The -p argument must be byte-identical to the whole prompt file. A word
  # split would leave only "first" here; a mangled newline would differ.
  cmp -s "$CAPTURED_PROMPT" "$SPACEY_PROMPT"
  # Belt-and-suspenders: the captured arg still contains the newline (proving
  # both lines survived as a single argument).
  grep -q 'second line also has some spaces' "$CAPTURED_PROMPT"
}

@test "usage-error: wrong number of args exits 2" {
  run "$SCRIPT" "$AGY"
  echo "status=$status"
  [ "$status" -eq 2 ]
}

@test "usage-error: too many args exits 2" {
  run "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE" "extra"
  echo "status=$status"
  [ "$status" -eq 2 ]
}

@test "usage-error: RC_REVIEWER_TIMEOUT=0 exits 2 (timeout 0 = no limit)" {
  RC_REVIEWER_TIMEOUT=0 run "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 2 ]
  # agy must never be invoked when the budget is invalid
  [ "$(call_count "$AGY_CALLS")" -eq 0 ]
}

@test "usage-error: RC_REVIEWER_TIMEOUT=abc (non-integer) exits 2" {
  RC_REVIEWER_TIMEOUT=abc run "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  [ "$status" -eq 2 ]
  [ "$(call_count "$AGY_CALLS")" -eq 0 ]
}

@test "absent: primary binary not resolvable -> ABSENT, falls back to gemini" {
  GEM_MODE=ok run --separate-stderr "$SCRIPT" "/no/such/path/agy" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Gemini"*) : ;;
  *) echo "expected TOOL: Gemini" && return 1 ;;
  esac
  [ "$(call_count "$GEM_CALLS")" -eq 1 ]
}

@test "absent: primary absent and no fallback -> SKIPPED absent, attributed to agy" {
  run --separate-stderr "$SCRIPT" "/no/such/path/agy" "" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 1 ]
  case "$output" in
  "SKIPPED: Google (Antigravity) unavailable — agy: absent"*) : ;;
  *) echo "expected SKIPPED absent attributed to agy" && return 1 ;;
  esac
}

# ===========================================================================
# Phase 4 — Codex slot (codex primary, NO fallback) + tool-agnostic attribution
# ===========================================================================

@test "codex-success: primary codex returns a valid review -> TOOL: Codex" {
  CDX_MODE=ok run --separate-stderr "$SCRIPT" "$CODEX" "" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Codex"*) : ;;
  *) echo "expected output to start with TOOL: Codex" && return 1 ;;
  esac
  echo "$output" | grep -qi 'findings'
  echo "$stderr" | grep -q 'ELAPSED:'
}

@test "codex-no-fallback-auth: codex auth-fails, no fallback -> SKIPPED led by Codex (not Google)" {
  CDX_MODE=auth run --separate-stderr "$SCRIPT" "$CODEX" "" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 1 ]
  case "$output" in
  "SKIPPED: Codex unavailable — codex: auth failure"*) : ;;
  *) echo "expected SKIPPED led by Codex with the codex auth note" && return 1 ;;
  esac
  # Attribution must have generalized: a codex SKIPPED must NOT say "Google".
  ! echo "$output" | grep -q 'Google'
  # no fallback clause at all
  ! echo "$output" | grep -q 'fallback:'
}

@test "codex-profile-argv: frozen 'codex exec' argv (subcommand + read-only sandbox, positional prompt)" {
  CDX_MODE=ok run --separate-stderr "$SCRIPT" "$CODEX" "" "$PROMPT_FILE"
  echo "status=$status"
  [ "$status" -eq 0 ]
  [ -f "$CDX_ARGS" ]
  echo "codex argv: $(cat "$CDX_ARGS")"
  # Frozen shape: the non-interactive `exec` subcommand, then the least-privilege
  # read-only sandbox, pinned against `codex exec --help`.
  grep -qF -- 'exec --sandbox read-only --skip-git-repo-check' "$CDX_ARGS"
  # Least privilege: the reviewer must NOT run with the "EXTREMELY DANGEROUS"
  # no-sandbox flag.
  ! grep -qF -- 'dangerously-bypass' "$CDX_ARGS"
  # The prompt is a POSITIONAL arg for codex (NOT after -p) — prove it arrived.
  grep -qF -- 'Please review this change' "$CDX_ARGS"
  # And codex must NOT be handed a -p flag (that is --profile for codex exec).
  ! grep -qE -- '(^| )-p( |$)' "$CDX_ARGS"
}

@test "codex-fast-empty-retry: codex empty-fast -> exactly one retry (shared state machine)" {
  RC_REVIEWER_TIMEOUT=6 CDX_MODE_1=empty CDX_MODE_2=ok \
    run --separate-stderr "$SCRIPT" "$CODEX" "" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Codex"*) : ;;
  *) echo "expected TOOL: Codex after the one fast-empty retry" && return 1 ;;
  esac
  # Exactly one retry -> two codex invocations total, no more.
  [ "$(call_count "$CDX_CALLS")" -eq 2 ]
}

@test "attribution-per-family: SKIPPED lead label maps by basename (agy->Antigravity, codex->Codex)" {
  # agy (no fallback) auth-fails -> leads with Google (Antigravity).
  AGY_MODE=auth run --separate-stderr "$SCRIPT" "$AGY" "" "$PROMPT_FILE"
  echo "agy-status=$status agy-output=<<$output>>"
  [ "$status" -eq 1 ]
  case "$output" in
  "SKIPPED: Google (Antigravity) unavailable"*) : ;;
  *) echo "expected agy SKIPPED to lead with Google (Antigravity)" && return 1 ;;
  esac

  # codex (no fallback) auth-fails -> leads with Codex, never Google.
  CDX_MODE=auth run --separate-stderr "$SCRIPT" "$CODEX" "" "$PROMPT_FILE"
  echo "codex-status=$status codex-output=<<$output>>"
  [ "$status" -eq 1 ]
  case "$output" in
  "SKIPPED: Codex unavailable"*) : ;;
  *) echo "expected codex SKIPPED to lead with Codex" && return 1 ;;
  esac
  ! echo "$output" | grep -q 'Google'
}

@test "google-single-row (double-vote guard): agy present -> exactly one TOOL line, gemini only via internal fallback" {
  AGY_MODE=ok run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  # The Google slot is a single dispatch unit: exactly one TOOL: line emitted.
  [ "$(printf '%s\n' "$output" | grep -c '^TOOL:')" -eq 1 ]
  case "$output" in
  "TOOL: Antigravity"*) : ;;
  *) echo "expected the single row to be TOOL: Antigravity" && return 1 ;;
  esac
  # gemini is reached ONLY as an internal fallback (never here, agy succeeded).
  [ "$(call_count "$GEM_CALLS")" -eq 0 ]
}

# ===========================================================================
# Phase 4 — --probe health check (reuses the frozen profiles + classifier)
# ===========================================================================

@test "probe-healthy: codex responds cleanly -> HEALTHY" {
  CDX_MODE=ok run "$SCRIPT" --probe "$CODEX" ""
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

@test "probe-cold-inconclusive: probe TIMEOUT -> INCONCLUSIVE, never UNHEALTHY (cold agy must survive)" {
  _p_start=$(date +%s)
  RC_HEALTH_PROBE_TIMEOUT=2 CDX_MODE=timeout CDX_SLEEP=40 \
    run "$SCRIPT" --probe "$CODEX" ""
  _p_elapsed=$(( $(date +%s) - _p_start ))
  echo "status=$status wall=${_p_elapsed}s"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "INCONCLUSIVE"*) : ;;
  *) echo "expected INCONCLUSIVE for a probe timeout (cold start)" && return 1 ;;
  esac
  # A timeout must NEVER be reported as a health failure.
  ! echo "$output" | grep -q 'UNHEALTHY'
  # Bounded by the short probe cap + KILL grace, not the 40s sleep.
  [ "$_p_elapsed" -lt 10 ]
}

@test "probe-unhealthy-auth: codex auth-fails -> UNHEALTHY (positive evidence)" {
  CDX_MODE=auth run "$SCRIPT" --probe "$CODEX" ""
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "UNHEALTHY:"*) : ;;
  *) echo "expected UNHEALTHY: for a codex auth failure" && return 1 ;;
  esac
  echo "$output" | grep -qi 'auth'
}

@test "probe-google-slot-fallback: agy unhealthy, gemini healthy -> slot HEALTHY" {
  AGY_MODE=auth GEM_MODE=ok run "$SCRIPT" --probe "$AGY" "$GEMINI"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
  # The slot's own fallback logic ran: agy probed (unhealthy), gemini probed.
  [ "$(call_count "$AGY_CALLS")" -eq 1 ]
  [ "$(call_count "$GEM_CALLS")" -eq 1 ]
}

@test "probe usage-error: --probe with wrong arg count exits 2" {
  run "$SCRIPT" --probe "$CODEX"
  echo "status=$status"
  [ "$status" -eq 2 ]
}
