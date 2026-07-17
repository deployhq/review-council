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
  #   rubric-echo-auth -> echoes the refutation prompt's rubric enumeration
  #                    ("Allowed: UPHELD | REFUTED | INCONCLUSIVE") + a real
  #                    auth-error phrase, no actual <id> | VERDICT line; must
  #                    classify AUTH, not OK (CR-1 regression)
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
  rubric-echo-auth)
    # CR-1 regression: the merged stream echoes the refutation prompt's rubric
    # enumeration verbatim ("Allowed: UPHELD | REFUTED | INCONCLUSIVE") plus a
    # genuine auth-error phrase, but contains NO actual "<id> | VERDICT — ..."
    # line. The old loose VERDICT_PATTERN matched the bare "| REFUTED" / "|
    # INCONCLUSIVE" substrings in the rubric line and misclassified this as
    # OK, hiding the real auth failure. Must classify AUTH.
    echo "Error: not logged in. Allowed: UPHELD | REFUTED | INCONCLUSIVE" >&2
    exit 1
    ;;
  verdicts)
    # Step-4 REFUTATION output: pipe-delimited verdict lines, NO review headings.
    # Must classify OK (the Phase-4 collapse routes refutation through this same
    # script; verdict output carries none of the review headings the OK-guard
    # keyed on).
    cat <<'VERDICT_EOF'
F1 | REFUTED — @user is loaded only from current_account.users, so it is scoped.
F2 | UPHELD — token login emits the event on the GET with no interstitial.
F3 | INCONCLUSIVE — cannot execute the spreadsheet scenario here.
VERDICT_EOF
    exit 0
    ;;
  verdicts-authish)
    # Verdict output whose MERGED stream (run_capped 2>&1) also carries a repo
    # phrase the model echoed while exploring — here a Rails flash "Please log in
    # to continue." that matches AUTH_PATTERN. Must STILL classify OK: the verdict
    # shape wins before the hard-fail patterns (the exact live smoke-test bug).
    cat <<'VERDICT_EOF'
F1 | UPHELD — token login emits auth.session_started directly on GET /login?token=...
F2 | REFUTED — @user is already account-scoped at this call site.
VERDICT_EOF
    echo "    96    notice: 'Your e-mail address has been verified. Please log in to continue.'" >&2
    exit 0
    ;;
  quota-individual)
    # agy's REAL quota phrasing (not the generic 429/TerminalQuotaError). Must
    # classify QUOTA -> fast-fail (no wasted fast-empty retry), not EMPTY.
    echo "Error: Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 145h11m19s." >&2
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
  rate-limit)
    # A BARE 429 with NO terminal-quota phrase: a tokens-per-minute throttle
    # that clears in seconds. Must classify RATE_LIMIT (soft, retryable) —
    # NOT QUOTA, which permanently kills the slot for the whole run.
    echo "Error: 429 Too Many Requests" >&2
    exit 1
    ;;
  rate-limit-hard)
    # 429 AND a terminal phrase. OpenAI returns HTTP 429 for BOTH a per-minute
    # throttle AND a real insufficient_quota, so the HARD check must win the
    # precedence. This is the guard that stops the fix from over-correcting.
    echo "Error: 429 - insufficient_quota: You exceeded your current quota." >&2
    exit 1
    ;;
  rate-limit-retryafter)
    # A throttle that states its own backoff.
    echo "Error: 429 Too Many Requests. Retry-After: 2" >&2
    exit 1
    ;;
  rate-limit-int64)
    # Retry-After at the INT64 boundary. It is ALL DIGITS, so a charset-only
    # guard admits it — and `$((v + 1))` then WRAPS NEGATIVE, sailing past the
    # `-lt $(remaining)` budget check and sleeping ~forever.
    echo "Error: 429 Too Many Requests. Retry-After: 9223372036854775807" >&2
    exit 1
    ;;
  rate-limit-huge)
    # Retry-After beyond INT64. Also all digits, but here dash aborts outright
    # with "Illegal number" under `set -e` — losing the attributed SKIPPED and
    # the ELAPSED line the orchestrator meters its run budget with.
    echo "Error: 429 Too Many Requests. Retry-After: 999999999999999999999999" >&2
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

@test "refutation-verdicts: UPHELD/REFUTED/INCONCLUSIVE output (no review headings) classifies OK, returned as TOOL" {
  # The Phase-4 collapse routes Step-4 refutation through this script; a verdict
  # set has none of the review headings, so it must be recognized on its own
  # shape or it falls through to the hard-fail patterns.
  AGY_MODE=verdicts run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Antigravity"*) : ;;
  *) echo "expected TOOL: Antigravity (verdict output must classify OK, not a hard fail)" && return 1 ;;
  esac
  echo "$output" | grep -qi 'REFUTED'
  [ "$(call_count "$GEM_CALLS")" -eq 0 ]
}

@test "refutation-verdicts-authish: verdict output whose merged stream echoes repo source ('please log in') still classifies OK, not AUTH" {
  # The live smoke-test bug: a successful refutation of an auth PR was dropped as
  # 'auth failure' because the model's reasoning (merged via 2>&1) echoed a
  # 'Please log in' flash from the code, and the verdict format wasn't recognized.
  AGY_MODE=verdicts-authish GEM_MODE=ok run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Antigravity"*) : ;;
  *) echo "expected TOOL: Antigravity (verdicts must not fall through to AUTH on echoed source)" && return 1 ;;
  esac
  # agy succeeded on its own shape → gemini fallback must NOT be consulted
  [ "$(call_count "$GEM_CALLS")" -eq 0 ]
}

@test "rubric-echo-not-verdict: rubric enumeration ('Allowed: UPHELD | REFUTED | INCONCLUSIVE') + auth phrase classifies AUTH, not OK (CR-1 regression)" {
  # CodeRabbit CR-1: the old loose VERDICT_PATTERN matched a bare verdict word
  # adjacent to ANY pipe on a line, so the refutation prompt's own rubric
  # enumeration -- echoed back verbatim by a model quoting its instructions --
  # false-positived the OK-guard and hid a genuine auth failure reported on
  # the same merged-stream line. No fallback bin, so a correct classification
  # exits 1 with a SKIPPED "... auth failure" line; the old bug exited 0 as OK.
  AGY_MODE=rubric-echo-auth run --separate-stderr "$SCRIPT" "$AGY" "" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 1 ]
  case "$output" in
  SKIPPED:*) : ;;
  *) echo "expected SKIPPED (AUTH), not OK/TOOL" && return 1 ;;
  esac
  echo "$output" | grep -qi 'auth failure'
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

@test "quota-fail-agy-individual: agy 'Individual quota reached' -> QUOTA (one call, no retry), not EMPTY" {
  # Regression for the deployhq#1043 smoke test: agy's real quota phrasing was
  # missed by QUOTA_PATTERN, so it classified EMPTY -> a wasted fast-empty retry
  # (2 calls) + a misleading 'empty output after retry' note. Must be QUOTA:
  # exactly one agy call, straight to gemini.
  AGY_MODE=quota-individual GEM_MODE=ok run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Gemini"*) : ;;
  *) echo "expected TOOL: Gemini (agy quota -> fallback)" && return 1 ;;
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

# ---------------------------------------------------------------------------
# Rate limit (transient) vs. quota (terminal)
#
# QUOTA_PATTERN used to bundle a bare `429`/`rate limit` together with the real
# terminal phrasings, so a 60-second tokens-per-minute throttle classified as
# QUOTA -> "quota exhausted" -> a HARD skip: no retry, no MCP fallback, slot
# gone for the whole run. Observed live: Codex reviewed fine in Round 1, was
# "quota exhausted" for the Step-4 refutation ~2min later, then answered a
# direct probe 6s afterwards. The council's own Round-1 -> refutation burst is
# what trips the per-minute limit, so it recurs on any large diff.
#
# Precedence is the crux: OpenAI returns HTTP 429 for BOTH a throttle AND a real
# insufficient_quota, so HARD must be checked BEFORE soft.
# ---------------------------------------------------------------------------

@test "rate-limit: bare 429 is retried once and succeeds -> TOOL: Codex" {
  RC_REVIEWER_TIMEOUT=6 RC_RATE_LIMIT_BACKOFF=0 \
    CDX_MODE_1=rate-limit CDX_MODE_2=ok \
    run --separate-stderr "$SCRIPT" "$CODEX" "" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Codex"*) : ;;
  *) echo "expected TOOL: Codex (a throttle must not kill the slot)" && return 1 ;;
  esac
  # exactly two calls: the throttled first try + the one retry
  [ "$(call_count "$CDX_CALLS")" -eq 2 ]
}

@test "rate-limit-precedence: 429 WITH insufficient_quota stays QUOTA (hard, no retry)" {
  # The guard against over-correcting: a real hard quota that happens to arrive
  # over HTTP 429 must NOT be softened into a retryable throttle.
  RC_REVIEWER_TIMEOUT=6 RC_RATE_LIMIT_BACKOFF=0 CDX_MODE=rate-limit-hard \
    run --separate-stderr "$SCRIPT" "$CODEX" "" "$PROMPT_FILE"
  echo "output=<<$output>>"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'quota exhausted'
  ! echo "$output" | grep -qF 'rate limited'
  # hard = terminal: exactly ONE call, no retry wasted
  [ "$(call_count "$CDX_CALLS")" -eq 1 ]
}

@test "rate-limit: retry that is throttled again -> 'rate limited on retry', within one budget" {
  RC_REVIEWER_TIMEOUT=6 RC_RATE_LIMIT_BACKOFF=0 CDX_MODE=rate-limit \
    run --separate-stderr "$SCRIPT" "$CODEX" "" "$PROMPT_FILE"
  echo "output=<<$output>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'SKIPPED: Codex unavailable'
  echo "$output" | grep -qF 'rate limited on retry'
  # It must NOT lie about the cause — "quota exhausted" tells the user to stop
  # trying; "rate limited" tells them to re-run.
  ! echo "$output" | grep -qF 'quota exhausted'
  [ "$(call_count "$CDX_CALLS")" -eq 2 ]
  # first-try + backoff + retry can never exceed ONE budget
  _el="$(printf '%s\n' "$stderr" | sed -n 's/^ELAPSED: //p' | head -1)"
  echo "elapsed=$_el"
  [ -n "$_el" ]
  [ "$_el" -le 6 ]
}

@test "rate-limit: the note is never 'quota exhausted' (attribution must not lie)" {
  RC_REVIEWER_TIMEOUT=6 RC_RATE_LIMIT_BACKOFF=0 CDX_MODE_1=rate-limit CDX_MODE_2=auth \
    run --separate-stderr "$SCRIPT" "$CODEX" "" "$PROMPT_FILE"
  [ "$status" -eq 1 ]
  # the retry's REAL class is preserved, exactly as the fast-empty retry does
  echo "$output" | grep -qF 'auth failure on retry'
  ! echo "$output" | grep -qF 'quota exhausted'
}

@test "rate-limit: a throttle body is never a valid RESULT" {
  # A rate-limit body carries no Findings/Overall Assessment headings and no
  # verdict line, so it must never satisfy the OK-guard and be returned as a
  # review.
  RC_REVIEWER_TIMEOUT=6 RC_RATE_LIMIT_BACKOFF=0 CDX_MODE=rate-limit \
    run --separate-stderr "$SCRIPT" "$CODEX" "" "$PROMPT_FILE"
  [ "$status" -eq 1 ]
  ! echo "$output" | grep -q '^TOOL:'
}

@test "rate-limit: Retry-After in the body is honoured as the backoff" {
  # RC_RATE_LIMIT_BACKOFF is deliberately NOT set here: the provider stated
  # "Retry-After: 2", so the wait must come from the body, not the default.
  RC_REVIEWER_TIMEOUT=30 CDX_MODE_1=rate-limit-retryafter CDX_MODE_2=ok \
    run --separate-stderr "$SCRIPT" "$CODEX" "" "$PROMPT_FILE"
  echo "output=<<$output>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  case "$output" in
  "TOOL: Codex"*) : ;;
  *) echo "expected TOOL: Codex after honouring Retry-After" && return 1 ;;
  esac
  # the stated 2s backoff is accounted for in the reported elapsed (it is real
  # wall-clock), and it must not have used the 20s default
  _el="$(printf '%s\n' "$stderr" | sed -n 's/^ELAPSED: //p' | head -1)"
  echo "elapsed=$_el"
  [ "$_el" -ge 2 ]
  [ "$_el" -lt 20 ]
}

@test "rate-limit: agy 'Individual quota reached' still classifies QUOTA (no regression)" {
  # deployhq#1043 regression guard, re-asserted after splitting the patterns:
  # agy's real terminal phrasing must stay HARD.
  RC_RATE_LIMIT_BACKOFF=0 AGY_MODE=quota-individual GEM_MODE=ok \
    run --separate-stderr "$SCRIPT" "$AGY" "$GEMINI" "$PROMPT_FILE"
  [ "$status" -eq 0 ]
  [ "$(call_count "$AGY_CALLS")" -eq 1 ]
}

@test "rate-limit: INT64-boundary Retry-After must not wrap past the budget guard" {
  # CodeRabbit #14: `$((9223372036854775807 + 1))` wraps to a NEGATIVE number, so
  # the `-lt $(remaining)` guard passes and the script sleeps ~forever. The value
  # is all digits, so the charset guard never sees a problem — only a LENGTH
  # bound applied BEFORE the arithmetic catches it.
  RC_REVIEWER_TIMEOUT=6 CDX_MODE=rate-limit-int64 \
    run --separate-stderr "$SCRIPT" "$CODEX" "" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'SKIPPED: Codex unavailable'
  echo "$output" | grep -qF 'rate limited'
  # It must return PROMPTLY — a wrap would have slept for ~292 billion years.
  _el="$(printf '%s\n' "$stderr" | sed -n 's/^ELAPSED: //p' | head -1)"
  echo "elapsed=$_el"
  [ -n "$_el" ]
  [ "$_el" -le 6 ]
}

@test "rate-limit: oversized Retry-After is clamped, never aborts the script" {
  # CodeRabbit #14: a value beyond INT64 makes dash exit with "Illegal number"
  # under `set -e` — the script dies mid-flight, so the orchestrator gets no
  # attributed SKIPPED line and no ELAPSED to meter the run budget with.
  RC_REVIEWER_TIMEOUT=6 CDX_MODE=rate-limit-huge \
    run --separate-stderr "$SCRIPT" "$CODEX" "" "$PROMPT_FILE"
  echo "status=$status"
  echo "output=<<$output>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'rate limited'
  # a structured result, not a shell crash
  ! printf '%s\n' "$stderr" | grep -qi 'illegal number'
  _el="$(printf '%s\n' "$stderr" | sed -n 's/^ELAPSED: //p' | head -1)"
  echo "elapsed=$_el"
  [ -n "$_el" ]
  [ "$_el" -le 6 ]
}

@test "usage-error: RC_RATE_LIMIT_BACKOFF beyond the ceiling exits 2 (no wrap)" {
  # The env knob shares the hole: it is validated digits-only, so an INT64
  # boundary value would reach the same $(( )) wrap. User config gets a LOUD
  # error (unlike a provider's Retry-After, which is clamped defensively).
  RC_RATE_LIMIT_BACKOFF=9223372036854775807 CDX_MODE=ok \
    run --separate-stderr "$SCRIPT" "$CODEX" "" "$PROMPT_FILE"
  echo "status=$status"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 2 ]
}
