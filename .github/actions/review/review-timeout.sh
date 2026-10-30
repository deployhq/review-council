#!/usr/bin/env bash
# Size the CI run's time limit (called by run-review.sh).
# Usage: review-timeout.sh <gate-minutes>  < resolved rc-config.sh output
# Prints the minutes to allow the whole run; warnings go to stderr.
#
# The gate sizes the limit from the run budget alone (default 45 minutes). A
# custom seat runs on its own deadline, so raise the limit to the longest
# deadline among the seats that will run (enabled, not awaiting a confirm) plus
# headroom for judging and posting — never past what the job's 120-minute cap
# leaves room for.
set -euo pipefail

HEADROOM=20     # judge, report and posting after the last seat finishes
SEAT_DEFAULT=30 # an agent seat's deadline without timeout_minutes (rc-seat.sh)
MAX=110         # the job's timeout-minutes (120) minus setup time

limit="${1:-}"
case "$limit" in ''|*[!0-9]*|0) limit=45 ;; esac

# An ocr seat without timeout_minutes takes its deadline from the run budget,
# which the gate's limit already covers.
longest="$(awk -F= -v def="$SEAT_DEFAULT" '
  /^reviewer\.custom\.[^.]+\.enabled=true$/          { split($1, k, "."); on[k[3]] = 1 }
  /^reviewer\.custom\.[^.]+\.needs_confirm=true$/    { split($1, k, "."); nc[k[3]] = 1 }
  /^reviewer\.custom\.[^.]+\.harness=/               { split($1, k, "."); h[k[3]] = $2 }
  /^reviewer\.custom\.[^.]+\.opt\.timeout_minutes=/  { split($1, k, "."); t[k[3]] = $2 + 0 }
  END {
    for (s in h) {
      if (!on[s] || nc[s]) continue
      m = (s in t) ? t[s] : (h[s] == "ocr" ? 0 : def)
      if (m > best) { best = m; slot = s }
    }
    if (best > 0) print best, slot
  }')"

if [ -n "$longest" ]; then
  minutes="${longest%% *}"
  slot="${longest#* }"
  need=$((minutes + HEADROOM))
  [ "$need" -le "$limit" ] || limit="$need"
  if [ "$limit" -gt "$MAX" ]; then
    echo "::warning::Custom seat '$slot' may run for ${minutes} minutes, longer than the job allows. The run is capped at ${MAX} minutes; lower the seat's timeout_minutes to $((MAX - HEADROOM)) or less." >&2
    limit="$MAX"
  fi
fi
printf '%s\n' "$limit"
