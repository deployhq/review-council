#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for the credential checks in .github/actions/review/run-review.sh
# (`--check-auth`): which Claude and Codex credentials may be combined, and
# the claude_model charset. Runs the real script under a clean env.
#
# Run: bats tests/unit/run-review-auth.bats

ACTION="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/.github/actions/review"

# check [VAR=value ...]: run --check-auth with only the given variables set.
check() {
  run --separate-stderr env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" GITHUB_ACTION_PATH="$ACTION" \
    RC_AUTH_MODE="${MODE:-api_key}" "$@" bash "$ACTION/run-review.sh" --check-auth
}
fails_with() { [ "$status" -ne 0 ] && printf '%s' "$output" | grep -qF "$1"; }

@test "auth: an API key alone is accepted" {
  check ANTHROPIC_API_KEY=k
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'API key'
}

@test "auth: a Claude OAuth token alone is accepted" {
  check CLAUDE_CODE_OAUTH_TOKEN=t
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'OAuth'
}

@test "auth: an API key and an OAuth token together are refused" {
  check ANTHROPIC_API_KEY=k CLAUDE_CODE_OAUTH_TOKEN=t
  fails_with 'only one'
}

@test "auth: an OAuth token with federation IDs is refused" {
  MODE=federation check CLAUDE_CODE_OAUTH_TOKEN=t ANTHROPIC_FEDERATION_RULE_ID=r ANTHROPIC_ORGANIZATION_ID=o ANTHROPIC_SERVICE_ACCOUNT_ID=s
  fails_with 'only one'
}

@test "auth: no Claude credential is refused and names all three options" {
  check
  fails_with 'CLAUDE_CODE_OAUTH_TOKEN'
  printf '%s' "$output" | grep -qF 'ANTHROPIC_API_KEY'
}

@test "auth: an empty credential counts as not set" {
  check ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN=t
  [ "$status" -eq 0 ]
}

@test "auth: an OpenAI key and a Codex access token together are refused" {
  check ANTHROPIC_API_KEY=k CODEX_API_KEY=o CODEX_ACCESS_TOKEN=a
  fails_with 'Codex'
}

@test "auth: a Codex access token alone is accepted" {
  check ANTHROPIC_API_KEY=k CODEX_ACCESS_TOKEN=a
  [ "$status" -eq 0 ]
}

@test "auth: a valid claude_model is accepted" {
  check ANTHROPIC_API_KEY=k RC_CLAUDE_MODEL=claude-opus-5-5
  [ "$status" -eq 0 ]
  check ANTHROPIC_API_KEY=k RC_CLAUDE_MODEL='sonnet[1m]'
  [ "$status" -eq 0 ]
}

@test "auth: a claude_model with shell characters is refused" {
  check ANTHROPIC_API_KEY=k RC_CLAUDE_MODEL='opus; id'
  fails_with 'claude_model'
}
