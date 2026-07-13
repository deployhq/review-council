---
description: Check Review Council provider status and prerequisites
allowed-tools: Bash, Read
---

# Review Council — Setup & Status

Show the user which review providers are available and what's missing.

## Step 1: Detect Providers

Run these checks in parallel:

### Claude
Always available. Skip detection.

### Codex
```bash
which codex 2>/dev/null && codex --version
```
- If found: "Codex (CLI) ........... available"
- If not found, check if `mcp__codex__codex` tool is available: "Codex (MCP) ........... available"
- If neither: "Codex ................. not found — install: `npm install -g @openai/codex && codex login`"

### Google (Antigravity / Gemini)

One reviewer slot shared by both Google CLIs — `agy` (Antigravity) is preferred, `gemini` is the fallback.

```bash
# probe agy on PATH, then common install dirs (~/.local/bin, homebrew, /usr/local) in case PATH misses it
AGY="$(command -v agy 2>/dev/null || true)"
if [ -z "$AGY" ]; then
  for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
    [ -x "$d/agy" ] && { AGY="$d/agy"; break; }
  done
fi
[ -n "$AGY" ] && "$AGY" --version
command -v gemini >/dev/null 2>&1 && gemini --version
```
- Both found: "Google (agy → gemini) . available" — `agy` runs, `gemini` is the fallback
- Only `agy`: "Google (Antigravity) .. available"
- Only `gemini`: "Google (Gemini) ....... available"
- Neither: "Google ................ not found — install Antigravity: `curl -fsSL https://antigravity.google/cli/install.sh | bash`"

Note: Gemini CLI's consumer "Sign in with Google" was sunset 2026-06-18 — Gemini CLI now needs a `GEMINI_API_KEY`, Vertex AI, or an enterprise Gemini Code Assist license. Antigravity (`agy`) is the current path for Google-account sign-in.

### Perplexity
```bash
test -n "$PERPLEXITY_API_KEY" && echo "set" || echo "not set"
```
- If set: "Perplexity (API) ...... available"
- If not set: "Perplexity ............ not configured — set `PERPLEXITY_API_KEY` env var"

### GitHub CLI (for PR reviews)
```bash
which gh 2>/dev/null && gh auth status 2>&1 | head -3
```
- If authenticated: "GitHub CLI ............ authenticated"
- If not: "GitHub CLI ............. not found or not authenticated (PR reviews disabled)"

### Config-file support (yq) — optional, install offered with consent

Review Council reads an optional `.review-council/config.yml` (see `rules/config.md`). Parsing needs **[mikefarah/yq](https://github.com/mikefarah/yq) v4**. It is **optional**: without it, the plugin runs on built-in defaults + `RC_*` env vars (config files are ignored). Detect it first — and confirm it's the *right* `yq` (there is a different Python tool also named `yq` that must NOT count):

```bash
if command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -q 'mikefarah' && yq --version 2>&1 | grep -qE 'version v?4'; then
  echo "yq: mikefarah v4 present ($(yq --version 2>&1))"
elif command -v yq >/dev/null 2>&1; then
  echo "yq: found, but NOT mikefarah v4 ($(yq --version 2>&1)) — config files need mikefarah/yq v4"
else
  echo "yq: not found"
fi
```

- **mikefarah v4 present** → status row: "Config files (yq) ..... available (mikefarah v4 detected)". Nothing else to do.
- **missing, or the wrong `yq`** → this is the unusual case for `setup` (an interactive skill): don't just print a command and stop. Instead, **detect → ask → install-on-consent → verify**:
  1. **Explain** it's optional — needed only to *use* `.review-council/config.yml`; without it the plugin runs fine on built-in defaults + `RC_*` env vars.
  2. **Ask the user for explicit consent**, e.g.: "Install mikefarah/yq v4 now so config files work? (yes/no)". Do not proceed without an explicit yes — this is consent-gated, never a silent auto-install.
  3. **On yes**, install for the platform actually present, then re-verify:
     - If `brew` is available (macOS, or Linux with Homebrew installed): `brew install yq`.
     - Otherwise (Linux without brew): fetch the mikefarah v4 binary straight to `~/.local/bin`:
       ```bash
       mkdir -p "$HOME/.local/bin"
       curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o "$HOME/.local/bin/yq"
       chmod +x "$HOME/.local/bin/yq"
       ```
       Confirm `~/.local/bin` is on `PATH` (`echo "$PATH"`); if it isn't, tell the user to add `export PATH="$HOME/.local/bin:$PATH"` to their shell profile (a new shell will need it).
     - After installing, **re-run the detection one-liner above** to confirm `yq --version` now reports mikefarah v4. If it still doesn't (e.g. PATH not picked up yet in this session), say so plainly rather than reporting success.
  4. **On no** (or anything non-affirmative) → print the manual install command (`brew install yq`, or the `curl`/`chmod` lines above for Linux) plus the <https://github.com/mikefarah/yq#install> link, and move on — this is never a blocker.

Report the final status as one of:
- "Config files (yq) ..... available (mikefarah v4 detected)"
- "Config files (yq) ..... installed just now (mikefarah v4)" — after consent + a successful install
- "Config files (yq) ..... not installed (using defaults + RC_* env)" — declined, or install failed
- "Config files (yq) ..... wrong yq — need mikefarah/yq v4" — present but wrong, and the user declined to fix it

### Static Analysis Tools (Phase 2) — detect only, PRINT-ONLY bootstrap

Review Council's deterministic static-analysis layer (`Step 2.5` of `/review-council:run`, gated on `static_analysis.enabled`) uses up to eight external tools, split into two tiers. Full tool registry, exact invocations, and tier semantics live in `rules/static-analysis.md`; this is just an availability check.

**This block is detect-and-print only. Unlike the `yq` flow above, `setup` NEVER installs these tools — not even with consent, not even if the user says yes.** There is no install prompt for static-analysis tools, period.

Probe all eight (`command -v <tool>` + a version check), grouped by tier:

```bash
# Tier A — secrets / known-CVEs (verified/high-precision; go straight to the report)
command -v gitleaks    >/dev/null 2>&1 && gitleaks version
command -v trufflehog  >/dev/null 2>&1 && trufflehog --version
command -v osv-scanner >/dev/null 2>&1 && osv-scanner --version

# Tier B — SAST / lint (context for reviewers, not a verdict)
command -v semgrep     >/dev/null 2>&1 && semgrep --version
command -v ruff        >/dev/null 2>&1 && ruff --version
command -v shellcheck  >/dev/null 2>&1 && shellcheck --version
command -v actionlint  >/dev/null 2>&1 && actionlint --version
command -v hadolint    >/dev/null 2>&1 && hadolint --version
```

For each tool **found** → "available (\<version\>)". For each tool **missing** → "not found", then print its install command from this table and **stop there — no consent prompt, no execution**:

| Tool | Tier | Install |
|---|---|---|
| `gitleaks` | A | `brew install gitleaks` |
| `trufflehog` | A | `brew install trufflehog` (or the official install script — see the trufflehog GitHub repo's install instructions) |
| `osv-scanner` | A | `brew install osv-scanner` |
| `semgrep` | B | `brew install semgrep` (or `pipx install semgrep`) |
| `ruff` | B | `brew install ruff` (or `pipx install ruff` / `uvx ruff`) |
| `shellcheck` | B | `brew install shellcheck` |
| `actionlint` | B | `brew install actionlint` |
| `hadolint` | B | `brew install hadolint` |

State this plainly to the user: "Install any of these you want — Review Council picks them up automatically on the next run (`command -v` probe, no restart needed). `setup` only ever detects and prints; it never installs a static-analysis tool for you, even with consent."

**trufflehog outbound-network caveat.** `trufflehog`'s `--results=verified` mode makes **live outbound network calls**, authenticating with each discovered credential against its actual provider (e.g. confirming an AWS key is real by calling AWS with it) — that live check is what makes its hits verified/high-precision. Implications worth surfacing: it requires network egress from the machine running the review, and the verification call itself could trip the *credential owner's* own anomaly detection, even though the intent is benign. `trufflehog` is **default-on** (included in the default `static_analysis.tools` list) — the one-line opt-out is dropping `trufflehog` from `static_analysis.tools` in `.review-council/config.yml` (or via `RC_STATIC_TOOLS`). If the network is unreachable, the scan degrades gracefully (treated as "ran, 0 findings") — it never errors the run.

## Step 2: Summary

Print:

```text
Review Council — Provider Status

Reviewers:
  - Claude (native) ........... always available
  - Security (native, dedicated) available by default (see note below)
  - Codex ..................... [available (CLI) | available (MCP) | not found]
  - Google (agy / gemini) ..... [available (agy → gemini) | available (Antigravity) | available (Gemini) | not found]
  - Perplexity ............... [available (API) | not configured]

Prerequisites:
  - GitHub CLI (gh) ........... [authenticated | not found]

Optional:
  - Config files (yq) ......... [available (mikefarah v4 detected) | installed just now (mikefarah v4) | wrong yq — need mikefarah/yq v4 | not installed (using defaults + RC_* env)]

Note: Claude is always available; the dedicated Security reviewer runs by default, but pinning lenses.security.providers in .review-council/config.yml replaces it with the named providers (see rules/config.md) — so it is available by default, not unconditionally. Both are the same model family (Claude), so council mode and the refutation pass still need at least one reviewer from a DIFFERENT family (Codex, Google, or Perplexity) to cross-verify against.

[N] of 3 different-family reviewers available (Codex, Google, Perplexity). Council mode needs the effective roster (Claude + the dedicated Security reviewer + every enabled and available provider, after any config disables) to reach settings.min_reviewers (default 2) AND include at least one different family. [Council mode ready. | Single-reviewer mode — effective roster below min_reviewers, or no different-family reviewer.]

Static Analysis (Step 2.5, Phase 2):
  Tier A — secrets / CVEs:
    - gitleaks .................. [available (vX.Y.Z) | not found — install: `brew install gitleaks`]
    - trufflehog ................ [available (vX.Y.Z) | not found — install: `brew install trufflehog`]
    - osv-scanner ............... [available (vX.Y.Z) | not found — install: `brew install osv-scanner`]
  Tier B — SAST / lint:
    - semgrep ................... [available (vX.Y.Z) | not found — install: `brew install semgrep`]
    - ruff ...................... [available (vX.Y.Z) | not found — install: `brew install ruff`]
    - shellcheck ................ [available (vX.Y.Z) | not found — install: `brew install shellcheck`]
    - actionlint ................ [available (vX.Y.Z) | not found — install: `brew install actionlint`]
    - hadolint .................. [available (vX.Y.Z) | not found — install: `brew install hadolint`]

  [N] of 8 available; missing ones degrade gracefully — Step 2.5 informs you and asks per run (install now and re-run, or proceed without them). `setup` is print-only for these — see above.
  Note: trufflehog makes live outbound network calls to verify found credentials — drop it from `static_analysis.tools` to opt out.

(Antigravity and Gemini share the Google slot — `agy` preferred, `gemini` fallback — so they count as one reviewer, not two.)

Usage:
  /review-council:run              auto-detect target
  /review-council:run 42           review PR #42
  /review-council:run src/foo.ts   review source code
  /review-council:run docs/plan.md review a plan or document
```

## Step 3: Offer a config scaffold (optional)

Offer to create the config files so the user can customize the roster, lenses, and settings. **Only offer for files that don't already exist — never overwrite.** An all-commented file behaves exactly like no file (pure defaults), so the scaffold is safe to accept and edit later. The full schema lives in `rules/config.md`; the scaffold below is its reference blocks.

```bash
mkdir -p .review-council
if [ -e .review-council/config.yml ]; then
  echo ".review-council/config.yml already exists — leaving it untouched."
else
  echo "(offer to create .review-council/config.yml)"
fi
if [ -e .review-council/config.local.yml ]; then
  echo ".review-council/config.local.yml already exists — leaving it untouched."
else
  echo "(offer to create .review-council/config.local.yml)"
fi
```

If the user accepts, write **`.review-council/config.yml`** with the **full-reference block from `rules/config.md` (§Reference blocks → "Full reference"), reproduced here verbatim** — keep the two in sync. An all-commented file = built-in defaults; uncomment only what you want to change:

```yaml
# ── Review Council — full configuration reference ────────────────────────────
# Every key below is shown with its built-in default. All keys are optional;
# delete or comment any you don't need. `.review-council/config.local.yml` uses
# this IDENTICAL schema and overrides config.yml per key. RC_* env vars win over
# both files (settings.* only). An all-commented file = pure defaults.

# reviewers:                     # enable/disable + optional model per reviewer
#   claude:     { enabled: true,  model: "" }        # "" = the tool's own default model
#   codex:      { enabled: true,  model: "" }
#   google:     { enabled: true,  model: "" }
#   perplexity: { enabled: true,  model: sonar }

# lenses:                        # review perspectives
#   # `providers` is ALWAYS a list; OMIT it for `auto` (diff-aware selection).
#   # Pinning security.providers REPLACES the dedicated security reviewer (not additive).
#   security:
#     enabled: true
#     # providers: [google, claude]     # omit -> auto
#   correctness:
#     enabled: true
#     # providers: [claude]             # omit -> auto
#   cross_file:
#     enabled: true
#     # providers: [codex]              # omit -> auto
#   performance:
#     enabled: true
#     # providers: [google]             # omit -> auto
#   design:
#     enabled: true
#     # providers: [claude]             # omit -> auto
#   dependency:
#     enabled: true
#     # providers: [perplexity]         # default when omitted -> [perplexity]

# settings:                      # run knobs (each also settable via its RC_* env var, which wins)
#   personas:                 true     # RC_PERSONAS
#   verify:                   true     # RC_VERIFY
#   verify_max_findings:      12       # RC_VERIFY_CAP
#   learn:                    true     # RC_LEARN
#   min_reviewers:            2        # RC_MIN_REVIEWERS
#   reviewer_timeout_seconds: 600      # RC_REVIEWER_TIMEOUT
#   run_budget_seconds:       600      # RC_RUN_BUDGET
#   auto_retry:               false    # RC_AUTO_RETRY
```

And write **`.review-council/config.local.yml`** (per-machine overrides — identical schema, wins over `config.yml`):

```yaml
# .review-council/config.local.yml — per-machine overrides (NOT committed).
# Identical schema to config.yml; overrides it per key. All-commented = no overrides.
# Example:
# settings:
#   verify: false
```

Then add `config.local.yml` to the target repo's `.gitignore` so per-machine overrides are never committed (append only if not already present, and don't duplicate):

```bash
# add the ignore entry once, if missing
if ! grep -qxF '.review-council/config.local.yml' .gitignore 2>/dev/null; then
  printf '\n# Review Council per-machine config (not shared)\n.review-council/config.local.yml\n' >> .gitignore
  echo "Added .review-council/config.local.yml to .gitignore"
fi
```

Confirm to the user: config files created (or already present), and `config.local.yml` is gitignored. Remind them the files are optional and everything works on defaults without them.

## Step 4: Guidance (if needed)

If fewer than 2 providers are available, suggest the easiest one to add based on what the user likely already has:
- If they have Node.js: suggest Codex (`npm install -g @openai/codex`)
- If they have a Perplexity account: suggest setting the API key
- Otherwise: suggest Antigravity (`curl -fsSL https://antigravity.google/cli/install.sh | bash`) — the current Google-account path. (The deprecated `npm install -g @google/gemini-cli` still works only with a `GEMINI_API_KEY`, Vertex, or enterprise Code Assist license.)
