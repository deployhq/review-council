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
which agy 2>/dev/null && agy --version
which gemini 2>/dev/null && gemini --version
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

## Step 2: Summary

Print:

```text
Review Council — Provider Status

Reviewers:
  - Claude (native) ........... always available
  - Codex ..................... [available (CLI) | available (MCP) | not found]
  - Google (agy / gemini) ..... [available (agy → gemini) | available (Antigravity) | available (Gemini) | not found]
  - Perplexity ............... [available (API) | not configured]

Prerequisites:
  - GitHub CLI (gh) ........... [authenticated | not found]

[N] of 4 reviewer slots available. [Convergence mode ready. | Single-reviewer mode — install at least one additional provider.]

(Antigravity and Gemini share the Google slot — `agy` preferred, `gemini` fallback — so they count as one reviewer, not two.)

Usage:
  /review-council:run              auto-detect target
  /review-council:run 42           review PR #42
  /review-council:run src/foo.ts   review source code
  /review-council:run docs/plan.md review a plan or document
```

## Step 3: Guidance (if needed)

If fewer than 2 providers are available, suggest the easiest one to add based on what the user likely already has:
- If they have Node.js: suggest Codex (`npm install -g @openai/codex`)
- If they have a Perplexity account: suggest setting the API key
- Otherwise: suggest Antigravity (`curl -fsSL https://antigravity.google/cli/install.sh | bash`) — the current Google-account path. (The deprecated `npm install -g @google/gemini-cli` still works only with a `GEMINI_API_KEY`, Vertex, or enterprise Code Assist license.)
