# Review Council

Multi-agent convergence review plugin for Claude Code. Multiple AI reviewers independently analyze your PR, code, or plan, then discuss until they converge on a curated list of findings.

## Commands

- `/review-council:run [target]` — Run a convergence review (auto-detects target type and available providers)
- `/review-council:setup` — Show provider status and prerequisites
- `/review-council:uninstall` — Remove configuration

## How It Works

Everything below is orchestrated locally inside a single Claude Code session and ends in a printed report — Review Council never pushes commits, opens PRs, or posts PR comments on its own (see `README.md` → GitHub Actions (Roadmap) for a possible future CI mode). Note the data egress this implies: when Codex, Google, or Perplexity are enabled, the gathered review context (diff, file contents, etc.) is sent to those third-party tools/APIs — only Claude (the native subagent) stays fully local.

1. **Detect providers + read config** — Auto-detects which reviewers are available (CLI first, MCP fallback) and reads `.review-council/config.yml` / `config.local.yml` (via `scripts/rc-config.sh`) for the reviewer roster, lens bindings, and run settings — precedence `env > config.local.yml > config.yml > built-in default`.
2. **Recall learnings** — If `settings.learn`, reads `.review-council/learnings.md` (if present). Its Conventions fold into the shared baseline context (Step 4 below); its Suppressions are held for the judge. Absent file → skip silently.
3. **Detect target** — Auto-detects if you're reviewing a PR, source code, or plan/document.
4. **Gather** — Collects relevant context (diff, files, related docs, recalled Conventions) shared identically with every reviewer.
5. **Round 1 — lens-differentiated review** — Sends the identical context to all available reviewers in parallel, each assigned a lens (Correctness & concurrency as the shared core, plus one diff-aware specialist overlay), plus an always-on dedicated **Security** reviewer.
6. **Well-formed check** — Validates each reviewer's output structurally (required §3.1 fields/sections present); retries once, then degrades or asks the user.
7. **Refutation pass** — Gated on `settings.verify` and budget-bounded: candidate findings are routed to an isolated, different-family verifier that returns UPHELD / REFUTED (counter-evidence) / INCONCLUSIVE. Skipped in solo-Claude mode or once `run_budget_seconds` is spent — findings are tagged `[unverified]` instead, never dropped.
8. **Judge** — Computes a canonical fingerprint per finding, deduplicates across models, recalibrates severity/confidence (promote on cross-family UPHELD, drop only on REFUTED, suppress known false positives from learnings), and emits a per-finding ledger.
9. **Report** — Outputs a severity-first curated list (Critical / Important / Suggestions) with confidence badges, dissenting opinions where genuinely unresolved, and the lens map.

## Reviewers

| Reviewer | Transport | Detection |
|----------|-----------|-----------|
| Claude | Native subagent | Always available |
| Security | Native subagent (dedicated) | Always available — runs regardless of which external providers are present |
| Codex | CLI (`codex exec`) / MCP fallback | `which codex` or MCP tool |
| Google (Antigravity / Gemini) | CLI — `agy` preferred, `gemini` fallback | `which agy` or `which gemini` |
| Perplexity | Sonar API (`curl`) | `PERPLEXITY_API_KEY` env var |

Minimum 2 reviewers needed for convergence mode (`settings.min_reviewers`, default 2). With only Claude, runs in single-reviewer mode. Antigravity and Gemini share one Google slot (`agy` preferred, `gemini` fallback) — they count as one reviewer, not two.

Round 1 is **lens-differentiated**: the dedicated Security reviewer always carries the Security lens; every repo-capable frontier reviewer (Claude, Codex, Google) carries Correctness & concurrency as its core plus one diff-aware specialist overlay (Cross-file/API-contract, Performance & reliability, Design & maintainability, Data-integrity & migration, Config/workflow, or UI-state & accessibility); tool-less Perplexity always carries Dependency/CVE/best-practices. Lens = emphasis, not blinders — every reviewer still flags any critical issue it notices outside its lens. The roster, lens bindings, and run settings are configurable per-repo via `.review-council/config.yml` / `config.local.yml` — see `rules/config.md`.

## Architecture

```
/review-council:run [target]
      |
      v
  Step 0: Detect providers + read config (roster, lenses, settings)
      |
      v
  Step 0.5: Recall learnings (.review-council/learnings.md)
      |
      v
  Step 1-2: Detect target + gather baseline context
      |
      v
  Orchestrator (main Claude thread)
      |
      +---> Step 3: Round 1 (parallel, lens-differentiated) --------+
      |     - Claude (subagent)        [Correctness + overlay]      |
      |     - Security (subagent)      [Security — always on]      |
      |     - Codex (CLI/MCP)          [Correctness + overlay]      |
      |     - Google (agy→gemini)      [Correctness + overlay]      |
      |     - Perplexity (API)         [Dependency/CVE]             |
      |<--------------------------------------------------------------+
      |
      v
  Step 3.5: Well-formed check & recover (structural validation)
      |
      v
  Step 4: Refutation pass (cross-family, budget-bounded)
      UPHELD / REFUTED / INCONCLUSIVE per finding
      |
      v
  Step 5: Judge (fingerprint, dedup, recalibrate, suppress, ledger)
      |
      v
  Step 6: Severity-first report (badges, dissent, lens map)
```

## File Structure

```
review-council/
  .claude-plugin/     Plugin metadata (plugin.json is the single source of truth for version)
  skills/             Slash commands (run, setup, uninstall)
  agents/             Subagent definitions (Claude reviewer persona, dedicated Security reviewer)
  rules/              Orchestration logic, delegation format, provider registry, config schema (rules/config.md)
  scripts/            Config reader (rc-config.sh) and Google-slot invocation state machine (rc-invoke-provider.sh)
  tests/              bats unit tests for the scripts, plus Tier-2 artifact-shape fixtures (local/on-demand, never CI)
```

## Versioning

Bump the `version` field in `.claude-plugin/plugin.json` whenever you ship a bug fix or new feature (semver: patch for fixes, minor for features, major for breaking changes). `marketplace.json` inherits from `plugin.json` via strict-mode merge — do not duplicate the version there. Pair the bump with a `chore: bump version to X.Y.Z` commit after the change.
