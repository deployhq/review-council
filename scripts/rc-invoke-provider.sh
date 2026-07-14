#!/usr/bin/env sh
# rc-invoke-provider.sh — tested invocation state machine for the Google-family
# reviewer slot (Antigravity `agy` primary, Gemini `gemini` fallback).
#
# This extracts control-flow that used to live as prose in
# rules/orchestration.md ("Reviewer Timeouts & Fast-Fail") and
# rules/providers.md ("Google-family reviewer") — six bug-fix commits'
# worth of timeout/retry/attribution edge cases — into a single POSIX `sh`
# script. See .superpowers/sdd/task-0.1-brief.md for the full spec.
#
# Scope: Google slot ONLY (one primary CLI + one optional fallback CLI).
# Codex and Perplexity are out of scope — do not generalize this further.
#
# Usage:
#   rc-invoke-provider.sh <primary-bin> <fallback-bin> <prompt-file>
#
#   <primary-bin>   path or bare name of the primary CLI (e.g. agy). Required.
#   <fallback-bin>  path or bare name of the fallback CLI (e.g. gemini).
#                   Pass "" for "no fallback". Required as a positional.
#   <prompt-file>   file containing the delegation prompt text. Required.
#
# Env:
#   RC_REVIEWER_TIMEOUT  total wall-clock budget for the whole slot, in
#                        seconds. Default 600.
#   RC_GOOGLE_ADD_DIR    optional, agy-only: appends --add-dir "<val>".
#   RC_GOOGLE_MODEL      optional, agy-only: appends --model "<val>".
#
# stdout: on success, "TOOL: <Label>" then the raw review text.
#         on total failure, a single "SKIPPED: ..." line attributed to the
#         primary tool.
# stderr: exactly one "ELAPSED: <n>" line (whole seconds spent across every
#         invocation this script made), plus free-form diagnostic notes.
# exit:   0 success, 1 SKIPPED, 2 usage error.

set -eu

# The hard-timeout watchdog (run_capped + KILL_GRACE) lives in a shared,
# sourceable library so scripts/rc-static-scan.sh can reuse the identical
# TERM-then-KILL escalation without forking it. Sourced (not exec'd); defines
# only KILL_GRACE + run_capped, executes nothing on load.
. "$(dirname "$0")/rc-lib-timeout.sh"

# ---------------------------------------------------------------------------
# Usage / argument handling
# ---------------------------------------------------------------------------

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <primary-bin> <fallback-bin> <prompt-file>" >&2
  exit 2
fi

primary_bin="$1"
fallback_bin="$2"
prompt_file="$3"

if [ ! -f "$prompt_file" ]; then
  echo "Usage: prompt file not found: $prompt_file" >&2
  exit 2
fi

prompt="$(cat "$prompt_file")"

# ---------------------------------------------------------------------------
# Budget state
# ---------------------------------------------------------------------------

timeout_budget="${RC_REVIEWER_TIMEOUT:-600}"
# RC_REVIEWER_TIMEOUT must be a positive integer (seconds). `timeout 0` means
# "no limit" (runs forever), defeating the whole point of the cap; a
# non-integer breaks the `spent`/`T/3` arithmetic. Reject both with a usage error.
case "$timeout_budget" in
  '' | *[!0-9]*)
    echo "Usage: RC_REVIEWER_TIMEOUT must be a positive integer (seconds)" >&2
    exit 2
    ;;
esac
[ "$timeout_budget" -gt 0 ] || {
  echo "Usage: RC_REVIEWER_TIMEOUT must be > 0" >&2
  exit 2
}

# KILL_GRACE (the SIGTERM->SIGKILL escalation grace) now lives in
# rc-lib-timeout.sh alongside run_capped, sourced above.

# `spent` accumulates measured whole seconds across every invocation (primary,
# retry, fallback). It is the honest total reported as ELAPSED — on a
# timeout-then-fallback it may legitimately exceed one budget, which is correct
# and feeds the downstream run-budget check.
spent=0

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/rc-invoke.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

# Per-invocation cap model (per rules/orchestration.md + rules/providers.md):
# every CLI invocation gets its own FULL `RC_REVIEWER_TIMEOUT` cap — the primary
# first call and the gemini fallback each get a fresh full budget. The ONLY
# remaining-budget constraint is the agy fast-empty RETRY, which is time-boxed
# to `T - spent` so first-try + retry together can never exceed one budget.
#
# remaining: cap for the agy retry only. Fast-empty guarantees `spent < T/3`
# when this is called, so the result is always > 0.
remaining() {
  echo $((timeout_budget - spent))
}

# ---------------------------------------------------------------------------
# Binary resolution + labeling (by basename, per the frozen profiles)
# ---------------------------------------------------------------------------

# resolve_bin <bin>: prints the resolved path on stdout and returns 0 if the
# binary is runnable (via PATH lookup or as an executable path); returns 1
# (prints nothing) otherwise.
resolve_bin() {
  _rb_bin="$1"
  if [ -z "$_rb_bin" ]; then
    return 1
  fi
  if command -v "$_rb_bin" >/dev/null 2>&1; then
    command -v "$_rb_bin"
    return 0
  fi
  if [ -x "$_rb_bin" ]; then
    printf '%s\n' "$_rb_bin"
    return 0
  fi
  return 1
}

# label_for <bin>: "Antigravity" / "Gemini" / the bare basename.
label_for() {
  _lf_bn="$(basename "$1")"
  case "$_lf_bn" in
    *agy*) echo "Antigravity" ;;
    *gemini*) echo "Gemini" ;;
    *) echo "$_lf_bn" ;;
  esac
}

# ---------------------------------------------------------------------------
# The timeout wrapper (run_capped) + its KILL_GRACE constant are sourced from
# scripts/rc-lib-timeout.sh at the top of this file. run_capped sets LAST_RC.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Per-tool command construction (frozen, tested profiles — see brief
# "Per-tool command construction")
# ---------------------------------------------------------------------------

# build_and_run <resolved-bin> <cap-seconds> <out-file>
# Builds the argv for the resolved binary by basename, then hands off to
# run_capped. The prompt is passed as a single -p argument built via `set --`
# (never `eval`), so spaces/newlines in the prompt survive intact.
build_and_run() {
  _bar_bin="$1"
  _bar_cap="$2"
  _bar_out="$3"
  _bar_bn="$(basename "$_bar_bin")"

  case "$_bar_bn" in
    *agy*)
      # --print-timeout MUST carry the "s" unit suffix — a bare integer is
      # rejected by agy ("missing unit in duration"). This exact bug is why
      # this script exists; see the print-timeout-unit-suffix test.
      set -- "$_bar_bin" -p "$prompt" --print-timeout "${_bar_cap}s" --dangerously-skip-permissions
      if [ -n "${RC_GOOGLE_ADD_DIR:-}" ]; then
        set -- "$@" --add-dir "$RC_GOOGLE_ADD_DIR"
      fi
      if [ -n "${RC_GOOGLE_MODEL:-}" ]; then
        set -- "$@" --model "$RC_GOOGLE_MODEL"
      fi
      ;;
    *gemini*)
      set -- "$_bar_bin" -p "$prompt" --skip-trust
      ;;
    *)
      set -- "$_bar_bin" -p "$prompt"
      ;;
  esac

  run_capped "$_bar_cap" "$_bar_out" "$@"
}

# ---------------------------------------------------------------------------
# Classification (check order):
#   1. TIMEOUT   — exit code 124 (timeout), 143 (128+SIGTERM), or 137
#                  (128+SIGKILL, from the -k escalation / watchdog KILL).
#   2. OK        — a valid review (non-empty AND has BOTH a `Findings` and an
#                  `Overall Assessment` heading-shaped line). Checked BEFORE the
#                  hard patterns so a real review is never discarded just
#                  because its body legitimately mentions "login"/"429"/"503"/
#                  "oauth". Anchoring to heading lines (not bare substrings)
#                  stops an error page that merely echoes a prompt mentioning
#                  those words from false-positiving as a valid review.
#   3. AUTH -> QUOTA -> (exhausted+quota) -> OVERLOAD — hard failures.
#   4. EMPTY     — anything else (empty/whitespace or missing a review section).
# ---------------------------------------------------------------------------

# Tightened AUTH: specific phrases only — dropped the bare `login`/`oauth`
# substrings (they false-positived on real reviews discussing login/OAuth code)
# in favor of specific auth-failure phrasings.
AUTH_PATTERN='no longer supported|not authenticated|please migrate to the antigravity|secret keyring is locked|ineligibletiererror|dasher_user|not eligible for gemini code assist|invalid api key|not logged in|login required|please log in|oauth error|authentication failed|auth error'
QUOTA_PATTERN='429|exhausted your daily quota|terminalquotaerror|rate limit'
OVERLOAD_PATTERN='503|high demand'

# classify <rc> <out-file>: sets global CLASS to one of
# TIMEOUT / AUTH / QUOTA / OVERLOAD / EMPTY / OK.
classify() {
  _cl_rc="$1"
  _cl_out="$2"

  if [ "$_cl_rc" = 124 ] || [ "$_cl_rc" = 143 ] || [ "$_cl_rc" = 137 ]; then
    CLASS=TIMEOUT
    return 0
  fi

  # A valid review wins before any hard-pattern check — see block comment.
  # Anchor to heading-shaped lines (optionally `#`-prefixed markdown headings,
  # ending in `:` or end-of-line) so inline prose mentioning the words doesn't
  # count as a section.
  if [ -s "$_cl_out" ] &&
    grep -qiE '^[[:space:]]*(#+[[:space:]]*)?findings([[:space:]]*:|[[:space:]]*$)' "$_cl_out" 2>/dev/null &&
    grep -qiE '^[[:space:]]*(#+[[:space:]]*)?overall assessment([[:space:]]*:|[[:space:]]*$)' "$_cl_out" 2>/dev/null; then
    CLASS=OK
    return 0
  fi

  if grep -qiE "$AUTH_PATTERN" "$_cl_out" 2>/dev/null; then
    CLASS=AUTH
    return 0
  fi

  if grep -qiE "$QUOTA_PATTERN" "$_cl_out" 2>/dev/null; then
    CLASS=QUOTA
    return 0
  fi
  if grep -qi 'exhausted your' "$_cl_out" 2>/dev/null && grep -qi 'quota' "$_cl_out" 2>/dev/null; then
    CLASS=QUOTA
    return 0
  fi

  if grep -qiE "$OVERLOAD_PATTERN" "$_cl_out" 2>/dev/null; then
    CLASS=OVERLOAD
    return 0
  fi

  CLASS=EMPTY
}

# ---------------------------------------------------------------------------
# One invocation = resolve + capped run + elapsed measurement + classify.
# Sets globals: INVOKE_CLASS, INVOKE_ELAPSED, INVOKE_OUT, INVOKE_BIN.
# Adds the measured elapsed seconds to `spent`.
# ---------------------------------------------------------------------------

invoke_once() {
  _io_bin="$1"
  _io_cap="$2"

  _io_resolved="$(resolve_bin "$_io_bin" || true)"
  if [ -z "$_io_resolved" ]; then
    INVOKE_CLASS=ABSENT
    INVOKE_ELAPSED=0
    INVOKE_OUT=""
    INVOKE_BIN="$_io_bin"
    return 0
  fi

  _io_out="$(mktemp "$WORKDIR/attempt.XXXXXX")"

  _io_start=$(date +%s)
  build_and_run "$_io_resolved" "$_io_cap" "$_io_out"
  _io_end=$(date +%s)
  _io_el=$((_io_end - _io_start))
  spent=$((spent + _io_el))

  classify "$LAST_RC" "$_io_out"

  INVOKE_CLASS="$CLASS"
  INVOKE_ELAPSED="$_io_el"
  INVOKE_OUT="$_io_out"
  INVOKE_BIN="$_io_resolved"
}

# ---------------------------------------------------------------------------
# Terminal output helpers
# ---------------------------------------------------------------------------

succeed() {
  # $1 = resolved bin that produced the review, $2 = its output file
  _s_label="$(label_for "$1")"
  printf 'TOOL: %s\n' "$_s_label"
  cat "$2"
  echo "ELAPSED: $spent" >&2
  exit 0
}

# fail <primary-note> <fallback-note-or-empty>
fail() {
  _f_pnote="$1"
  _f_fnote="$2"

  _f_primary_bn="$(basename "$primary_bin")"
  case "$_f_primary_bn" in
    *agy*) _f_lead="Google (Antigravity)" ;;
    *gemini*) _f_lead="Google (Gemini)" ;;
    *) _f_lead="Google" ;;
  esac

  if [ -n "$_f_fnote" ]; then
    _f_fallback_bn="$(basename "$fallback_bin")"
    echo "SKIPPED: $_f_lead unavailable — $_f_primary_bn: $_f_pnote; $_f_fallback_bn fallback: $_f_fnote"
  else
    echo "SKIPPED: $_f_lead unavailable — $_f_primary_bn: $_f_pnote"
  fi
  echo "ELAPSED: $spent" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Main state machine (see brief "Primary flow")
# ---------------------------------------------------------------------------

# Primary first call gets a full fresh budget.
invoke_once "$primary_bin" "$timeout_budget"
primary_class="$INVOKE_CLASS"
primary_out="$INVOKE_OUT"
primary_resolved="$INVOKE_BIN"
primary_elapsed="$INVOKE_ELAPSED"

if [ "$primary_class" = "OK" ]; then
  succeed "$primary_resolved" "$primary_out"
fi

primary_note=""
case "$primary_class" in
  ABSENT)
    primary_note="absent"
    ;;
  AUTH)
    primary_note="auth failure"
    ;;
  QUOTA)
    primary_note="quota exhausted"
    ;;
  OVERLOAD)
    primary_note="overloaded"
    ;;
  TIMEOUT)
    primary_note="timed out"
    ;;
  EMPTY)
    # Integer division truncates to 0 for T<3, so below a 3s budget the
    # fast-empty retry never fires (any elapsed >= 0 is not < 0). This is
    # intentional and harmless: the real RC_REVIEWER_TIMEOUT is 600s; sub-3s
    # budgets only occur in tests that deliberately exercise the no-retry path.
    _fast_threshold=$((timeout_budget / 3))
    if [ "$primary_elapsed" -lt "$_fast_threshold" ]; then
      # Fast empty (agy cold-start quirk): retry ONCE, time-boxed to the
      # REMAINING budget (T - spent), never a fresh RC_REVIEWER_TIMEOUT, so
      # first-try + retry can never exceed one budget.
      invoke_once "$primary_bin" "$(remaining)"
      retry_class="$INVOKE_CLASS"
      retry_out="$INVOKE_OUT"
      retry_resolved="$INVOKE_BIN"
      if [ "$retry_class" = "OK" ]; then
        succeed "$retry_resolved" "$retry_out"
      fi
      # Preserve the retry's REAL failure class in the note — don't flatten an
      # auth/quota/overload/timeout/absent retry into "empty output after retry"
      # (that hid the true cause from the SKIPPED attribution).
      case "$retry_class" in
        AUTH) primary_note="auth failure on retry" ;;
        QUOTA) primary_note="quota exhausted on retry" ;;
        OVERLOAD) primary_note="overloaded on retry" ;;
        TIMEOUT) primary_note="timed out on retry" ;;
        ABSENT) primary_note="absent on retry" ;;
        *) primary_note="empty output after retry" ;;
      esac
    else
      # Slow empty: treat like a timeout — no retry.
      primary_note="empty output (slow)"
    fi
    ;;
esac

# Fallback (no retry for the fallback, ever). Gets a fresh full budget per
# rules/providers.md — NOT the remaining budget.
if [ -z "$fallback_bin" ]; then
  fail "$primary_note" ""
fi

invoke_once "$fallback_bin" "$timeout_budget"
fb_class="$INVOKE_CLASS"
fb_out="$INVOKE_OUT"
fb_resolved="$INVOKE_BIN"

if [ "$fb_class" = "OK" ]; then
  succeed "$fb_resolved" "$fb_out"
fi

fb_note=""
case "$fb_class" in
  ABSENT) fb_note="absent" ;;
  AUTH) fb_note="ineligible (auth/DASHER)" ;;
  QUOTA) fb_note="quota exhausted" ;;
  OVERLOAD) fb_note="overloaded" ;;
  TIMEOUT) fb_note="timed out" ;;
  EMPTY) fb_note="empty output" ;;
esac

fail "$primary_note" "$fb_note"
