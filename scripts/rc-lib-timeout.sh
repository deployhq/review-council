# shellcheck shell=sh
# rc-lib-timeout.sh — shared hard-timeout watchdog (sourceable library).
#
# Extracted VERBATIM from scripts/rc-invoke-provider.sh (the Google-slot
# invocation state machine) so a second caller — scripts/rc-static-scan.sh, the
# Phase-2 deterministic static-analysis runner — can reuse the exact same
# TERM-then-KILL escalation without forking it. Six bug-fix commits' worth of
# timeout edge cases went into getting this right once; do not duplicate it.
#
# Contract: this file only DEFINES a constant (KILL_GRACE) and a function
# (run_capped). It executes nothing on source — no shebang, no top-level side
# effects — so it is safe to `.` under `set -eu`. Zero Google-slot-specific
# (agy/gemini) logic lives here.
#
# Sole export used by callers: run_capped sets the global LAST_RC.

# Grace period between SIGTERM and the SIGKILL escalation that makes the cap
# HARD: a provider that traps/ignores TERM (or is wedged) must still be stopped
# so `wait` can't block forever. Plain constant — deliberately not an env knob.
KILL_GRACE=3

# run_capped <cap-seconds> <out-file> <cmd...>
# Runs <cmd...> with combined stdout+stderr captured to <out-file>, capped at
# <cap-seconds>. The cap is HARD: TERM at the cap, then KILL after KILL_GRACE,
# so a TERM-ignoring/wedged child can't outlive the budget. Sets global LAST_RC
# to the command's exit status (124/143/137 on a timeout kill). Never itself
# fails, so it's safe to call under `set -e`. Kills the child pid only — no
# process-group/setsid escalation (out of scope for leaf CLIs like agy/gemini).
#
# stdin is CLOSED (</dev/null) for the child. run_capped only ever wraps
# non-interactive tools (the agy/gemini/codex reviewer CLIs and the static
# scanners), and the agentic reviewer CLIs DRAIN stdin to EOF at startup even
# when their prompt is passed as an argument (codex & gemini document it; agy
# does it silently). Without this, the child inherits run_capped's stdin and, if
# that stdin never reaches EOF (the usual case in a Claude Code Bash-tool run),
# blocks on the stdin read until the cap TERM/KILLs it — the review-council
# latency bug where a healthy Codex reviewer hung the full RC_REVIEWER_TIMEOUT
# before failing over. See tests/unit/rc-lib-timeout.bats.
run_capped() {
  _rc_cap="$1"
  _rc_out="$2"
  shift 2
  LAST_RC=0
  TO="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  if [ -n "$TO" ]; then
    # -k escalates to SIGKILL if the process is still alive KILL_GRACE seconds
    # after the initial SIGTERM at the cap. </dev/null: the child runs in the
    # FOREGROUND here, so it would otherwise inherit run_capped's stdin (see the
    # header note) — close it so a stdin-draining CLI can't hang on it.
    "$TO" -k "$KILL_GRACE" "$_rc_cap" "$@" >"$_rc_out" 2>&1 </dev/null || LAST_RC=$?
  else
    # no timeout binary — background + watchdog so the call is never unbounded.
    # Watchdog: TERM at the cap, wait the grace, then KILL — matching -k above.
    # </dev/null is explicit here too (a POSIX async `&` already redirects stdin
    # from /dev/null, but state it rather than lean on that subtlety).
    "$@" >"$_rc_out" 2>&1 </dev/null &
    pid=$!
    (
      sleep "$_rc_cap"
      kill -TERM "$pid" 2>/dev/null
      sleep "$KILL_GRACE"
      kill -KILL "$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid" 2>/dev/null || LAST_RC=$?
    kill "$wd" 2>/dev/null || true
  fi
}
