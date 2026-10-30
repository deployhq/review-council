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

HEADROOM=20 # judge, report and posting after the last seat finishes
MAX=110     # the job's timeout-minutes (120) minus setup time

limit="${1:-}"
case "$limit" in ''|*[!0-9]*|0) limit=45 ;; esac

# Each seat's deadline, the way its runner computes it:
#   rc-seat.sh (codex, claude, opencode): timeout_minutes, else 30 for a local
#     (ollama) seat, else settings.reviewer_timeout_seconds (default 600).
#   rc-ocr.sh: timeout_minutes, else 30 for a local seat, else two thirds of
#     the run budget; times the effort rounds (low 1, medium 2, high 3), plus
#     90 seconds.
longest="$(awk -F= '
  function ceil_min(s) { return int((s + 59) / 60) }
  /^settings\.reviewer_timeout_seconds=/            { rt = $2 + 0 }
  /^settings\.run_budget_seconds=/                  { rb = $2 + 0 }
  /^reviewer\.custom\.[^.]+\.enabled=true$/          { split($1, k, "."); on[k[3]] = 1 }
  /^reviewer\.custom\.[^.]+\.needs_confirm=true$/    { split($1, k, "."); nc[k[3]] = 1 }
  /^reviewer\.custom\.[^.]+\.harness=/               { split($1, k, "."); h[k[3]] = $2 }
  /^reviewer\.custom\.[^.]+\.provider=/              { split($1, k, "."); p[k[3]] = $2 }
  /^reviewer\.custom\.[^.]+\.opt\.timeout_minutes=/  { split($1, k, "."); t[k[3]] = $2 + 0 }
  /^reviewer\.custom\.[^.]+\.opt\.effort=/           { split($1, k, "."); e[k[3]] = $2 }
  END {
    if (rt <= 0) rt = 600
    if (rb <= 0) rb = 900
    for (s in h) {
      if (!on[s] || nc[s]) continue
      if (s in t) m = t[s]
      else if (p[s] == "ollama") m = 30
      else if (h[s] == "ocr") m = int((rb - int(rb / 3)) / 60)
      else m = ceil_min(rt)
      if (h[s] == "ocr") {
        if (m > 180) m = 180
        r = (e[s] == "high") ? 3 : ((e[s] == "medium") ? 2 : 1)
        m = m * r + 2
      }
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
    echo "::warning::Custom seat '$slot' may run for ${minutes} minutes, longer than the job allows. The run is capped at ${MAX} minutes; lower its timeout_minutes (or, for ocr, its effort)." >&2
    limit="$MAX"
  fi
fi
printf '%s\n' "$limit"
