# CC-Cowork-Workflow — Claude Code external executor (Codex) orchestration

**Scope:** Claude Code only. Depends on the `/codex:*` plugin, which other agents (Cursor, standalone CLIs, …) do not have. Kept out of `AGENTS.md` on purpose — that file is tool-neutral. `CLAUDE.md` only points here and says *when* to load this file; the rules live here so they don't sit in every-session context.

An **external executor** is a delegated coding/review backend (currently **Codex**). The rules below are written executor-neutral, so another backend could be slotted in later by swapping the subagent's runtime resolution and command prefix.

## Executors

| Executor | Plugin | How Claude reaches it | Cmd prefix |
| --- | --- | --- | --- |
| **Codex** | `codex-plugin-cc` (official) | the `codex-run` subagent → `scripts/codex-companion.mjs` | `/codex:*` |

> Neither the plugin version nor the companion path is written down anywhere: `codex-run` resolves the live install at call time from `$CLAUDE_PLUGIN_DATA`, skipping orphaned versions. Model and effort are not pinned here either — unset means Codex's own configured default, which is the right answer on a machine you did not configure. Pin them per call, only when a specific run needs it.

## Roles

- **Claude orchestrates** the whole task: plan → get user approval → implement → review → verify. Claude is always the driver. Never let an executor be the entry point — a cold `/codex:rescue "<task>"` with no framed task and no agreed plan bypasses your control and is not allowed.
- **The executor executes** only inside the implementation phase, on a single, well-defined unit handed to it.
- **Reviewer ≠ author.** Whoever did not write the code reviews it. Executor writes → Claude reviews the returned diff. Claude writes → delegate the review to the executor (`/codex:review`; add `:adversarial-review` for business-invariant or concurrency code).

## Flow

1. Frame the task and plan it (the planning phase).
2. Write a short plan/spec of what will be built.
3. **After the plan is written, summarize it in Chinese for the user** so they know exactly what is planned, then get explicit approval. This Chinese plan summary is the user's approval gate — **do not start implementation until the user approves it.**
4. Begin implementation.
5. Delegate one defined unit to the executor through the **`codex-run` subagent** — see the next section. Never inline a prompt into a Bash call, and never hand the work to `codex:codex-rescue`.
6. Claude reviews the returned diff **and** runs the project's verification (the deterministic gate: lint / type / test). Fail → return to step 5 (executor re-work) or fix directly; pass → step 7.
7. Commit and finish per the project's Verify & Commit rules.

## Delegating one unit — the only supported path

`.claude/agents/codex-run.md` ships with this file. It is a courier: it launches one background Codex job, blocks on the companion's own `status --wait`, writes the result to disk, and reports paths. It never rewrites your prompt and never summarizes Codex's output.

1. **Write the prompt to a file** — `<working-dir>/codex-<unit>-prompt.md`. It **must carry the relevant project context inline** (the rules from `AGENTS.md`, any project specs/conventions, the exact files in scope): an executor cannot inherit this session's context, so unfed context is simply lost.
2. **Spawn `codex-run`** with a task text of plain `field: value` lines — `prompt-file:` and `result-dir:` are absolute paths and required; `write:` defaults to `no`; `model:` and `effort:` are omitted unless this run genuinely needs to pin them.
3. **Read the result file yourself** (`<result-dir>/codex-<job-id>.result.md`). The subagent hands you a path, not a verdict. The full record — `touchedFiles`, thread id, failure text — sits next to it in `codex-<job-id>.result.json`.
4. **`write: yes` only when the unit really is "Codex edits the repo."** Reviews, diagnosis and research stay read-only; that is the default and it should stay the common case.

Two properties make this safe to repeat, and both are worth protecting when editing this file: the prompt travels **by path, never by value**, so nothing can quietly reword it; and the result is **on disk before the subagent speaks**, so a lost or failed reply never costs you a finished job.

## Why not the plugin's own `codex:codex-rescue`

It is a deliberate one-shot forwarder, and its own definition forbids what orchestration needs: it may call `task` exactly once and is **barred from `status`, `result` and `cancel`**, so it cannot bring a background job's output back. It also **defaults to `--write`**, turns words like "continue" or "dig deeper" into `--resume-last` (silently chaining onto an unrelated earlier thread), is allowed to **rewrite your prompt** before forwarding, and **returns nothing at all** when the Bash call fails — not even a job id to recover from. Fine for a human typing `/codex:rescue` once; wrong for every step of a plan.

## When a job seems lost

- **A job still running when the Claude session ends is dead.** The plugin's `SessionEnd` hook kills this session's `queued`/`running` jobs and drops them from the job index. Relaunch the unit; never trust a partial.
- **A job that finished keeps its record on disk**, even after the index is cleaned: `$CLAUDE_PLUGIN_DATA/state/<project>-<hash>/jobs/<job-id>.json`, with the answer at `.storedJob.result.rawOutput`. Look there before concluding anything was lost — and look at `<result-dir>/codex-<job-id>.result.md` first, which is the same text the subagent already saved for you.
- **On any error, check state before retrying.** `node <companion> status --all` first: the job is usually already running or done, and a blind re-launch double-applies the work.

## Non-negotiables

- Never wave through the review/quality gate just because the executor "looks done." Executors write to disk directly, so Claude's review must be a real read of the diff — especially for business invariants and concurrency-sensitive code.
- Treat any executor's *research/claims* (not just its code) as signal, not ground truth — verify load-bearing facts (repo names, install commands, shutdown dates, `file:line` refs) with a deterministic check before acting. Decorrelated ≠ correct.
- Keep these rules in this file under repo root, pointed to from `CLAUDE.md`. Do not migrate them into `AGENTS.md` — they are Claude-Code-only by nature.
