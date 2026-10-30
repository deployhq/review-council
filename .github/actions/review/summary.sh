#!/usr/bin/env bash
# Write the redacted job summary (called by .github/actions/review/action.yml,
# also after a timeout or a cancel). The step log gets the run's tool trace
# (which tools ran, never their output) and, on failure, Claude's error.
set -uo pipefail

plugin_dir="$(cd "$GITHUB_ACTION_PATH/../../.." && pwd -P)"
log="$RUNNER_TEMP/rc-run.jsonl"
# One redaction list for the whole plugin: rc-post.sh redact
# (stdin -> stdout, count on stderr, non-zero on failure).
redact() { "$plugin_dir/scripts/rc-post.sh" redact; }

if [ -s "$log" ]; then
  echo "::group::Tool trace (last 40 calls)"
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")
    | "\(.name): \((.input.description // .input.file_path // .input.skill // .input.pattern // "") | tostring | gsub("\n"; " ") | .[0:120])"' \
    "$log" 2>/dev/null | tail -n 40 | redact 2>/dev/null || echo "(trace unavailable)"
  echo "::endgroup::"
  err="$(jq -r 'select(.type == "result" and .is_error == true) | .result // .subtype // "error"' "$log" 2>/dev/null | tail -n 1 | redact 2>/dev/null)" || err=""
  [ -z "$err" ] || echo "::error::Review Council: $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-500)"
fi

{
  echo "## Review Council"
  echo
  if [ ! -s "$log" ]; then
    echo "No output was captured (the run did not start, or was cancelled before writing)."
  else
    jq -r 'select(.type == "result")
      | "_\(if .is_error == true then "failed" else (.subtype // "result") end) · \((.duration_ms // 0) / 1000 | floor)s · $\(.total_cost_usd // 0)_\n"' \
      "$log" 2>/dev/null | tail -n 2 || true
    result="$(jq -r 'select(.type == "result") | .result // empty' "$log" 2>/dev/null | tail -n 1000 || true)"
    if [ -n "$result" ]; then
      if redacted="$(printf '%s\n' "$result" | redact)"; then
        printf '%s\n' "$redacted"
      else
        echo "summary withheld: redaction failed"
      fi
    else
      echo "The run produced no final result (timed out or cancelled?). The step log has the tool trace."
    fi
  fi
} >> "$GITHUB_STEP_SUMMARY"
