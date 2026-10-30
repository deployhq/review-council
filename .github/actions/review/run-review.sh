#!/usr/bin/env bash
# Run `/review-council:run` unattended (called by .github/actions/review/action.yml,
# from the reviewed repo's checkout).
# Inputs (env): RC_AUTH_MODE (api_key|federation), RC_TIMEOUT_MINUTES, PR_NUMBER,
#   the RC_* run settings, GH_TOKEN, the provider keys, RC_PR_BOT_TOKEN(_ENV),
#   and in federation mode the ANTHROPIC_* federation IDs plus the runner's
#   ACTIONS_ID_TOKEN_REQUEST_URL / ACTIONS_ID_TOKEN_REQUEST_TOKEN.
set -uo pipefail

plugin_dir="$(cd "$GITHUB_ACTION_PATH/../../.." && pwd -P)"

# Unset empty optional values so they read as "not set", not "set to ''"
# (an empty credential variable can still win its precedence slot).
for v in ANTHROPIC_API_KEY CODEX_API_KEY OPENROUTER_API_KEY PERPLEXITY_API_KEY \
         ANTHROPIC_FEDERATION_RULE_ID ANTHROPIC_ORGANIZATION_ID \
         ANTHROPIC_SERVICE_ACCOUNT_ID ANTHROPIC_WORKSPACE_ID; do
  [ -n "${!v:-}" ] || unset "$v"
done
[ -n "${RC_PR_BOT_TOKEN:-}" ] || unset RC_PR_BOT_TOKEN RC_PR_BOT_TOKEN_ENV

# Keep the OIDC request credentials out of Claude's environment; only the
# refresh loop below (federation mode) holds a copy. In API-key mode the
# caller should not grant id-token: write, so this is normally a no-op.
oidc_url="${ACTIONS_ID_TOKEN_REQUEST_URL:-}"
oidc_tok="${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}"
unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN

# Check the Claude auth setup. This is the one place it is validated. The
# workflow picks the mode: federation when anthropic_federation_rule_id is
# set, else api_key. The action also runs this script with --check-auth as its
# first step, so a bad setup fails before the installs.
if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ -n "${ANTHROPIC_FEDERATION_RULE_ID:-}${ANTHROPIC_ORGANIZATION_ID:-}${ANTHROPIC_SERVICE_ACCOUNT_ID:-}${ANTHROPIC_WORKSPACE_ID:-}" ]; then
  echo "::error::Both the ANTHROPIC_API_KEY secret and anthropic_* federation inputs are set. Use one: drop the secret for federation, or the anthropic_* inputs for an API key."
  exit 1
fi
case "${RC_AUTH_MODE:-}" in
  api_key)
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
      if [ -n "${ANTHROPIC_ORGANIZATION_ID:-}${ANTHROPIC_SERVICE_ACCOUNT_ID:-}${ANTHROPIC_WORKSPACE_ID:-}" ]; then
        echo "::error::Federation IDs are set but anthropic_federation_rule_id is empty. Set it to use federation."
      else
        echo "::error::No Claude credentials. Pass the ANTHROPIC_API_KEY secret, or set the anthropic_* federation inputs (see docs/github-action.md)."
      fi
      exit 1
    fi
    if [ -n "$oidc_url" ] && [ "${1:-}" = "--check-auth" ]; then
      echo "::warning::The caller grants 'id-token: write' but federation is not used. Remove it from the calling workflow's permissions."
    fi
    ;;
  federation)
    if [ -z "${ANTHROPIC_ORGANIZATION_ID:-}" ] || [ -z "${ANTHROPIC_SERVICE_ACCOUNT_ID:-}" ]; then
      echo "::error::Federation needs anthropic_organization_id and anthropic_service_account_id as well as anthropic_federation_rule_id."
      exit 1
    fi
    if [ -z "$oidc_url" ] || [ -z "$oidc_tok" ]; then
      echo "::error::No GitHub OIDC token available. Grant 'id-token: write' in the calling workflow (federation only)."
      exit 1
    fi
    ;;
  *)
    echo "::error::Unknown auth_mode '${RC_AUTH_MODE:-}' (expected api_key or federation)."
    exit 1
    ;;
esac
if [ "${1:-}" = "--check-auth" ]; then
  echo "Claude auth setup OK (${RC_AUTH_MODE})"
  exit 0
fi

if [ "$RC_AUTH_MODE" = api_key ]; then
  echo "Claude auth: API key"
else
  # Workload Identity Federation. Claude Code exchanges the JWT in
  # ANTHROPIC_IDENTITY_TOKEN_FILE itself and re-reads the file on each
  # refresh. GitHub JWTs live ~5 min and each can be exchanged once, so keep
  # a fresh one in the file (atomic rename) every 60s.
  # Not --bare: bare mode ignores federation variables. ANTHROPIC_API_KEY is
  # unset (not blanked) by the loop above, since a key would outrank federation.
  export ANTHROPIC_IDENTITY_TOKEN_FILE="$RUNNER_TEMP/anthropic-oidc.jwt"
  fetch_jwt() {
    curl -fsS -H "Authorization: Bearer $oidc_tok" \
      "$oidc_url&audience=https://api.anthropic.com" \
      | jq -er .value > "$ANTHROPIC_IDENTITY_TOKEN_FILE.tmp" \
      && mv -f "$ANTHROPIC_IDENTITY_TOKEN_FILE.tmp" "$ANTHROPIC_IDENTITY_TOKEN_FILE"
  }
  # The first token must exist before Claude starts: a missing file makes it
  # wait instead of failing.
  if ! fetch_jwt; then
    echo "::error::Could not fetch a GitHub OIDC token for the Anthropic exchange."
    exit 1
  fi
  ( while sleep 60; do fetch_jwt || echo "::warning::OIDC token refresh failed"; done ) &
  refresher=$!
  trap 'kill "$refresher" 2>/dev/null' EXIT
  echo "Claude auth: Workload Identity Federation"
fi
unset oidc_url oidc_tok

# A composite step cannot set timeout-minutes, so enforce the timeout here:
# TERM to claude's process group, KILL 60s later if it is still alive. The
# gate's limit is raised to fit the longest custom seat the run's config will
# run (same config, same env as the run itself).
timeout_min="$("$plugin_dir/scripts/rc-config.sh" .review-council 2>/dev/null \
  | bash "$GITHUB_ACTION_PATH/review-timeout.sh" "${RC_TIMEOUT_MINUTES:-}")" || timeout_min="${RC_TIMEOUT_MINUTES:-}"
case "$timeout_min" in ''|*[!0-9]*|0) timeout_min=45 ;; esac
echo "Review time limit: ${timeout_min} minutes"

rc=0
# --setting-sources user: the reviewed PR's .claude/ settings and hooks never
# load into a session that holds the API keys.
timeout -k 60 "${timeout_min}m" \
  claude -p "/review-council:run ${PR_NUMBER}" \
    --plugin-dir "$plugin_dir" \
    --setting-sources user \
    --allowedTools "Bash Read Grep Glob Agent Skill Write" \
    --output-format stream-json --verbose \
    > "$RUNNER_TEMP/rc-run.jsonl" || rc=$?
if [ "$rc" -eq 124 ]; then
  echo "::error::Review Council timed out after ${timeout_min} minutes (run_budget_seconds plus 30 minutes of headroom)."
fi
echo "claude exited with $rc"
exit "$rc"
