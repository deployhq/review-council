# Run Review Council in GitHub Actions

Review Council can review your pull requests on its own, in GitHub Actions, with no human in the loop. It runs the same council as `/review-council:run` and posts one **review-digest comment** on the PR.

You call it as a **reusable workflow** from your own repo. Your repo's secrets pay for the models. Your repo's `GITHUB_TOKEN` posts the comment.

- [How it works](#how-it-works)
- [Set it up](#set-it-up)
- [Configure it](#configure-it)
- [The digest comment](#the-digest-comment)
- [Security model](#security-model)
- [Troubleshooting](#troubleshooting)

## How it works

**When it runs.**

- A pull request is **marked ready for review**. Drafts are skipped.
- Someone **comments `/review-council`** on a PR. The commenter must have write access (admin, maintain or write). The workflow reacts with 👀 so you know it started.

Either way, the PR must be open and not a draft. It never runs on PRs from forks. See [Fork PRs](#fork-prs).

**What it does.**

1. Checks out the PR's branch.
2. Installs Claude Code, the Review Council plugin (from a pinned ref), `yq`, and the Codex CLI if you gave it an OpenAI key.
3. Runs headless Claude Code: `claude -p "/review-council:run <PR number>"`.
4. Posts the digest on the PR, or updates the one already there. Re-runs never add a second comment.
5. Appends the final report to the job summary.

**Which reviewers run.**

| Reviewer | Needs |
|---|---|
| Claude + the dedicated Security reviewer | `ANTHROPIC_API_KEY` (required) |
| Codex | `OPENAI_API_KEY` |
| Perplexity | `PERPLEXITY_API_KEY` |
| Custom seats (optional) | a seat in `config.yml`, approved in the workflow, plus its key. See [Custom seats in CI](#custom-seats-in-ci). |

Claude and Security are the same model family. With only `ANTHROPIC_API_KEY`, the council runs in single-reviewer mode: findings are not cross-checked by a second family. **Add `OPENAI_API_KEY`** to get the real council: Codex reviews, and it double-checks the other reviewers' findings.

The Google slot (`agy` / `gemini`) is not set up in CI.

**Time and cost.** In our local test, a headless run on a tiny diff took about **3.5 minutes** and cost about **$3 on the Claude side**. Real PRs cost more: cost grows with the size of the diff and the number of reviewers. Codex, Perplexity and seat costs are billed separately by each provider. The run is bounded by the existing caps (`run_budget_seconds`, per-reviewer timeouts, turn limits). There is no separate spend cap.

**Concurrency.** One run per PR. If a new run starts for the same PR (a second `/review-council`, or another trigger), the older run is cancelled.

**It never blocks a merge.** The digest is advisory. The workflow does not fail the check when it finds problems. If you want a gate, read the [state block](#the-hidden-state-block).

## Set it up

You need admin access to the repo, an Anthropic API key, and (recommended) an OpenAI API key.

### 1. Add the secrets

In your repo: **Settings → Secrets and variables → Actions → New repository secret**. Organization secrets work too.

| Secret | Required | What it does |
|---|---|---|
| `ANTHROPIC_API_KEY` | yes | Runs Claude Code, the Claude reviewer and the Security reviewer. |
| `OPENAI_API_KEY` | no (recommended) | Enables Codex. The workflow passes it to Codex as `CODEX_API_KEY`, which is the variable Codex reads in non-interactive mode. Without it, Codex is not installed. |
| `OPENROUTER_API_KEY` | no | Key for a custom seat on OpenRouter. |
| `PERPLEXITY_API_KEY` | no | Enables the Perplexity reviewer. |
| `PR_BOT_TOKEN` | no | A GitHub token to post as your own App or bot instead of `github-actions[bot]`. See [Who posts](#who-posts). |

Use keys dedicated to this workflow. Give each one a spend limit at the provider.

### 2. Add the caller workflow

Copy [`examples/github-action/review-council.yml`](../examples/github-action/review-council.yml) to `.github/workflows/review-council.yml` in your repo:

```yaml
name: Review Council

on:
  pull_request:
    types: [ready_for_review]
  issue_comment:
    types: [created]

permissions:
  contents: read
  pull-requests: write
  issues: write

jobs:
  review:
    uses: deployhq/review-council/.github/workflows/review-council.yml@main
    with:
      approved_seats: ""        # e.g. "kimi" — see "Custom seats in CI"
      run_budget_seconds: 900
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
      PERPLEXITY_API_KEY: ${{ secrets.PERPLEXITY_API_KEY }}
      # PR_BOT_TOKEN: ${{ secrets.PR_BOT_TOKEN }}   # optional: post as your own App or bot
```

Things to know:

- **Keep the `permissions:` block.** A reusable workflow can never get more permissions than its caller grants. Without `pull-requests: write` and `issues: write`, the run cannot post. Comments on a PR are issue comments, so `issues: write` is needed.
- **Merge it to your default branch first.** GitHub runs `issue_comment` workflows only from the default branch. Until the file is on `main` (or whatever your default is), `/review-council` does nothing.
- **Don't add `concurrency:` with `cancel-in-progress` to the caller.** Every PR comment triggers the caller, so it would cancel a running review. The reusable workflow already allows one run per PR.
- **Two refs, two jobs.** `@main` in `uses:` pins the *workflow*. The `plugin_ref` input pins the *plugin* it runs. Pin both to a tag or commit SHA if you want fully repeatable runs.
- **Want a review on PRs that are opened non-draft?** `ready_for_review` fires only when a draft becomes ready. Add `opened` to the `pull_request` types. Add `synchronize` to review every push (this costs a run per push; the newer run cancels the older). Drafts are skipped on every trigger, including `/review-council` comments.

### 3. Try it

Open a PR, or comment `/review-council` on an existing one. Watch the run in the **Actions** tab. The digest appears on the PR when the run finishes.

### Inputs

| Input | Type | Default | What it does |
|---|---|---|---|
| `approved_seats` | string | `""` | Comma-separated custom-seat slot names that may run. See [Custom seats in CI](#custom-seats-in-ci). |
| `run_budget_seconds` | number | `900` | Soft time budget for the whole review. When spent, the council skips or shrinks the double-check pass and still posts a report. |
| `plugin_ref` | string | `main` | Git ref of `deployhq/review-council` to load the plugin from. |
| `claude_code_version` | string | a pinned version | Version of `@anthropic-ai/claude-code` to install. |
| `codex_version` | string | `0.163.0` | Version of the Codex CLI to install. |
| `static_analysis` | boolean | `true` | Run the static-analysis scan (secrets, CVEs, lint) before the review. Missing tools are skipped and noted; the run never stops to ask. |

## Configure it

### Where settings come from

Precedence is per key: **workflow env > `config.yml` > built-in default.**

- **`.review-council/config.yml`** is read from the **PR's branch**. A PR can change the roster, lenses or settings and see the effect in its own review. Treat it like any other code in the PR: it is untrusted, so security-sensitive keys are ignored there (see [Security model](#security-model)).
- **The workflow** sets env vars, which win over the file. The reusable workflow always sets:

  | Env | Value | Effect |
  |---|---|---|
  | `RC_CI` | `true` | "No human is present." Never asks a question. Posts without a confirm step. Skips the triage walk and the learnings capture. Never opens a draft PR. |
  | `RC_PR_COMMENTS` | `true` | Posting is always on in CI. You don't need `pr_comments.enabled` in `config.yml`. |
  | `RC_RUN_BUDGET` | `run_budget_seconds` input | Overrides `settings.run_budget_seconds` from the file. |
  | `RC_STATIC_ANALYSIS` | `static_analysis` input | Overrides `static_analysis.enabled` from the file. |
  | `RC_APPROVED_SEATS` | `approved_seats` input | Pre-approves the named seats. |

  `RC_CI=true` also forces `settings.auto_retry=true` (a failed reviewer is retried once without asking) and `settings.learn=false`. `.review-council/learnings.md` is still **read** (its conventions and suppressions apply), but CI never **writes** to it.

- **`config.local.yml` is not used in CI.** It is gitignored, so it is not in the checkout.

Start from [`examples/github-action/config.yml`](../examples/github-action/config.yml). The full schema is in [`rules/config.md`](../rules/config.md).

### Custom seats in CI

A custom seat is an extra reviewer: a model you choose, run through a harness CLI. Locally, a seat that sends code to OpenRouter and comes only from the committed `config.yml` asks you once before it runs. In CI there is nobody to ask, so the **workflow** gives that approval instead.

1. Name the seat in `.review-council/config.yml`:

   ```yaml
   reviewers:
     custom:
       kimi:                              # the slot name
         harness: claude                  # Claude Code as the harness (already installed in CI)
         provider: openrouter
         model: moonshotai/kimi-k2.7-code
         role: reviewer                   # or signal (the default)
   ```

2. Approve it in the caller workflow, using the same slot name, and pass the key:

   ```yaml
       with:
         approved_seats: "kimi"
       secrets:
         OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
   ```

A seat that needs approval and is not in `approved_seats` is skipped. The report says: `kimi: skipped — not approved for CI (add it to approved_seats)`. The PR branch cannot approve its own seat: approval lives only in the workflow file, which runs from your default branch.

Limits in CI:

- **Approved seats are not capped.** Every seat in `approved_seats` runs, so `approved_seats: "qwen,kimi"` runs both. Unapproved committed seats keep the local rules: at most one runs per review, and a seat that needs approval is skipped because nobody can confirm it.
- **Use `harness: claude` (or `opencode`) for OpenRouter.** Don't use `codex` with OpenRouter: it cannot send `data_collection: deny`, and its sandbox does not stop it reading files (including its own key).
- **No local models.** `provider: ollama` needs a model on the machine; the runner has none.
- **The key is `OPENROUTER_API_KEY`.** `api_key_env`, `harness_options.flags` and `harness_options.env` are ignored from committed config. Typed options (`effort`, `timeout_minutes`, `max_turns`, …) still work.
- The seat's harness is installed only when the config names it.

Seat roles, families and egress: see [Custom reviewer seats](../README.md#custom-reviewer-seats) in the README.

## The digest comment

One comment per PR. A re-run edits it in place.

It has three sections:

1. **What was found, and by whom.** Findings by severity (Critical, Important, Suggestions), with confidence badges and the reviewers that raised them. A reviewer that failed or was skipped is named here. It never fails silently: if every reviewer fails, a short "review could not run" digest is still posted, with status `degraded` and the failed reviewers named.
2. **What the council decided.** What was upheld, refuted or left unverified by the double-check pass.
3. **What was fixed.** In CI this is one line: `Not triaged — automated CI run.`

It ends with a footer:

```
---

<sub>Review done with [Review Council](https://github.com/deployhq/review-council/) · github-actions[bot]</sub>
```

With `PR_BOT_TOKEN`, the footer names your bot's login instead. If that login can't be read, the footer is just `Review done with Review Council`, with no identity.

### The hidden state block

The comment starts with two hidden HTML comments. They don't render on GitHub. They are there for tools and agents:

```
<!-- rc:report -->
<!-- rc:state {"v":1,"sha":"<40-hex sha>","status":"findings","critical":0,"important":2,"suggestion":3,"degraded":[]} -->
```

| Field | Meaning |
|---|---|
| `v` | Format version. Currently `1`. |
| `sha` | The commit that was reviewed (`git rev-parse HEAD` of the checkout). |
| `status` | `clean`, `findings` or `degraded`. See below. |
| `critical`, `important`, `suggestion` | Number of findings at each severity. |
| `degraded` | Reviewers that failed or were skipped because of an error (bad key, quota, timeout). |

`status` is decided in this order:

- `degraded` — at least one configured reviewer failed. **Not clean**, even with zero findings.
- `findings` — at least one Critical or Important finding.
- `clean` — otherwise. Suggestions alone count as clean.

**Reading it from an agent** (for example, an agent that opens PRs and waits for a clean review):

1. List the PR's issue comments (`GET /repos/{owner}/{repo}/issues/{number}/comments`). This returns comments from every author, bots included.
2. Find the comment whose body starts with `<!-- rc:report -->`.
3. Parse the JSON on its second line, between `<!-- rc:state ` and ` -->`.
4. Treat the PR as reviewed and clean only if `sha` equals the PR's current head SHA **and** `status` is `clean`.

If `sha` is older than the head, the review is stale. Comment `/review-council` (with a token that has write access) to run it again.

## Security model

### Fork PRs

PRs from forks are ignored completely. That includes `/review-council` comments on them. A fork PR's `pull_request` run gets no secrets, and a comment-triggered run would run with full secrets on code from outside your org. If your team and bots push branches to the repo itself, this only affects outside contributors.

### Triggers, permissions and data

**Who can trigger.** The `pull_request` trigger runs for branches pushed to your repo. The `/review-council` trigger checks the commenter's permission (`GET /repos/{owner}/{repo}/collaborators/{user}/permission`) and runs only for `admin`, `maintain` or `write`.

**Job permissions.** `contents: read`, `pull-requests: write`, `issues: write`. The checkout does not keep credentials (`persist-credentials: false`). The run can read code and post a comment. It cannot push.

**The PR's Claude settings never load.** Claude Code runs with `--setting-sources user`, so the reviewed branch's `.claude/` settings and hooks are never loaded into the session that holds the keys.

**Trusted vs. untrusted config.** The workflow file is the trusted place. It runs from your default branch and chooses the switches (`RC_CI`, `RC_APPROVED_SEATS`, …). The PR branch's `config.yml` is untrusted: it can tune the review, but it cannot approve a seat, set `api_key_env`, set free-form seat flags, or set `pr_comments.bot_token_env`. The target PR comes from the checkout, never from config.

**Secret scan before posting.** Before the digest is posted, likely secrets are replaced with `[REDACTED]`: Anthropic (`sk-ant-…`), OpenAI (`sk-…`, `sk-proj-…`), OpenRouter (`sk-or-…`), GitHub (`ghp_…`, `gho_…`, `ghs_…`, `ghu_…`, `ghr_…`, `github_pat_…`) and AWS (`AKIA…`, `ASIA…`). The comment is still posted. The log shows only how many values were redacted, never the values.

**Where your code goes.** The PR's diff and the files the reviewers read are sent, under **your** keys, to:

- **Anthropic** — always (Claude Code, the Claude and Security reviewers).
- **OpenAI** — if `OPENAI_API_KEY` is set (Codex).
- **Perplexity** — if `PERPLEXITY_API_KEY` is set.
- **OpenRouter and the model's host** — for an approved OpenRouter seat (with `data_collection: deny`).
- **GitHub** — the digest comment and the job summary.

Static-analysis tools run on the runner. `trufflehog` checks found credentials against their provider; drop it from `static_analysis.tools` to stop that.

**Residual risk.** The orchestrator is Claude Code with a Bash tool, and the API keys are in its environment. It reads the PR's diff, which could contain instructions planted to steer it. This is bounded: only people with write access can start a run, by pushing a branch or commenting. That is the same posture as other AI PR-review actions. Use dedicated keys with spend limits, and don't use the workflow on repos where people you don't trust have write access.

### Who posts

By default the comment posts as `github-actions[bot]`, using the calling repo's `GITHUB_TOKEN`. No GitHub App is needed.

To post as your own GitHub App or bot user, pass a token as the optional `PR_BOT_TOKEN` secret. The workflow exports it as `RC_PR_BOT_TOKEN` and points `pr_comments.bot_token_env` at it. The token needs write access to issue and PR comments on the repo. Unset means `github-actions[bot]`.

For a bot user, store its fine-grained token as a repo or org secret. For a GitHub App, an installation token (for example from `actions/create-github-app-token`) works, but it expires after an hour and GitHub may refuse to pass a token between jobs as a job output, so test this in your setup.

## Troubleshooting

**The run fails at once with a permissions error, or never posts.** Check the `permissions:` block in your caller workflow. It needs `pull-requests: write` and `issues: write`.

**`/review-council` does nothing.** The caller workflow must be on your default branch. The commenter needs write access. The PR must be open, not a draft, and not from a fork. The 👀 reaction appears only once these checks pass.

**A missing or wrong secret.** `ANTHROPIC_API_KEY` is required; without it the run fails. Any other missing key just drops that reviewer. A bad key shows up in the digest: the reviewer is listed in `degraded` and the status is `degraded`.

**Codex shows as degraded.** Check `OPENAI_API_KEY` in your secrets. The workflow passes it to Codex as `CODEX_API_KEY`; Codex does not read `OPENAI_API_KEY` in non-interactive mode. A bad key fails in seconds, and the review carries on without Codex.

**The report says `stopped at budget`.** The run used up `run_budget_seconds`. Some findings were not double-checked and are tagged `[unverified]`. Raise `run_budget_seconds` in the caller workflow.

**A fork PR got no review.** That is by design. See [Fork PRs](#fork-prs).

**A seat was skipped.** `not approved for CI` means its slot name is missing from `approved_seats`. Other notes (missing key, wrong harness, a second committed seat) are in the report's Pipeline line.
