#!/usr/bin/env bash
# Write the redacted job summary (called by .github/actions/review/action.yml).
set -uo pipefail

plugin_dir="$(cd "$GITHUB_ACTION_PATH/../../.." && pwd -P)"
log="$RUNNER_TEMP/rc-run.jsonl"
{
  echo "## Review Council"
  echo
  if [ ! -s "$log" ]; then
    echo "No output was captured (the run did not start, or was cancelled before writing)."
  else
    jq -r 'select(.type == "result")
      | "_\(.subtype // "result") · \((.duration_ms // 0) / 1000 | floor)s · $\(.total_cost_usd // 0)_\n"' \
      "$log" 2>/dev/null | tail -n 2 || true
    result="$(jq -r 'select(.type == "result") | .result // empty' "$log" 2>/dev/null | tail -n 1000 || true)"
    if [ -n "$result" ]; then
      # One redaction list for the whole plugin: rc-post.sh redact
      # (stdin -> stdout, count on stderr, non-zero on failure).
      if redacted="$(printf '%s\n' "$result" | "$plugin_dir/scripts/rc-post.sh" redact)"; then
        printf '%s\n' "$redacted"
      else
        echo "summary withheld: redaction failed"
      fi
    else
      echo "The run produced no final result (see the step log)."
    fi
  fi
} >> "$GITHUB_STEP_SUMMARY"
