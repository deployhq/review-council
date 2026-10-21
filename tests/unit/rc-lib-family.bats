#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for scripts/rc-lib-family.sh — the slug -> family map shared by
# the config reader and the ocr output mapper (spec §5).
#
# Run: bats tests/unit/rc-lib-family.bats

LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/rc-lib-family.sh"

family() { sh -c '. "$1"; rc_family "$2"' sh "$LIB" "$1"; }
distinct() { sh -c '. "$1"; rc_family_distinct "$2"' sh "$LIB" "$1"; }

@test "family: every row of the spec's table" {
  while IFS='|' read -r slug want; do
    got="$(family "$slug")"
    [ "$got" = "$want" ] || { echo "$slug -> $got (want $want)"; return 1; }
  done <<'TABLE'
qwen/qwen3.8-max-0902|Qwen
qwen3.6:35b-a3b-coding-nvfp4|Qwen
qwen|Qwen
moonshotai/kimi-k2.7-code|Moonshot
~moonshotai/kimi-latest|Moonshot
~~MoonshotAI/Kimi-Latest|Moonshot
z-ai/glm-5|Zhipu
deepseek/deepseek-v4|DeepSeek
deepseek-r1:32b|DeepSeek
anthropic/claude-opus-latest|Claude
openai/gpt-5.6|OpenAI
google/gemini-3|Google
x-ai/grok-4|unknown
perplexity/sonar-reasoning|unknown
openrouter/fusion|unknown
@preset/my-thing|unknown
qwenfake/x|unknown
moonshotai/other|unknown
TABLE
}

@test "family: the map's value set equals the canonical set" {
  # Every family the map can produce, plus unknown — nothing else.
  for slug in qwen moonshotai/kimi z-ai/glm deepseek anthropic/claude openai/gpt google/gemini zzz; do
    family "$slug"
  done | sort -u >"$BATS_TEST_TMPDIR/got"
  printf '%s\n' Claude DeepSeek Google Moonshot OpenAI Qwen Zhipu unknown | sort >"$BATS_TEST_TMPDIR/want"
  diff "$BATS_TEST_TMPDIR/want" "$BATS_TEST_TMPDIR/got"
}

@test "distinct: exactly Qwen, Moonshot, Zhipu, DeepSeek" {
  for f in Qwen Moonshot Zhipu DeepSeek; do distinct "$f"; done
  for f in Claude OpenAI Google unknown Codex ''; do
    run distinct "$f"
    [ "$status" -ne 0 ]
  done
}
