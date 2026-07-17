#!/usr/bin/env sh
# rc-invoke-provider.sh — tested invocation state machine for a single reviewer
# slot: one primary CLI plus one optional fallback CLI. It drives the
# Google-family slot (Antigravity `agy` primary, Gemini `gemini` fallback) and,
# since Phase 4, the Codex slot (`codex` primary, no fallback).
#
# This extracts control-flow that used to live as prose in
# rules/orchestration.md ("Reviewer Timeouts & Fast-Fail") and
# rules/providers.md ("Google-family reviewer") — six bug-fix commits'
# worth of timeout/retry/attribution edge cases — into a single POSIX `sh`
# script. See .superpowers/sdd/task-0.1-brief.md for the full spec.
#
# Scope: any provider that is (a) one primary binary + one optional fallback
# binary and (b) classifiable by process exit code + stderr text. Google and
# Codex qualify; each command profile is basename-keyed and frozen against the
# real CLI's --help (see build_and_run). Perplexity stays OUT — it is an HTTP
# API (curl + bearer token), with no binary to resolve and an HTTP-status
# failure taxonomy, so it keeps its own inline curl path (see plan §2.5).
#
# Usage (review mode):
#   rc-invoke-provider.sh <primary-bin> <fallback-bin> <prompt-file>
#
#   <primary-bin>   path or bare name of the primary CLI (e.g. agy, codex).
#                   Required.
#   <fallback-bin>  path or bare name of the fallback CLI (e.g. gemini).
#                   Pass "" for "no fallback" (Codex has none). Required
#                   as a positional.
#   <prompt-file>   file containing the delegation prompt text. Required.
#
# Usage (probe mode):
#   rc-invoke-provider.sh --probe <primary-bin> <fallback-bin>
#
#   A lightweight health check: runs the primary (then the fallback, for a
#   Google-style slot) ONCE with a trivial 1-token prompt under a short cap
#   (RC_HEALTH_PROBE_TIMEOUT, default 20s), reusing the SAME frozen command
#   profiles + hard-fail patterns, and prints a single machine verdict on
#   stdout:
#       HEALTHY | UNHEALTHY: <reason> | INCONCLUSIVE
#   Fail-OPEN: only POSITIVE hard-fail evidence (auth / quota / overload /
#   ineligible) yields UNHEALTHY; a TIMEOUT (agy cold start!), empty output, or
#   network blip yields INCONCLUSIVE so a cold-but-usable provider is never
#   dropped. Slot is HEALTHY iff the primary OR the fallback is healthy. Pass
#   "" as <fallback-bin> for a no-fallback slot (Codex). Exit is always 0
#   (verdict is on stdout), or 2 on a usage error.
#
# Env:
#   RC_REVIEWER_TIMEOUT      review mode: total wall-clock budget for the whole
#                            slot, in seconds. Default 600.
#   RC_HEALTH_PROBE_TIMEOUT  probe mode: short per-tool cap, in seconds.
#                            Default 20.
#   RC_RATE_LIMIT_BACKOFF    seconds to wait before the single RATE_LIMIT retry.
#                            Default 20. A provider-stated `Retry-After` in the
#                            response body wins over it. The backoff is charged
#                            to the reported ELAPSED, and the retry is time-boxed
#                            to the remaining budget, so first-try + backoff +
#                            retry never exceed one RC_REVIEWER_TIMEOUT.
#   RC_GOOGLE_ADD_DIR        optional, agy-only: appends --add-dir "<val>".
#   RC_GOOGLE_MODEL          optional, agy-only: appends --model "<val>".
#
# stdout: review mode — on success, "TOOL: <Label>" then the raw review text;
#         on total failure, a single "SKIPPED: ..." line attributed to the
#         primary tool. probe mode — a single verdict line (see above).
# stderr: review mode — exactly one "ELAPSED: <n>" line (whole seconds spent
#         across every invocation this script made), plus free-form notes.
# exit:   0 success (or probe verdict printed), 1 SKIPPED, 2 usage error.

set -eu

# The hard-timeout watchdog (run_capped + KILL_GRACE) lives in a shared,
# sourceable library so scripts/rc-static-scan.sh can reuse the identical
# TERM-then-KILL escalation without forking it. Sourced (not exec'd); defines
# only KILL_GRACE + run_capped, executes nothing on load.
. "$(dirname "$0")/rc-lib-timeout.sh"

# ---------------------------------------------------------------------------
# Usage / argument handling  (review mode vs. --probe mode)
# ---------------------------------------------------------------------------

# MODE is "review" (3 positionals + prompt file) or "probe" (--probe + 2
# positionals, trivial internal prompt). --probe is a literal first-arg token
# (dash-safe: a real binary is never named "--probe").
MODE=review
if [ "${1:-}" = "--probe" ]; then
  MODE=probe
  shift
fi

if [ "$MODE" = probe ]; then
  if [ "$#" -ne 2 ]; then
    echo "Usage: $0 --probe <primary-bin> <fallback-bin>" >&2
    exit 2
  fi
  primary_bin="$1"
  fallback_bin="$2"
  # Trivial 1-token health-check prompt (never a real review request).
  prompt="ping"
  # Probe mode uses its own short cap, independent of the review budget.
  timeout_budget="${RC_HEALTH_PROBE_TIMEOUT:-20}"
else
  if [ "$#" -ne 3 ]; then
    echo "Usage: $0 [--probe] <primary-bin> <fallback-bin> <prompt-file>" >&2
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
  timeout_budget="${RC_REVIEWER_TIMEOUT:-600}"
fi

# ---------------------------------------------------------------------------
# Budget state
# ---------------------------------------------------------------------------

# The cap (RC_REVIEWER_TIMEOUT / RC_HEALTH_PROBE_TIMEOUT) must be a positive
# integer (seconds). `timeout 0` means "no limit" (runs forever), defeating the
# whole point of the cap; a non-integer breaks the `spent`/`T/3` arithmetic.
# Reject both with a usage error.
case "$timeout_budget" in
  '' | *[!0-9]*)
    echo "Usage: reviewer/probe timeout must be a positive integer (seconds)" >&2
    exit 2
    ;;
esac
[ "$timeout_budget" -gt 0 ] || {
  echo "Usage: reviewer/probe timeout must be > 0" >&2
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

# label_for <bin>: "Antigravity" / "Gemini" / "Codex" / the bare basename.
label_for() {
  _lf_bn="$(basename "$1")"
  case "$_lf_bn" in
    *agy*) echo "Antigravity" ;;
    *gemini*) echo "Gemini" ;;
    *codex*) echo "Codex" ;;
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
    *codex*)
      # Frozen non-interactive Codex profile, pinned against `codex exec --help`
      # (Phase 4). Three details are load-bearing:
      #   1. `exec` is the non-interactive subcommand (interactive `codex` would
      #      hang forever with no TTY). `exec` has no --ask-for-approval flag —
      #      it never prompts — so no "bypass approvals" knob is needed.
      #   2. The prompt is a POSITIONAL arg — for `codex exec`, `-p` is
      #      `--profile`, NOT the prompt (unlike agy/gemini). It goes last.
      #   3. `--sandbox read-only` is LEAST PRIVILEGE for a reviewer: the model's
      #      shell commands can read the repo but cannot write or reach the
      #      network. A code reviewer only reads, so this is sufficient — and we
      #      deliberately do NOT use `--dangerously-bypass-approvals-and-sandbox`
      #      (which codex's own help calls "EXTREMELY DANGEROUS": no sandbox at
      #      all), consistent with the plugin's least-privilege posture (e.g.
      #      Phase 3 dropped the run skill's Write grant). read-only sandbox ops
      #      are allowed outright in `exec`, so the run stays hands-off.
      # `--skip-git-repo-check` is defensive (lets the review run even outside a
      # git repo). If Codex's CLI surface changes, re-pin from `codex exec
      # --help` and update the codex-profile-argv test in lockstep.
      #   4. `codex exec` DRAINS stdin even with a positional prompt ("If stdin
      #      is piped and a prompt is also provided, stdin is appended as a
      #      <stdin> block"), so it hangs forever on an inherited never-EOF
      #      stdin. run_capped (rc-lib-timeout.sh) closes the child's stdin
      #      (</dev/null) for exactly this reason; agy/gemini share the trait.
      #      See tests/unit/rc-lib-timeout.bats.
      set -- "$_bar_bin" exec --sandbox read-only --skip-git-repo-check "$prompt"
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
#   3. AUTH -> QUOTA -> (exhausted+quota) -> RATE_LIMIT -> OVERLOAD.
#                  QUOTA (terminal) MUST precede RATE_LIMIT (transient): a
#                  provider returns HTTP 429 for both a per-minute throttle and
#                  a real insufficient_quota, so a 429 carrying a terminal
#                  phrase stays hard while a bare 429 is soft and retryable.
#   4. EMPTY     — anything else (empty/whitespace or missing a review section).
# ---------------------------------------------------------------------------

# Tightened AUTH: specific phrases only — dropped the bare `login`/`oauth`
# substrings (they false-positived on real reviews discussing login/OAuth code)
# in favor of specific auth-failure phrasings.
AUTH_PATTERN='no longer supported|not authenticated|please migrate to the antigravity|secret keyring is locked|ineligibletiererror|dasher_user|not eligible for gemini code assist|invalid api key|not logged in|login required|please log in|oauth error|authentication failed|auth error'
# QUOTA is TERMINAL: the provider will not serve us again until a reset or an
# upgrade, so the slot is dead for this run — no retry, and skills/run/SKILL.md
# Step 3 treats it as a HARD reason (not even the MCP fallback is tried).
#
# `individual quota reached` / `upgrade your subscription` are agy's real quota
# phrasing (Antigravity), distinct from the generic TerminalQuotaError — without
# them a quota-dead agy classifies EMPTY, wastes a fast-empty retry, and reports
# a misleading "empty output after retry" (seen live on deployhq#1043).
QUOTA_PATTERN='exhausted your daily quota|terminalquotaerror|individual quota reached|upgrade your subscription|insufficient_quota|exceeded your current quota'
# RATE_LIMIT is TRANSIENT: a tokens-per-minute throttle that clears in seconds.
# It used to live in QUOTA_PATTERN, which meant a 60-second blip permanently
# removed a reviewer from the run and told the user their paid quota was gone.
# Observed live: Codex reviewed fine in Round 1, reported "quota exhausted" for
# the Step-4 refutation ~2 minutes later, then answered a direct probe 6s after
# that. The council's own Round-1 -> refutation burst is what trips the limit,
# so it recurs on any large diff.
#
# PRECEDENCE IS LOAD-BEARING: classify() checks QUOTA *before* RATE_LIMIT
# because OpenAI returns HTTP 429 for BOTH a per-minute throttle AND a real
# `insufficient_quota`. A bare 429 with no terminal phrase is soft; a 429
# carrying one is hard.
RATE_LIMIT_PATTERN='429|rate limit|rate_limit_exceeded|too many requests|retry.after'
OVERLOAD_PATTERN='503|high demand'

# Backoff before the single RATE_LIMIT retry, in seconds. A provider-stated
# `Retry-After` in the body wins over this default (see retry_after_of). Exposed
# as an env knob — unlike KILL_GRACE — because the bats suite must exercise the
# retry path without a real 20s sleep, and because a user hitting an unusually
# aggressive throttle may want to lengthen it.
RATE_LIMIT_BACKOFF="${RC_RATE_LIMIT_BACKOFF:-20}"
case "$RATE_LIMIT_BACKOFF" in
  '' | *[!0-9]*)
    echo "Usage: RC_RATE_LIMIT_BACKOFF must be a non-negative integer (seconds)" >&2
    exit 2
    ;;
esac

# retry_after_of <out-file>: prints the provider's stated Retry-After value in
# whole seconds, or nothing when it didn't state one. Lowercases via `tr` rather
# than using a case-insensitive sed flag (`I` is GNU-only; BSD/macOS sed lacks
# it), keeping this portable.
retry_after_of() {
  tr '[:upper:]' '[:lower:]' <"$1" 2>/dev/null |
    sed -n 's/.*retry[ _-]*after[":= ][^0-9]*\([0-9][0-9]*\).*/\1/p' |
    head -1
}

# A Step-4 REFUTATION verdict line has the shape (rules/delegation-format.md's
# Refutation Template, "Return one line per finding"):
#   <finding-id> | UPHELD — <one-sentence evidence, with the cited location>
# i.e. the line STARTS with an ID-shaped token (alnum plus "._-:", no internal
# spaces), then optional space, a literal "|", optional space, and EXACTLY ONE
# verdict word. Recognized as a valid RESULT alongside the review format (see
# classify) so a verdict set is never dropped through the hard-fail patterns —
# a verdict output carries none of the review headings the OK-guard keyed on.
#
# CR-1 fix: anchored to that id|verdict shape at line start, NOT to a bare
# "|<verdict-word>" substring anywhere on the line. The old loose pattern also
# matched the refutation prompt's own rubric enumeration when a model echoed
# it back verbatim (merged into the out-file via run_capped's 2>&1), e.g.
# "Allowed: UPHELD | REFUTED | INCONCLUSIVE" — there the word "UPHELD" (not an
# id-token-then-pipe) precedes the FIRST "|", so the id-shaped-token character
# class (no spaces allowed) can never reach that pipe, and the anchored match
# fails. That loose match could hide a genuine auth/quota/overload failure
# reported on the same merged-stream line — the exact CR-1 misclassification
# bug this anchor guards against.
VERDICT_PATTERN='^[[:space:]]*[[:alnum:]._:-]+[[:space:]]*\|[[:space:]]*(upheld|refuted|inconclusive)([[:space:]]|$|\|)'

# classify <rc> <out-file>: sets global CLASS to one of
# TIMEOUT / AUTH / QUOTA / OVERLOAD / EMPTY / OK.
classify() {
  _cl_rc="$1"
  _cl_out="$2"

  if [ "$_cl_rc" = 124 ] || [ "$_cl_rc" = 143 ] || [ "$_cl_rc" = 137 ]; then
    CLASS=TIMEOUT
    return 0
  fi

  # A valid RESULT wins before any hard-pattern check — see block comment. Two
  # shapes count: (1) a Round-1 REVIEW (Findings + Overall Assessment heading-
  # shaped lines); (2) a Step-4 REFUTATION verdict set (VERDICT_PATTERN lines).
  # Anchor to line shape (headings / pipe-delimited verdicts), not bare
  # substrings, so inline prose — or repo source the model echoes in its
  # reasoning, merged here via run_capped's 2>&1 (e.g. a "please log in" flash) —
  # doesn't count. Without shape (2), verdict output has no review headings,
  # falls through to the hard-fail patterns, and false-matches on that echoed
  # source: the exact refutation-classification bug this guards against.
  if [ -s "$_cl_out" ] &&
    { { grep -qiE '^[[:space:]]*(#+[[:space:]]*)?findings([[:space:]]*:|[[:space:]]*$)' "$_cl_out" 2>/dev/null &&
        grep -qiE '^[[:space:]]*(#+[[:space:]]*)?overall assessment([[:space:]]*:|[[:space:]]*$)' "$_cl_out" 2>/dev/null; } ||
      grep -qiE "$VERDICT_PATTERN" "$_cl_out" 2>/dev/null; }; then
    CLASS=OK
    return 0
  fi

  if grep -qiE "$AUTH_PATTERN" "$_cl_out" 2>/dev/null; then
    CLASS=AUTH
    return 0
  fi

  # QUOTA (terminal) is checked BEFORE RATE_LIMIT (transient), and the order is
  # load-bearing: OpenAI returns HTTP 429 for both a per-minute throttle and a
  # real `insufficient_quota`, so a 429 that also carries a terminal phrase must
  # stay hard. A bare 429 falls through to RATE_LIMIT below.
  if grep -qiE "$QUOTA_PATTERN" "$_cl_out" 2>/dev/null; then
    CLASS=QUOTA
    return 0
  fi
  if grep -qi 'exhausted your' "$_cl_out" 2>/dev/null && grep -qi 'quota' "$_cl_out" 2>/dev/null; then
    CLASS=QUOTA
    return 0
  fi

  if grep -qiE "$RATE_LIMIT_PATTERN" "$_cl_out" 2>/dev/null; then
    CLASS=RATE_LIMIT
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

  # Lead attribution is basename-keyed so a no-fallback Codex SKIPPED leads with
  # "Codex", not "Google". The Google leads are locked by the existing bats
  # suite — do not change them.
  _f_primary_bn="$(basename "$primary_bin")"
  case "$_f_primary_bn" in
    *agy*) _f_lead="Google (Antigravity)" ;;
    *gemini*) _f_lead="Google (Gemini)" ;;
    *codex*) _f_lead="Codex" ;;
    *) _f_lead="$_f_primary_bn" ;;
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
# Probe mode (--probe): a single short-cap trivial run per tool -> machine
# verdict. Reuses the frozen command profiles (build_and_run) and the hard-fail
# patterns (AUTH/QUOTA/OVERLOAD) — no re-implementation. Distinct from the
# review classifier in ONE way: a probe treats ANY clean exit-0 non-empty
# response as "alive" (it does NOT require the review's Findings/Overall
# Assessment sections, since the trivial prompt never asks for a review).
# ---------------------------------------------------------------------------

# probe_bin <bin>: sets globals PROBE_VERDICT (HEALTHY|UNHEALTHY|INCONCLUSIVE)
# and PROBE_REASON. Fail-open: only positive hard-fail evidence -> UNHEALTHY.
probe_bin() {
  _pb_bin="$1"
  PROBE_REASON=""

  _pb_resolved="$(resolve_bin "$_pb_bin" || true)"
  if [ -z "$_pb_resolved" ]; then
    # Not resolvable. Detection (Step 0.2) already gates on installed, so this
    # is a defensive fail-open — never a health failure on its own.
    PROBE_VERDICT=INCONCLUSIVE
    PROBE_REASON="not resolvable"
    return 0
  fi

  _pb_out="$(mktemp "$WORKDIR/probe.XXXXXX")"
  build_and_run "$_pb_resolved" "$timeout_budget" "$_pb_out"

  # 1. Hard timeout / kill (cold start, network blip) -> fail-open. A cold-but-
  #    usable agy MUST land here, never UNHEALTHY.
  if [ "$LAST_RC" = 124 ] || [ "$LAST_RC" = 143 ] || [ "$LAST_RC" = 137 ]; then
    PROBE_VERDICT=INCONCLUSIVE
    PROBE_REASON="timed out"
    return 0
  fi

  # 2. Positive hard-fail evidence -> UNHEALTHY (drop). Same patterns as the
  #    review classifier, same precedence (auth -> quota -> overload).
  if grep -qiE "$AUTH_PATTERN" "$_pb_out" 2>/dev/null; then
    PROBE_VERDICT=UNHEALTHY
    PROBE_REASON="auth failure"
    return 0
  fi
  if grep -qiE "$QUOTA_PATTERN" "$_pb_out" 2>/dev/null ||
    { grep -qi 'exhausted your' "$_pb_out" 2>/dev/null && grep -qi 'quota' "$_pb_out" 2>/dev/null; }; then
    PROBE_VERDICT=UNHEALTHY
    PROBE_REASON="quota exhausted"
    return 0
  fi
  # A transient throttle is NOT positive evidence of a dead provider. The probe
  # is fail-OPEN by design — only positive hard-fail evidence drops a slot — and
  # dropping a reviewer for a 60-second blip is the exact bug the QUOTA /
  # RATE_LIMIT split fixes. Same QUOTA-before-RATE_LIMIT precedence as classify().
  if grep -qiE "$RATE_LIMIT_PATTERN" "$_pb_out" 2>/dev/null; then
    PROBE_VERDICT=INCONCLUSIVE
    PROBE_REASON="rate limited"
    return 0
  fi
  if grep -qiE "$OVERLOAD_PATTERN" "$_pb_out" 2>/dev/null; then
    PROBE_VERDICT=UNHEALTHY
    PROBE_REASON="overloaded"
    return 0
  fi

  # 3. Clean exit with some output -> alive.
  if [ "$LAST_RC" = 0 ] && [ -s "$_pb_out" ]; then
    PROBE_VERDICT=HEALTHY
    return 0
  fi

  # 4. Empty output or a generic non-zero exit with no positive evidence ->
  #    fail-open (keep). The probe only catches DEAD providers, not cold ones.
  PROBE_VERDICT=INCONCLUSIVE
  PROBE_REASON="empty or unclassified response"
}

# run_probe: primary (then fallback, for a Google-style slot) -> one verdict.
# Slot HEALTHY iff either tool is healthy; UNHEALTHY only when every probed tool
# gives positive hard-fail evidence; otherwise INCONCLUSIVE (fail-open). Exits.
run_probe() {
  probe_bin "$primary_bin"
  _rp_pv="$PROBE_VERDICT"
  _rp_pr="$PROBE_REASON"

  if [ "$_rp_pv" = HEALTHY ]; then
    echo "HEALTHY"
    exit 0
  fi

  if [ -n "$fallback_bin" ]; then
    probe_bin "$fallback_bin"
    _rp_fv="$PROBE_VERDICT"
    _rp_fr="$PROBE_REASON"
    if [ "$_rp_fv" = HEALTHY ]; then
      echo "HEALTHY"
      exit 0
    fi
    # Neither tool healthy. Drop (UNHEALTHY) only with positive evidence from
    # BOTH; if either is merely INCONCLUSIVE (cold/slow), keep the slot.
    if [ "$_rp_pv" = UNHEALTHY ] && [ "$_rp_fv" = UNHEALTHY ]; then
      echo "UNHEALTHY: primary $_rp_pr; fallback $_rp_fr"
    else
      echo "INCONCLUSIVE"
    fi
    exit 0
  fi

  # No fallback (e.g. Codex): the single tool's verdict is the slot's.
  if [ "$_rp_pv" = UNHEALTHY ]; then
    echo "UNHEALTHY: $_rp_pr"
  else
    echo "INCONCLUSIVE"
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# Main state machine (see brief "Primary flow")
# ---------------------------------------------------------------------------

# Probe mode short-circuits the review state machine entirely (run_probe exits).
if [ "$MODE" = probe ]; then
  run_probe
fi

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
  RATE_LIMIT)
    # A TRANSIENT throttle, not a terminal quota. Retry ONCE after a backoff,
    # time-boxed to the REMAINING budget (T - spent) and never a fresh
    # RC_REVIEWER_TIMEOUT — so first-try + backoff + retry can never exceed one
    # budget, exactly like the fast-empty retry below.
    #
    # The note text matters as much as the retry: "quota exhausted" tells a user
    # their paid quota is gone and to stop trying; "rate limited" tells them to
    # re-run. The old shared bucket said the former for a 60-second blip.
    primary_note="rate limited"
    _rl_wait="$(retry_after_of "$primary_out")"
    case "$_rl_wait" in
      '' | *[!0-9]*) _rl_wait="$RATE_LIMIT_BACKOFF" ;;
    esac
    # Retry only if the backoff AND a non-trivial attempt both still fit in what
    # is left of the budget. This also bounds a hostile/garbage `Retry-After:
    # 99999` — it simply never fits, so we report honestly instead of sleeping.
    if [ "$((_rl_wait + 1))" -lt "$(remaining)" ]; then
      if [ "$_rl_wait" -gt 0 ]; then
        sleep "$_rl_wait"
      fi
      # The backoff is real wall-clock. Charge it to `spent` so remaining() and
      # the ELAPSED line the orchestrator meters its run budget with stay honest.
      spent=$((spent + _rl_wait))
      invoke_once "$primary_bin" "$(remaining)"
      retry_class="$INVOKE_CLASS"
      retry_out="$INVOKE_OUT"
      retry_resolved="$INVOKE_BIN"
      if [ "$retry_class" = "OK" ]; then
        succeed "$retry_resolved" "$retry_out"
      fi
      # Preserve the retry's REAL class, same as the fast-empty retry does.
      case "$retry_class" in
        AUTH) primary_note="auth failure on retry" ;;
        QUOTA) primary_note="quota exhausted on retry" ;;
        RATE_LIMIT) primary_note="rate limited on retry" ;;
        OVERLOAD) primary_note="overloaded on retry" ;;
        TIMEOUT) primary_note="timed out on retry" ;;
        ABSENT) primary_note="absent on retry" ;;
        *) primary_note="empty output after retry" ;;
      esac
    fi
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
  # The fallback is never retried (rules/providers.md), so a throttled fallback
  # is reported as-is — but still labelled honestly, never "quota exhausted".
  RATE_LIMIT) fb_note="rate limited" ;;
  OVERLOAD) fb_note="overloaded" ;;
  TIMEOUT) fb_note="timed out" ;;
  EMPTY) fb_note="empty output" ;;
esac

fail "$primary_note" "$fb_note"
