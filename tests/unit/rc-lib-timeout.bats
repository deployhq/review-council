#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for scripts/rc-lib-timeout.sh — the shared hard-timeout watchdog
# (run_capped + KILL_GRACE) reused by rc-invoke-provider.sh (the reviewer CLI
# slots) and rc-static-scan.sh (the static-analysis tools).
#
# Load-bearing property under test: run_capped MUST run its child with stdin
# CLOSED (</dev/null). Every agentic reviewer CLI we dispatch — codex, agy, and
# gemini — drains stdin to EOF at startup even when the prompt is passed as an
# argument (codex/gemini document it; agy does it undocumented). If run_capped
# let the child inherit an interactive/never-EOF stdin, the child would block on
# that stdin read until the cap TERM/KILLed it — the exact review-council
# latency bug where a healthy Codex reviewer hung the full RC_REVIEWER_TIMEOUT
# before failing over to the MCP transport. Both run_capped branches (the
# `timeout`-binary path and the bg+watchdog fallback) must close it.

LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/rc-lib-timeout.sh"

setup() {
  OUT="$BATS_TEST_TMPDIR/out.txt"

  # Fake CLI that drains stdin to EOF, then prints a marker — the shape of every
  # reviewer CLI. If stdin never reaches EOF, the `cat` blocks forever and
  # run_capped can only end it by killing at the cap (no marker, non-zero rc).
  # If run_capped closes the child's stdin, `cat` sees EOF at once and the
  # marker is written promptly.
  DRAINER="$BATS_TEST_TMPDIR/drainer"
  cat >"$DRAINER" <<'EOF'
#!/usr/bin/env sh
cat >/dev/null   # read all of stdin to EOF
echo DRAINED
EOF
  chmod +x "$DRAINER"
}

# start_neverending_stdin <fifo>: start a producer that holds the FIFO's write
# end open with NO data and NO EOF (until it is killed), and set PRODUCER_PID.
# This is the "inherited never-EOF stdin" that hung the real reviewers —
# run_capped is then called with the FIFO as ITS stdin, proving it closes the
# CHILD's. NB: this MUST be a function call, not a command substitution — a
# `sleep >fifo &` inside `$(...)` deadlocks (the producer blocks on the FIFO
# write-open while holding the capture pipe, and the reader never arrives).
start_neverending_stdin() {
  mkfifo "$1"
  sleep 30 >"$1" &
  PRODUCER_PID=$!
}

@test "run_capped (timeout branch) closes child stdin — a stdin-draining CLI is not hung by inherited never-EOF stdin" {
  . "$LIB"
  FIFO="$BATS_TEST_TMPDIR/fifo1"
  start_neverending_stdin "$FIFO"

  run_capped 3 "$OUT" "$DRAINER" <"$FIFO"
  rc="$LAST_RC"

  kill "$PRODUCER_PID" 2>/dev/null || true
  wait "$PRODUCER_PID" 2>/dev/null || true

  [ "$rc" -eq 0 ]
  grep -q DRAINED "$OUT"
}

@test "run_capped (fallback bg+watchdog branch) also closes child stdin" {
  . "$LIB"
  FIFO="$BATS_TEST_TMPDIR/fifo2"
  start_neverending_stdin "$FIFO"
  RCFILE="$BATS_TEST_TMPDIR/rc2"

  # Force the no-timeout-binary path: with PATH restricted to the base dirs,
  # `command -v timeout`/`gtimeout` find nothing (macOS has neither), so
  # run_capped takes its bg+watchdog fallback. sh/cat/env still resolve.
  ( PATH=/usr/bin:/bin; run_capped 3 "$OUT" "$DRAINER" <"$FIFO"; printf '%s' "$LAST_RC" >"$RCFILE" )

  kill "$PRODUCER_PID" 2>/dev/null || true
  wait "$PRODUCER_PID" 2>/dev/null || true

  [ "$(cat "$RCFILE")" -eq 0 ]
  grep -q DRAINED "$OUT"
}

@test "run_capped still enforces the cap on a child that ignores stdin (</dev/null did not weaken the timeout)" {
  . "$LIB"
  HANG="$BATS_TEST_TMPDIR/hang"
  printf '#!/usr/bin/env sh\nsleep 30\n' >"$HANG"
  chmod +x "$HANG"

  start=$(date +%s)
  run_capped 2 "$OUT" "$HANG" </dev/null
  end=$(date +%s)

  # TERM at the cap, then KILL after KILL_GRACE: 124 / 143 / 137.
  [ "$LAST_RC" -eq 124 ] || [ "$LAST_RC" -eq 143 ] || [ "$LAST_RC" -eq 137 ]
  [ "$((end - start))" -lt 10 ]
}
