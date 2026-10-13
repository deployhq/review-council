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
# fails, so it's safe to call under `set -e`. Descendants are signalled too:
# GNU timeout signals its own process group; the fallback below starts the
# child as a process-group leader (perl setpgrp) and signals that group, so a
# subprocess an agentic CLI spawned can't outlive the cap. (Without perl the
# fallback degrades to signalling the child pid only.)
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
    #
    # Process group: perl's setpgrp makes the child a group leader (exec keeps
    # the pid, so pgid == $pid) and the watchdog signals `-$pid`, the whole
    # group. `exec { $ARGV[0] } @ARGV` never goes through a shell, even for a
    # one-word argv. POSIX `kill -s SIG -- -PGID` works in bash, dash and
    # macOS /bin/sh alike (dash rejects `kill -SIG -- -PGID`).
    if command -v perl >/dev/null 2>&1; then
      perl -e 'setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127' -- "$@" \
        >"$_rc_out" 2>&1 </dev/null &
      pid=$!
      _rc_tgt="-$pid"
    else
      "$@" >"$_rc_out" 2>&1 </dev/null &
      pid=$!
      _rc_tgt="$pid"
    fi
    # Once the watchdog fires it ignores TERM, so the cancel below can't cut
    # the TERM -> grace -> KILL escalation short: a leader that dies on TERM
    # would otherwise leave a TERM-ignoring descendant alive. Each step falls
    # back to the bare pid (a group not yet formed), and stops once neither
    # the group nor the pid exists.
    (
      sleep "$_rc_cap"
      trap '' TERM
      kill -s TERM -- "$_rc_tgt" 2>/dev/null ||
        kill -s TERM -- "$pid" 2>/dev/null || exit 0
      sleep "$KILL_GRACE"
      kill -s KILL -- "$_rc_tgt" 2>/dev/null ||
        kill -s KILL -- "$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid" 2>/dev/null || LAST_RC=$?
    # Cancel an unfired watchdog; a fired one ignores this and `wait` returns
    # after its KILL step (bounded by KILL_GRACE).
    kill "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
  fi
}
