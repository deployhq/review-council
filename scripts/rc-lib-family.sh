# rc-lib-family.sh — the slug -> model-family map for custom reviewer seats.
#
# Sourced (not executed) by scripts/rc-config.sh and scripts/rc-ocr.sh, so the
# reader and the ocr output mapper derive a family from ONE function. POSIX sh.
#
# A seat's family is the MODEL's vendor, never the harness's: Kimi run through
# ocr is Moonshot, not "ocr". Families decide cross-family corroboration and
# refutation routing, so the map is deliberately conservative:
#   - native  : Claude, OpenAI, Google — collide with the built-in seats.
#   - distinct: Qwen, Moonshot, Zhipu, DeepSeek.
#   - unknown : everything else (meta-routers, presets, unmapped vendors).
# Only a distinct family earns cross-family credit. A missing or wrong entry can
# therefore only WITHHOLD credit, never manufacture it.
#
# Derivation (spec §5): strip every leading "~" (OpenRouter's latest-alias),
# lowercase, then match a prefix that is followed by end-of-string, "/", "-",
# ".", ":" or a digit. First match wins.

# rc_family <slug>: prints the canonical family for <slug>.
rc_family() {
  _rf_s="$1"
  while :; do
    case "$_rf_s" in
      '~'*) _rf_s="${_rf_s#\~}" ;;
      *) break ;;
    esac
  done
  # ASCII-only on purpose: slugs are ASCII by the modelslug guard.
  # shellcheck disable=SC2018,SC2019
  _rf_s="$(printf '%s' "$_rf_s" | tr 'A-Z' 'a-z')"
  for _rf_pair in \
    'qwen=Qwen' \
    'moonshotai/kimi=Moonshot' \
    'z-ai/glm=Zhipu' \
    'deepseek=DeepSeek' \
    'anthropic/claude=Claude' \
    'openai/gpt=OpenAI' \
    'google/gemini=Google'; do
    _rf_prefix="${_rf_pair%%=*}"
    case "$_rf_s" in
      "$_rf_prefix" | "$_rf_prefix"/* | "$_rf_prefix"-* | "$_rf_prefix".* | "$_rf_prefix":* | "$_rf_prefix"[0-9]*)
        printf '%s\n' "${_rf_pair#*=}"
        return 0
        ;;
    esac
  done
  printf 'unknown\n'
}

# rc_family_distinct <family>: exit 0 iff <family> is a distinct family (one
# that differs from every native seat, so it can earn cross-family credit).
rc_family_distinct() {
  case "$1" in
    Qwen | Moonshot | Zhipu | DeepSeek) return 0 ;;
    *) return 1 ;;
  esac
}
