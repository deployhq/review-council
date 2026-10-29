#!/usr/bin/env bash
# Install the static-analysis tools, best effort (called by
# .github/actions/review/action.yml). shellcheck and jq ship with
# ubuntu-latest; pipx is preinstalled.
# Inputs (env): GITLEAKS_VERSION TRUFFLEHOG_VERSION OSV_SCANNER_VERSION
#   ACTIONLINT_VERSION HADOLINT_VERSION SEMGREP_VERSION RUFF_VERSION
set -uo pipefail

bin="$HOME/.local/bin"
tmp="$(mktemp -d)"
get_tar() { # <url> <binary-name>
  curl -fsSL "$1" -o "$tmp/a.tgz" && tar -xzf "$tmp/a.tgz" -C "$tmp" "$2" && install -m 0755 "$tmp/$2" "$bin/$2"
}
get_bin() { # <url> <binary-name>
  curl -fsSL "$1" -o "$bin/$2" && chmod +x "$bin/$2"
}
gh_dl=https://github.com
get_tar "$gh_dl/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" gitleaks \
  || echo "::warning::gitleaks install failed"
get_tar "$gh_dl/trufflesecurity/trufflehog/releases/download/v${TRUFFLEHOG_VERSION}/trufflehog_${TRUFFLEHOG_VERSION}_linux_amd64.tar.gz" trufflehog \
  || echo "::warning::trufflehog install failed"
get_bin "$gh_dl/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_linux_amd64" osv-scanner \
  || echo "::warning::osv-scanner install failed"
get_tar "$gh_dl/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" actionlint \
  || echo "::warning::actionlint install failed"
get_bin "$gh_dl/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-x86_64" hadolint \
  || echo "::warning::hadolint install failed"
pipx install "semgrep==${SEMGREP_VERSION}" || echo "::warning::semgrep install failed"
pipx install "ruff==${RUFF_VERSION}" || echo "::warning::ruff install failed"
rm -rf "$tmp"
for t in gitleaks trufflehog osv-scanner semgrep ruff shellcheck actionlint hadolint; do
  if command -v "$t" >/dev/null; then echo "$t: ok"; else echo "$t: missing"; fi
done
