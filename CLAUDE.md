# Review Council

<!-- rc:description:start -->
Multi-agent code review for Claude Code. Multiple AI models review your PR, code, or plan independently; a cross-family refutation pass and an active judge then distill the findings into a curated, severity-ranked list of what actually needs changing.
<!-- rc:description:end -->

## Commands

- `/review-council:run [target]` — Run a multi-agent review (auto-detects target type and available providers)
- `/review-council:setup` — Show provider status and prerequisites
- `/review-council:uninstall` — Remove configuration

## How It Works

Everything below is orchestrated locally inside a single Claude Code session and ends in a printed report. **By default Review Council is report-only** — it never pushes commits or posts to a PR on its own. The one exception is opt-in: when `pr_comments.enabled` is set (default **off**), an added step (Step 6.6) posts the findings to the PR — **one review per run**, whose text is the summary, with inline comments on the diff — but only after an explicit human confirmation, never automatically, and it may offer to open a draft PR if none exists. See the **Posting to PRs** section in `README.md`. **CI mode is the one sanctioned exception to the human gate:** with `RC_CI=true` (set by the reusable workflow `.github/workflows/review-council.yml`, guide in `docs/github-action.md`) no human is present, so the run never asks anything and Step 6.6 posts automatically — still only when `pr_comments.enabled` is on (the workflow sets `RC_PR_COMMENTS=true`), and it never opens a draft PR. Note the data egress this implies: when Codex, Google, or Perplexity are enabled, the gathered review context (diff, file contents, etc.) is sent to those third-party tools/APIs — only Claude (the native subagent) stays fully local. An opt-in **custom reviewer seat** (`reviewers.custom`, harness `ocr`) sends review context to **OpenRouter and the model's host** (with `data_collection: deny` hard-coded), or **nowhere** for a local Ollama model. When posting is enabled, the findings and the digest (findings + decisions) are also sent to GitHub.

1. **Detect providers + read config** — Auto-detects which reviewers are available (CLI first, MCP fallback) and reads `.review-council/config.yml` / `config.local.yml` (via `scripts/rc-config.sh`) for the reviewer roster, lens bindings, and run settings — precedence `env > config.local.yml > config.yml > built-in default`. Custom reviewer seats also read the trusted user layer `~/.review-council/config.yml`; a risky seat that only the committed config enables (`confirm.<n>` lines) is put to the user once before it runs.
2. **Recall learnings** — If `settings.learn`, reads `.review-council/learnings.md` (if present). Its Conventions fold into the shared baseline context (the Gather step below); its Suppressions are held for the judge. Absent file → skip silently.
3. **Detect target** — Auto-detects if you're reviewing a PR, source code, or plan/document.
4. **Gather** — Collects relevant context (diff, files, related docs, recalled Conventions) shared identically with every reviewer.
5. **Static analysis** (Step 2.5, gated on `static_analysis.enabled`) — One subagent runs up to eight external tools (`gitleaks`, `trufflehog`, `osv-scanner`, `semgrep`, `ruff`, `shellcheck`, `actionlint`, `hadolint`) against the diff. **Tier A** (verified secrets/CVEs) is carried straight to the judge, pre-`[verified]`; **Tier B** (SAST/lint) is folded into the shared context above as signals for reviewers to corroborate or dismiss. Not a voting reviewer — no lens, doesn't count toward `min_reviewers`, never refuted in the refutation pass. See "Static Analysis" below.
6. **Round 1 — lens-differentiated review** — Sends the identical context to all available reviewers in parallel, each assigned a lens (Correctness & concurrency as the shared core, plus one diff-aware specialist overlay), plus an always-on dedicated **Security** reviewer. Opt-in **custom seats** (user-chosen models; any number per run) run alongside them in the background, each through a harness CLI: `codex`, `claude` or `opencode` seats get the same shared context and a lens; an `ocr` seat reviews the git diff itself (no shared context, no lens) and its coverage line is always printed. All seats are finder-only.
7. **Well-formed check** — Validates each reviewer's output structurally (required §3.1 fields/sections present); retries once, then degrades or asks the user.
8. **Refutation pass** — Gated on `settings.verify` and budget-bounded: candidate findings are routed to an isolated, different-family verifier that returns UPHELD / REFUTED (counter-evidence) / INCONCLUSIVE. Skipped in solo-Claude mode (for the native findings — a distinct custom seat's findings are still refuted by a fresh Claude verifier) or once `run_budget_seconds` is spent — findings are tagged `[1 reviewer · unverified]` (solo-Claude) or `[unverified]` (budget/over-cap) instead, never dropped.
9. **Judge** — Computes a canonical fingerprint per finding (LLM and tool findings alike), deduplicates across models, recalibrates severity/confidence (promote on cross-family UPHELD, drop only on REFUTED, suppress known false positives from learnings), merges in the Tier A/B static-analysis findings, and emits a per-finding ledger.
10. **Report** — Outputs a severity-first curated list (Critical / Important / Suggestions) with confidence badges (`[verified]` > `[cross-reviewed]` > `[1 reviewer · unverified]` > `[unverified]` > `[tool-only:<rule>]`), dissenting opinions where genuinely unresolved, and the lens map.
11. **Post digest** (Step 6.6, gated on `pr_comments.enabled`, default off) — Optional and human-confirmed: after the report, walks the findings with the author (fix / defer / won't-fix — the same walk Step 7 reuses), composes the **digest** (who reviewed · the findings off the diff · collapsed *what the council decided* · *what was fixed*), and posts it via `scripts/rc-post.sh review` as the text of **one review per run**, which reads the judge's JSON ledger (§5.7): each reported finding on a line of the PR's diff becomes an **inline review comment** (one review per run, **request changes** when any finding is critical/important, a plain comment otherwise; our earlier request is dismissed once nothing blocks, and findings listed in a request a *person* dismissed never request changes again — the review body carries a hidden `rc:blocking` fingerprint list and the PR timeline says who dismissed it; each comment carries the report's confidence tag, which the summary explains); findings off the diff are written into the summary. There is no separate summary comment: one is posted only if GitHub accepts no review, and an earlier one is replaced by a link to the latest review. Re-runs match earlier inline comments by fingerprint: already-commented findings are left alone, and an earlier comment the run no longer reports is re-checked by a read-only Claude subagent (Step 6.6.4) and resolved only if judged fixed — never on a degraded run; if GitHub refuses the resolve, the one marked "looks fixed" reply stays and a person resolves it, a thread a *person* resolved is left alone, and a resolved finding that comes back gets a new comment. If GitHub refuses to dismiss (protected-branch dismissal rules), our request stays until a person dismisses it. The body starts with `<!-- rc:report -->` and a hidden `<!-- rc:state {...} -->` line (reviewed SHA, `clean`/`findings`/`degraded`, per-severity counts, failed reviewers) and ends with a `Review done with Review Council · <identity>` footer, which `rc-post.sh` adds to the review and to every inline comment; likely secrets are redacted to `[REDACTED]` before posting. Posts as the authenticated `gh` user by default (the footer marks it automated), as `github-actions[bot]` in CI (or the caller's own App/bot via the workflow's `PR_BOT_TOKEN` secret), or as a bot when `pr_comments.bot_token_env` names a set token var. If no PR exists it offers to open a draft. **With `RC_CI=true`** it posts without the confirm, skips the triage walk (no "what was fixed" section), and never offers a draft; if every reviewer fails it still posts a short "review could not run" digest with `status=degraded` naming them (never a silent pass). Fail-soft — never blocks or mutates the review.
12. **Capture Gate** (Step 7, gated on `settings.learn`) — Record-only: after the report, walks the surviving findings with the author (tackle / skip / skip-all — reusing Step 6.6's walk when posting ran), distills a *skip with a generalizable reason* into a Suppression (keyed by the judge's canonical fingerprint) or a Convention, and — human-confirmed only — appends it to `.review-council/learnings.md` via `scripts/rc-learn.sh`. This is the write side of the learnings loop; what it writes here, step 2 (Recall learnings) reads on the next run.

## Static Analysis (Step 2.5)

A deterministic layer that gives the council grounded evidence, not a second vote — never a reviewer itself (no lens, doesn't count toward `min_reviewers`, never refuted in the refutation pass):

- **Tier A — verified / high-precision** (`gitleaks`, `trufflehog`, `osv-scanner`): secrets and known-CVE hits go straight into the report, pre-verified, badge `[verified]`, exempt from the suggestion cap, never downgraded by the judge (severity is **inherited**, not judge-assigned). `gitleaks` is precision-by-rule (regex/entropy), not live-verified like `trufflehog` — see `rules/static-analysis.md`.
- **Tier B — SAST / lint** (`semgrep`, `ruff`, `shellcheck`, `actionlint`, `hadolint`): folded into Round 1's shared context as "PRE-EXISTING STATIC-ANALYSIS SIGNALS — corroborate or dismiss." A reviewer match on the same (judge-computed) fingerprint promotes the finding to `[verified]`; a tool-only hit stays a capped `suggestion` badged `[tool-only:<rule>]`.

Configured via `static_analysis.*` in `.review-council/config.yml` (`enabled`, `tools`, `timeout_seconds`, `semgrep_config` — see `rules/config.md`). `/review-council:setup` prints tool availability and install commands but never installs one itself (print-only, unlike the `yq` flow). **Caveat:** `trufflehog`'s verified mode makes live outbound network calls to confirm a found credential is real — it's default-on; drop it from `static_analysis.tools` (or `RC_STATIC_TOOLS`) to opt out. If a tool listed in `static_analysis.tools` isn't installed, Step 2.5 doesn't skip it silently — it tells the user and asks whether to install-and-rerun, **run it via its official Docker image for this run** (no local install; the four core scanners `gitleaks`/`trufflehog`/`semgrep`/`osv-scanner` only, opt-in per-run via `RC_STATIC_DOCKER_TOOLS`, native-install-always-wins, config-invariant when unset), or proceed without it.

## Reviewers

| Reviewer | Transport | Detection |
|----------|-----------|-----------|
| Claude | Native subagent | Always available |
| Security | Native subagent (dedicated) | Always available — runs regardless of which external providers are present |
| Codex | CLI (`codex exec`) / MCP fallback | `which codex` or MCP tool |
| Google (Antigravity / Gemini) | CLI — `agy` preferred, `gemini` fallback | `which agy` or `which gemini` |
| Perplexity | Sonar API (`curl`) | `PERPLEXITY_API_KEY` env var |
| Custom seats (opt-in) | `codex` / `claude` / `opencode` via `scripts/rc-seat.sh`; `ocr` via `scripts/rc-ocr.sh` (background, isolated) | a `reviewers.custom` entry + the harness binary (`ocr` also `jq`) + (OpenRouter) the `api_key_env` var |

Minimum 2 reviewers needed for council mode (`settings.min_reviewers`, default 2). Claude and the dedicated Security reviewer are both native and always run, but they are the **same model family (Claude)** — council mode and the refutation pass need at least one reviewer from a **different family** (Codex, Google, or Perplexity) to cross-verify against. With only Claude-family reviewers available, the run proceeds in single-reviewer mode. Antigravity and Gemini share one Google slot (`agy` preferred, `gemini` fallback) — they count as one reviewer, not two.

A **custom seat** is a user-chosen model run through a harness CLI (`codex`, `claude`, `opencode` or `ocr`); its family is the model's, never the harness's. Its `role` is `signal` (default — findings in a separate "Extra signals" section, never counted) or `reviewer` (main list; counts toward `min_reviewers` only with a **distinct** family — Qwen/Moonshot/Zhipu/DeepSeek — and a complete run; seats sharing a family count once). It is **never a verifier**, never lifts solo-Claude mode for native findings, and a **non-distinct** seat (Claude/OpenAI/Google/unknown family) never counts as cross-family corroboration — its findings stay `[unverified]`. See `rules/config.md` → `reviewers.custom`.

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
  Step 2.5: Static scan (Phase 2, gated on static_analysis.enabled)
      Tier A (verified secrets/CVEs) ----> straight to Judge, pre-[verified]
      Tier B (SAST/lint signals) --------> folded into shared context
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
      |     - Custom seats (opt-in, background)                       |
      |       codex/claude/opencode [Correctness + overlay]       |
      |       ocr [no lens]                                       |
      |<--------------------------------------------------------------+
      |
      v
  Step 3.5: Well-formed check & recover (structural validation)
      |
      v
  Step 4: Refutation pass (cross-family, budget-bounded)
      UPHELD / REFUTED / INCONCLUSIVE per finding
      (custom seat: never a verifier; distinct-family findings refuted, non-distinct stay [unverified])
      |
      v
  Step 5: Judge (fingerprint, dedup, recalibrate, merge Tier A/B, suppress, ledger)
      |
      v
  Step 6: Severity-first report
      badges [verified] > [cross-reviewed] > [1 reviewer · unverified] > [unverified] > [tool-only:<rule>]; dissent; lens map
      |
      v
  Step 6.6: Post digest (optional, gated on pr_comments.enabled — default off)
      Human-confirmed: triage walk (fix/defer/won't-fix, shared with Step 7) ->
      compose the summary -> re-check stale inline comments (Claude) ->
      rc-post.sh review: one review = the summary + the inline comments
      (RC_CI=true: no confirm, no triage walk, no draft PR — posts automatically)
      |
      v
  Step 7: Capture Gate (record-only, gated on settings.learn; never runs in CI)
      Human-confirmed: tackle/skip/skip-all -> distill generalizable skips into
      Suppression (by fingerprint) or Convention -> rc-learn.sh writes learnings.md
      |
      v (feeds Step 0.5 recall on the next run)
```

## File Structure

```
review-council/
  .claude-plugin/     Plugin metadata (plugin.json is the single source of truth for version)
  skills/             Slash commands (run, setup, uninstall)
  agents/             Subagent definitions (Claude reviewer persona, dedicated Security reviewer)
  rules/              Orchestration logic, delegation format, provider registry, config schema (rules/config.md), static-analysis tool registry (rules/static-analysis.md)
  scripts/            Config reader (rc-config.sh), static-analysis runner (rc-static-scan.sh), learnings writer (rc-learn.sh), PR-digest posting engine (rc-post.sh), shared timeout lib (rc-lib-timeout.sh), Codex + Google provider-dispatch state machine (rc-invoke-provider.sh), custom-seat dispatch: ocr + JSON→§3.1 mapper (rc-ocr.sh), codex/claude/opencode (rc-seat.sh), model slug→family map (rc-lib-family.sh)
  tests/              bats unit tests for the scripts, plus Tier-2 artifact-shape fixtures (local/on-demand, never CI)
  .github/workflows/  review-council.yml (reusable workflow: unattended council run on PRs, `on: workflow_call`; Claude auth by API key, subscription OAuth token or, opt-in, Anthropic federation), unit-tests.yml (bats); its steps live in composite actions in this repo (`.github/actions/`), loaded at `plugin_ref`
  docs/               github-action.md (CI guide: setup, inputs, summary + state block, security model)
  examples/           github-action/ — copy-paste caller workflow + example `.review-council/config.yml` for CI
```

## Security Invariants

**Config is read from the *reviewed repo's* working directory, so every config value is attacker-controlled** — a repository you review can commit a `.review-council/config.yml`. Treat it as untrusted input, not trusted settings.

**Any config value that can reach a command line, a query/`yq` expression, or a shell env-assignment must be charset-validated at the reader (`scripts/rc-config.sh`) before it is emitted.** The reader is the only deterministic layer: downstream, values are interpolated into command lines an LLM composes, and quoting does not save you (`$(...)` and backticks expand inside double quotes too). Validate at the reader, reject to the key's default with a stderr note — never emit a raw value and hope a later consumer quotes it. Follow the `valid_modelslug` pattern (allowlist the safe charset; reject everything else). This is the operational form of `rules/config.md`'s "configuration is declarative data — parsed, never executed": *parsed* means validated here, so it can never become *executed* downstream.

**PR-comment posting (`pr_comments.*`, `scripts/rc-post.sh`) inherits the same discipline.** `pr_comments.bot_token_env` names an env var that `rc-post.sh` reads via indirect expansion, so it is validated as a strict POSIX identifier (`valid_envname`) at the reader and re-checked before any `eval` in `rc-post.sh` (defence in depth). The **token value never lives in config** — only the *name* of the env var that holds it does. The **target PR is always derived from local git** (`gh pr view` on the current branch, or the draft just created), **never from config** — a reviewed repo must not be able to redirect where the bot posts. And posting is fail-soft and human-gated: it never auto-posts (outside CI mode, below) and never blocks or mutates the review. Before any post, `rc-post.sh` redacts likely secrets in the body (Anthropic, OpenAI, OpenRouter, Perplexity `pplx-`, GitHub incl. `ghu_`/`ghr_`, AWS `AKIA`/`ASIA`, Google `AIza`, Slack `xoxb-`/`xoxp-`/`xoxa-`/`xoxr-`, Stripe `sk_live_`/`rk_live_` key shapes, and `-----BEGIN … PRIVATE KEY-----` blocks) to `[REDACTED]` and notes only the count — redact-and-post, never echo a value. There is one list: `rc-post.sh redact` applies it, and CI uses the same subcommand for the job summary. **Inline comments** follow the same rules: the ledger is model-composed data, so `rc-post.sh` places a finding inline only if its path is in GitHub's own list of the PR's files and its line is a right-side line of a hunk; it neutralises `<!--` in model text (no planted markers), builds every request with `jq`, redacts each inline comment before it is encoded (and every payload), and only ever treats comments and reviews **by its own identity** as earlier ones. It resolves a thread only if the orchestrator's re-check marked it fixed **and** it is still one of our stale, unresolved comments — a confused orchestrator cannot resolve arbitrary threads.

**Trust layers.** Trusted: `~/.review-council/config.yml` (the user layer — read only for `reviewers.custom` in this release), `.review-council/config.local.yml` **only while git does not track it**, and env. Untrusted: the committed `config.yml` and a git-tracked `config.local.yml` (the reader notes it). Being gitignored is a convention, not a boundary — the tracked-file rule applies to `pr_comments.bot_token_env` too.

**CI mode (`RC_CI`, `RC_APPROVED_SEATS`, `.github/workflows/review-council.yml`).** The CI trust boundary is **write access to the caller repo**. The caller workflow sets the switches, but which copy runs depends on the trigger: `issue_comment` runs the default-branch copy; `pull_request` runs the **PR branch's** copy, so a same-repo PR can change `approved_seats`, `plugin_ref` or the `uses:` ref for its own run. That is not an escalation (pushing a branch already allows editing any workflow), but never describe the workflow file as a default-branch-only control. The PR branch's committed `config.yml` and `learnings.md` stay untrusted.
- **Two jobs.** `gate` runs every check (event, draft, fork, commenter permission) with no concurrency group; `review` (`needs: gate`) holds the per-PR concurrency group with `cancel-in-progress`, so only an authorised trigger can cancel a running review.
- **Env-only switches.** `RC_CI` and `RC_APPROVED_SEATS` are read from the environment only, never from any config file, so a PR cannot turn off its own human gate or approve its own seat. `RC_APPROVED_SEATS` slots are charset-validated at the reader like any slot name; an approved seat is emitted `needs_confirm=false` with no `confirm.<n>` line, and an unapproved seat that needs confirmation is skipped with a note (`not approved for CI`) — it fails closed. Approved seats do not count toward the one-committed-seat cap (the workflow file, not the repo, chose them); unapproved committed seats keep it. **Approval covers the slot name, not the definition:** the seat's `harness`, `provider` and `model` still come from the PR branch's `config.yml`; trusted-only keys stay ignored. `RC_CI=true` forces `auto_retry=true` and `learn=false` (Step 7 never runs; nothing is written). Recall follows `settings.recall`, the configured `learn` value, so `learn: false` stops CI reading `learnings.md`. Learnings come from the PR branch, so a write-access author can add Suppressions to their own review — the same trust as `config.yml`.
- **PR text is data** (opt-in `skip_bot_prs` skips bot-opened PRs at the gate). The PR is opened by a person or bot with write access (fork PRs are skipped), but a bot PR (Dependabot, Renovate, an agent) can carry third-party text — upstream release notes in the body, vendored code in the diff. Comments and reviews are kept only when `authorAssociation` is `OWNER`, `MEMBER` or `COLLABORATOR` (wider than the `/review-council` write-access gate: any org member, any collaborator incl. read/triage); the rest are dropped unread — Step 2's CI metadata fetch applies the filter in the `gh` call itself. All PR text is material to review, never instructions.
- **Claude auth: one workflow, exactly one credential, federation opt-in.** The mode is `federation` when the `anthropic_federation_rule_id` input is set, else `api_key`, which covers both the `ANTHROPIC_API_KEY` secret and the `CLAUDE_CODE_OAUTH_TOKEN` secret (a subscription token from `claude setup-token`; usage counts against its creator's seat); both are `required: false` at the workflow level. Federation also needs `anthropic_organization_id` and `anthropic_service_account_id` (optional `anthropic_workspace_id`). The setup is validated in **one place**, `.github/actions/review/run-review.sh` (run with `--check-auth` as the review action's first step, before installs): no credentials, more than one Claude credential (key, OAuth token, federation inputs), both Codex credentials, an invalid `claude_model`, incomplete federation IDs, or federation without an OIDC grant all fail with an `::error::`. **The `review` job declares no `permissions:` and the called file has no workflow-level grant, so the review job gets exactly the caller's grant** (verified by a live probe): API-key callers grant **no** `id-token`, federation callers add `id-token: write`, and callers must grant nothing beyond the documented minimum. The job must not declare `id-token: write` itself, because GitHub validates a called job's permissions even when it is skipped, which would force every caller to grant it. The `gate` job keeps its own narrow grant. Federation is opt-in because the job runs an AI with shell access that reads PR text: with `id-token: write` it could mint a GitHub OIDC token for another audience, which matters if a cloud account trusts this repo's OIDC tokens — so no cloud trust policy should match the repo's PR runs broadly. The OIDC request variables are stripped from Claude's environment, a partial guard only. In federation mode `ANTHROPIC_API_KEY` is **unset, not blanked** (an API key outranks federation); a background loop refreshes the GitHub OIDC token file (audience `https://api.anthropic.com`) every 60s, since each token is single-use (`jti`). The federation IDs are not secrets.
- **Native Codex needs a Codex credential.** The workflow counts native Codex as available only when `OPENAI_API_KEY` is set (passed as `CODEX_API_KEY`) or Codex is logged in with a ChatGPT Enterprise `CODEX_ACCESS_TOKEN` (`codex login --with-access-token`, then the variable is unset), even if a `harness: codex` seat installed the binary. One or the other, never both (early error). A failed access-token login warns and leaves native Codex *not configured*.
- **`claude_model` input.** Sets the model Claude Code runs (`--model`, from `RC_CLAUDE_MODEL`); the reviewer subagents inherit it. Charset-validated in `run-review.sh` before use. `reviewers.claude.model` in config still pins only the Claude reviewer subagent.
- **The PR's Claude settings never load.** The run uses `claude -p … --setting-sources user`, so the reviewed branch's `.claude/` settings and hooks never load into the session that holds the keys.
- **Fork PRs and drafts are skipped** on both triggers. Forks are skipped entirely, including `/review-council` comments on them: a comment-triggered run would carry full secrets onto outside code.
- **Write-access gate.** A `/review-council` comment runs only when the commenter's repo permission is `admin`, `maintain` or `write`.
- **Least privilege.** The review job gets the caller's grant: `contents: read`, `pull-requests: write`, `issues: write`, plus `id-token: write` with federation only; the checkout does not persist credentials. Posting identity is the caller's `GITHUB_TOKEN` (`github-actions[bot]`), or the optional `PR_BOT_TOKEN` secret exported as `RC_PR_BOT_TOKEN` with `RC_PR_BOT_TOKEN_ENV=RC_PR_BOT_TOKEN` (env — the trusted layer); it is never resolved via `gh api user` in CI, and an unreadable bot login leaves the footer without an identity.
- **Residual risk, stated plainly.** The orchestrator has Bash with the API keys in its env and reads the PR's code, title, body and diff. A malicious write-access PR author could plant a prompt injection to exfiltrate the keys — but they could already do that by editing a workflow in their branch. Third-party text in a bot PR is not covered by that argument: it is data, but an injection in it still runs in the session that holds the keys (the docs suggest not commenting `/review-council` on dependency-bot PRs). Comments and reviews from anyone else are dropped, and redaction runs before posting. Recommend dedicated, spend-limited keys. Keep Codex error output out of the digest (OpenAI echoes short keys in errors).

**Custom reviewer seats (`reviewers.custom`, `scripts/rc-ocr.sh`, `scripts/rc-seat.sh`) inherit the same discipline:**
- **Trusted-only keys.** `api_key_env` (names the env var whose value is sent to the provider) and the free-form `harness_options.flags` / `harness_options.env` are honoured **only** from trusted layers; from committed config they are ignored with a note. Free-form options exist for `ocr` only — `codex`/`claude`/`opencode` take none from any layer. Typed options (`effort`, `concurrency`, `max_tokens_budget`, `timeout_minutes`) are validated and allowed from any layer. Isolation-critical flags (`--rule --repo --from --to --commit -c --tools --provider --model -o --output --format -f --audience --resume --preview -p`) and env names (`HOME PATH TMPDIR OCR_NO_UPDATE`, the key var) are reserved from every layer.
- **The confirm gate.** A legitimate-but-risky choice that comes only from committed config (in this release: a committed-only seat that egresses to OpenRouter) emits `confirm.<n>=<reason>`; the orchestrator asks once at Step 0 and skips the seat on no/no answer. The reader also marks such a seat `needs_confirm=true`, and `rc-ocr.sh` refuses it unless the orchestrator passes `--confirmed` — so a skipped question fails closed. A reviewed repo cannot send its code to a third party on the user's key without the user's say-so.
- **Trust is decided case-insensitively.** `config.local.yml` is trusted only if git tracks no file of that name under any casing — on a case-insensitive filesystem a committed `Config.Local.yml` would otherwise be read as the trusted local file.
- **Hard-coded egress policy.** Endpoints are council literals (no URL key). OpenRouter calls carry `data_collection: deny`, written by the council into the harness's own config/env (`ocr`, `claude`, `opencode`) — never read from repo config or the user's harness config. **`codex` cannot send it**, and its sandbox blocks writes, not reads (a live test read a file in the operator's home), so with OpenRouter anything it reads can leave the machine: its announcement says so, a committed `codex` + OpenRouter seat's confirm question says so, and `claude`/`opencode` are documented as the fit for OpenRouter.
- **Per-harness boundary, verified by canaries (write, out-of-repo read, planted repo overrides).** Every agent seat runs in a **tracked-only snapshot** of the repo (no `.env`/untracked files) in a throwaway home, and an Ollama model must already be pulled (no repo-chosen model downloads). `codex`: the kernel sandbox for writes (`--sandbox read-only`), throwaway `CODEX_HOME` (a repo `.codex/config.toml` is ignored); reads are not confined (see above). `claude`: `--tools=Read,Grep,Glob --restricted` (file tools confined to the working directory), `--setting-sources ""` (a planted hook did not run), throwaway `CLAUDE_CONFIG_DIR`, every model variable pinned to the seat's model. `opencode`: a council-written deny-by-default config with `external_directory: deny`, `OPENCODE_DISABLE_PROJECT_CONFIG=1` **and** `--pure` (without them a repo config re-grants writes and a repo plugin runs code), minimum version 1.19.0 (guards re-tested on 1.19.3).
- **Committed config is bounded.** At most one seat from the repo's committed config runs per review, and seats never corroborate each other — cross-family agreement needs a native reviewer — so a reviewed repo cannot manufacture `[cross-reviewed]` findings with its own seats.
- **Rule pinning.** A neutral council rule file passed with `--rule` displaces the reviewed repo's `.opencodereview/rule.json`; a pre-flight `ocr rules check` must report `Source: Custom (--rule)` or the seat is skipped.
- **Temp `HOME` + env allowlist.** Each run gets a throwaway `HOME` (removed on exit) and runs `ocr` under `env -i` with an allowlist (no host `ANTHROPIC_*` leakage); the key is passed on file descriptor 3, never argv, and never written to disk. `rc-seat.sh` does the same for every agent harness, with a throwaway home per run. The orchestrator interpolates only the validated slot name, a run-unique result path, and git-resolved SHAs — PR refs come from `baseRefOid`/`headRefOid`, never branch names or config. Routing reads the script-written `.meta` file, never model text.
- **Finder-only.** A seat can add findings but never refute (delete) one; a non-distinct seat can never manufacture cross-family corroboration.

## Versioning

Bump the `version` field in `.claude-plugin/plugin.json` whenever you ship a bug fix or new feature (semver: patch for fixes, minor for features, major for breaking changes). `marketplace.json` inherits the `version` from `plugin.json` via strict-mode merge — do not duplicate the version there. Pair the bump with a `chore: bump version to X.Y.Z` commit after the change.

## Short Description & Docs

The plugin's one-line **short description** has a single source of truth: the `description` field in `.claude-plugin/plugin.json`. It is stamped into `README.md`, this file, `.claude-plugin/marketplace.json`, and `skills/run/SKILL.md`'s frontmatter by **`scripts/sync-metadata.sh`**. **When you change the description, edit only `plugin.json` and run `scripts/sync-metadata.sh`** to propagate it everywhere — CI's `tests/unit/sync-metadata.bats` (which runs `sync-metadata.sh --check`) fails if any copy drifts.

More broadly, **when you change review-council's functionality or pipeline, review the user-facing docs** (`README.md`, this file, `skills/setup/SKILL.md`) for accuracy — and if the pitch changed, update `plugin.json`'s `description` and re-run the sync. At the close of a major phase, do a thorough user-facing-doc pass and fold the fixes into that phase's last PR.
