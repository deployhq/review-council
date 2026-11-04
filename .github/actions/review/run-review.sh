#!/usr/bin/env bash
# Run `/review-council:run` unattended (called by .github/actions/review/action.yml,
# from the reviewed repo's checkout).
# Inputs (env): RC_AUTH_MODE (api_key|federation), RC_TIMEOUT_MINUTES, PR_NUMBER,
#   RC_CLAUDE_MODEL, RC_CODEX_MODEL, RC_CODEX_PROVIDER, the RC_* run settings, GH_TOKEN, the provider keys,
#   CLAUDE_CODE_OAUTH_TOKEN, CODEX_ACCESS_TOKEN, RC_PR_BOT_TOKEN(_ENV), and in
#   federation mode the ANTHROPIC_* federation IDs plus the runner's
#   ACTIONS_ID_TOKEN_REQUEST_URL / ACTIONS_ID_TOKEN_REQUEST_TOKEN.
set -uo pipefail

plugin_dir="$(cd "$GITHUB_ACTION_PATH/../../.." && pwd -P)"

# Unset empty optional values so they read as "not set", not "set to ''"
# (an empty credential variable can still win its precedence slot).
for v in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN CODEX_API_KEY CODEX_ACCESS_TOKEN \
         OPENROUTER_API_KEY PERPLEXITY_API_KEY RC_CLAUDE_MODEL RC_CODEX_MODEL RC_CODEX_PROVIDER \
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

# Check the credential setup. This is the one place it is validated. Claude
# takes exactly one of: an API key (ANTHROPIC_API_KEY), a subscription OAuth
# token (CLAUDE_CODE_OAUTH_TOKEN, from `claude setup-token`), or federation
# (the workflow sets RC_AUTH_MODE=federation when anthropic_federation_rule_id
# is set; api_key mode covers both secrets). Codex takes at most one of an API
# key or an Enterprise access token. The action also runs this script with
# --check-auth as its first step, so a bad setup fails before the installs.
fed_ids="${ANTHROPIC_FEDERATION_RULE_ID:-}${ANTHROPIC_ORGANIZATION_ID:-}${ANTHROPIC_SERVICE_ACCOUNT_ID:-}${ANTHROPIC_WORKSPACE_ID:-}"
n=0
[ -z "${ANTHROPIC_API_KEY:-}" ] || n=$((n + 1))
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || n=$((n + 1))
[ -z "$fed_ids" ] || n=$((n + 1))
if [ "$n" -gt 1 ]; then
  echo "::error::Give Claude only one credential: the ANTHROPIC_API_KEY secret, the CLAUDE_CODE_OAUTH_TOKEN secret, or the anthropic_* federation inputs."
  exit 1
fi
if [ -n "${CODEX_API_KEY:-}" ] && [ -n "${CODEX_ACCESS_TOKEN:-}" ]; then
  echo "::error::Give Codex only one credential: the OPENAI_API_KEY secret or the CODEX_ACCESS_TOKEN secret."
  exit 1
fi
# check_model <input> <value> [allow-1m]: a model ID from a workflow input.
# Whole-string match ([[ =~ ]], not grep -x, which passes a multi-line value).
# The charset keeps it safe on a command line and inside a TOML string.
# allow-slash is for OpenRouter IDs (vendor/model).
check_model() {
  local re='^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}' extra=""
  case "${3:-}" in
    allow-1m)
      re+='(\[[A-Za-z0-9]{1,8}\])?'
      extra=" and an optional [1m] suffix"
      ;;
    allow-slash)
      re='^[A-Za-z0-9][A-Za-z0-9._:/-]{0,79}'
      extra=" /"
      ;;
  esac
  re+='$'
  if [ -n "$2" ] && ! [[ "$2" =~ $re ]]; then
    echo "::error::Invalid $1 (allowed: letters, digits, . _ : -$extra)."
    exit 1
  fi
}
check_model claude_model "${RC_CLAUDE_MODEL:-}" allow-1m
# codex_provider: openai (default; OPENAI_API_KEY or CODEX_ACCESS_TOKEN) or
# openrouter (OPENROUTER_API_KEY and an OpenRouter model ID). Native Codex also
# refutes Claude's findings, so on OpenRouter its model must come from a known
# family other than Claude: a Claude model, or a router that may pick one,
# would have Claude checking its own work.
case "${RC_CODEX_PROVIDER:-openai}" in
  openai)
    check_model codex_model "${RC_CODEX_MODEL:-}"
    ;;
  openrouter)
    if [ -n "${CODEX_API_KEY:-}${CODEX_ACCESS_TOKEN:-}" ]; then
      echo "::error::codex_provider openrouter uses the OPENROUTER_API_KEY secret. Remove the OPENAI_API_KEY / CODEX_ACCESS_TOKEN secret from the call."
      exit 1
    fi
    if [ -z "${OPENROUTER_API_KEY:-}" ]; then
      echo "::error::codex_provider openrouter needs the OPENROUTER_API_KEY secret."
      exit 1
    fi
    if [ -z "${RC_CODEX_MODEL:-}" ]; then
      echo "::error::codex_provider openrouter needs codex_model, as an OpenRouter model ID (e.g. openai/gpt-6-luna)."
      exit 1
    fi
    check_model codex_model "$RC_CODEX_MODEL" allow-slash
    # shellcheck source=/dev/null
    . "$plugin_dir/scripts/rc-lib-family.sh"
    case "$(rc_family "$RC_CODEX_MODEL")" in
      Claude | unknown)
        echo "::error::codex_model '$RC_CODEX_MODEL' is not allowed for the Codex reviewer on OpenRouter: it must be an OpenAI, Google, Qwen, Moonshot, Zhipu or DeepSeek model, not a Claude model or a router."
        exit 1
        ;;
    esac
    ;;
  *)
    # The value is not echoed: a multi-line one could forge log commands.
    echo "::error::Unknown codex_provider (expected openai or openrouter)."
    exit 1
    ;;
esac
case "${RC_AUTH_MODE:-}" in
  api_key)
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      auth_label="API key"
    elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
      auth_label="OAuth token (Claude subscription)"
    elif [ -n "${ANTHROPIC_ORGANIZATION_ID:-}${ANTHROPIC_SERVICE_ACCOUNT_ID:-}${ANTHROPIC_WORKSPACE_ID:-}" ]; then
      echo "::error::Federation IDs are set but anthropic_federation_rule_id is empty. Set it to use federation."
      exit 1
    else
      echo "::error::No Claude credentials. Pass the ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN secret, or set the anthropic_* federation inputs (see docs/github-action.md)."
      exit 1
    fi
    if [ -n "$oidc_url" ] && [ "${1:-}" = "--check-auth" ]; then
      echo "::warning::The caller grants 'id-token: write' but federation is not used. Remove it from the calling workflow's permissions."
    fi
    ;;
  federation)
    auth_label="Workload Identity Federation"
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
  echo "Claude auth setup OK: ${auth_label}"
  exit 0
fi

if [ "$RC_AUTH_MODE" = api_key ]; then
  echo "Claude auth: ${auth_label}"
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

# Codex with an Enterprise access token: log in once (into ~/.codex, where the
# council's `codex exec` reads it), then drop the variable from the env.
if [ -n "${CODEX_ACCESS_TOKEN:-}" ]; then
  if printenv CODEX_ACCESS_TOKEN | codex login --with-access-token >/dev/null 2>&1; then
    echo "Codex auth: access token (ChatGPT Enterprise)"
  else
    echo "::warning::Codex could not log in with CODEX_ACCESS_TOKEN; the run continues without native Codex."
  fi
  unset CODEX_ACCESS_TOKEN
fi

# codex_model / codex_provider: set in Codex's own config (~/.codex, which the
# Codex reviewer and the refutation pass both use; custom codex seats run with
# a throwaway CODEX_HOME and keep their own settings). A value the config
# already has (a self-hosted runner's own) is kept.
codex_cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
# codex_set_top <key> <value>: add a top-level key as the first line (a key
# after a [table] header would belong to that table).
codex_set_top() {
  mkdir -p "$(dirname "$codex_cfg")"
  if grep -qE "^[[:space:]]*$1[[:space:]]*=" "$codex_cfg" 2>/dev/null; then
    echo "::warning::Codex's config.toml already sets $1; keeping it."
    return 0
  fi
  { printf '%s = "%s"\n' "$1" "$2"; cat "$codex_cfg" 2>/dev/null || :; } >"$codex_cfg.new" &&
    mv -f "$codex_cfg.new" "$codex_cfg"
}
if [ -n "${RC_CODEX_MODEL:-}" ]; then
  codex_set_top model "$RC_CODEX_MODEL"
  echo "Codex model: $RC_CODEX_MODEL"
fi
if [ "${RC_CODEX_PROVIDER:-}" = openrouter ]; then
  codex_set_top model_provider openrouter
  # The same fixed provider as rc-seat.sh's codex seats; codex reads the key
  # from OPENROUTER_API_KEY. Appended once: a repeated table stops codex.
  if ! grep -qE '^[[:space:]]*\[model_providers\.openrouter\]' "$codex_cfg" 2>/dev/null; then
    printf '\n[model_providers.openrouter]\nname = "OpenRouter"\nbase_url = "https://openrouter.ai/api/v1"\nwire_api = "responses"\nenv_key = "OPENROUTER_API_KEY"\n' >>"$codex_cfg"
  fi
  echo "Codex provider: OpenRouter"
fi

# A reviewer that fails (Codex, Google) appends its reason and its own error
# line here; summary.sh prints them in the step log. Never shown to the model.
export RC_FAIL_LOG="$RUNNER_TEMP/rc-failures.log"

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
model_args=()
[ -z "${RC_CLAUDE_MODEL:-}" ] || model_args=(--model "$RC_CLAUDE_MODEL")
timeout -k 60 "${timeout_min}m" \
  claude -p "/review-council:run ${PR_NUMBER}" \
    ${model_args[@]+"${model_args[@]}"} \
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
