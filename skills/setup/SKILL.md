---
description: Check Review Council provider status and prerequisites
allowed-tools: Bash, Read, Write, Edit
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

### Gemini
```bash
which gemini 2>/dev/null && gemini --version
```
- If found: "Gemini (CLI) .......... available"
- If not found, check if Gemini MCP tool is available: "Gemini (MCP) .......... available"
- If neither: "Gemini ................ not found — install: `npm install -g @anthropic-ai/gemini && gemini login`"

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

```
Review Council — Provider Status

Reviewers:
  - Claude (native) ........... always available
  - Codex ..................... [available (CLI) | available (MCP) | not found]
  - Gemini ................... [available (CLI) | available (MCP) | not found]
  - Perplexity ............... [available (API) | not configured]

Prerequisites:
  - GitHub CLI (gh) ........... [authenticated | not found]

[N] of 4 reviewers available. [Convergence mode ready. | Single-reviewer mode — install at least one additional provider.]

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
- Otherwise: suggest Gemini
