#!/usr/bin/env bash
# Install the custom-seat harnesses the resolved config enables (called by
# .github/actions/review/action.yml, from the reviewed repo's checkout).
# Inputs (env): RC_CI RC_APPROVED_SEATS CODEX_VERSION OPENCODE_VERSION OCR_VERSION
set -euo pipefail

plugin_dir="$(cd "$GITHUB_ACTION_PATH/../../.." && pwd -P)"

cfg="$("$plugin_dir/scripts/rc-config.sh" .review-council 2>/dev/null || true)"
harnesses="$(awk -F= '
  /^reviewer\.custom\.[^.]+\.enabled=true$/ { split($1, k, "."); on[k[3]] = 1 }
  /^reviewer\.custom\.[^.]+\.needs_confirm=true$/ { split($1, k, "."); nc[k[3]] = 1 }
  /^reviewer\.custom\.[^.]+\.harness=/       { split($1, k, "."); h[k[3]] = $2 }
  END { for (s in h) if (on[s] && !nc[s]) print h[s] }
' <<<"$cfg" | sort -u)"
if [ -z "$harnesses" ]; then
  echo "No enabled custom seats."
  exit 0
fi
for h in $harnesses; do
  case "$h" in
    claude) echo "claude harness: already installed" ;;
    codex)
      command -v codex >/dev/null || npm install -g "@openai/codex@${CODEX_VERSION}"
      codex --version ;;
    opencode)
      npm install -g "opencode-ai@${OPENCODE_VERSION}"
      opencode --version ;;
    ocr)
      npm install -g "@alibaba-group/open-code-review@${OCR_VERSION}"
      command -v ocr ;;
    *) echo "::warning::unknown harness '$h' — not installed" ;;
  esac
done
jq --version
