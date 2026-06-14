# AI Agent Instructions

This file is the single source of truth for all AI coding assistants working on this project.
Tool-specific files (`CLAUDE.md`) point here.

Keep it to durable, cross-session guidance — product, rules, standards, security, handoff. Session scratch (current branch, this round's progress, temporary state) does not belong here; put it in the End-of-Session Summary or `notice.md`.

## Product

Vibe-Setup is a project-bootstrapping tool for AI-assisted development. Its centerpiece is `vibe-init.sh`, a Bash CLI that scaffolds a new project — or seeds an existing one via `--apply` — with a shared set of AI-agent instruction files (`AGENTS.md`, `CLAUDE.md`), a secrets-deny `.claude/settings.json`, and a manual test checklist, and can optionally install and initialize [Trellis](https://www.npmjs.com/package/@mindfoldhq/trellis). It targets local developer machines (macOS/Linux, Bash 3.2+), is single-user and run from the terminal, and writes only into the chosen project directory. The files under `templates/` are the durable source of truth the script copies from.

## Project Phase

<!-- A terse, kept-current snapshot of each app/package — not a log. Update in place; don't append history. -->
- **vibe-init.sh**: Built — scaffold mode (empty dir or named subfolder), optional `git init` (`--git yes|no`, default yes), `--apply` mode for existing projects (interactive file selection, `--files` to preselect a subset, hints when the target is not a git repo but never runs `git init`), optional Trellis install/init, secret-deny merge into Trellis-generated settings, `$DEVELOPER_NAME` support, `--dry-run`, `-y`. Tested manually via gitignored scaffolding dirs (`[0-9]/`); no automated test suite yet.
- **lib/apply.sh**: Built — sourced by the entrypoint; lists the managed files with their status and lets the user copy all or a chosen subset into an existing project, never overwriting (writes `<name>.template` on conflict).
- **templates/ (base, trellis)**: Authored and kept current — `AGENTS.md`, `CLAUDE.md`, `CC-Cowork-Workflow.md` (Claude Code external-executor co-work guide), `.claude/settings.json`, and the manual test-checklist HTML.

## Development Rules

### Communication Language
- User-facing output — explanations, questions, status updates, summaries, anything the user reads — must be in Simplified Chinese (简体中文).
- Software and internal work stays in English: code, identifiers, comments, commit messages, logs, test names, and your own reasoning/analysis.
- This governs presentation, not content: do not rename existing identifiers or rewrite existing English docs just to comply, and match the surrounding language of any file you edit.

### Two-Step Confirmation First
- Never start the moment a requirement is stated or changed. Every new or modified requirement first passes through an understand-and-confirm step before any code is written. The only exception is trivial mechanical actions whose intent is obvious (e.g. `git push`, fixing a typo, a one-line rename).
- **Step one — reflect and surface, always in the open before building:**
  - Judge whether the request is sound: is it safe? is it efficient? does it fit the project's scale?
  - Consider whether a better approach exists than the one asked for.
  - State your full understanding of the request, your analysis of it (risks, tradeoffs, anything ill-advised), and your concrete recommendation.
- **Step two — act on the outcome:**
  - If the request is uncertain (multiple approaches with tradeoffs, may affect other features, or ill-suited to the project's scale), wait for the user's confirmation before modifying code.
  - If there is a clearly optimal and safe path, you may proceed without waiting for confirmation — but conspicuously notify the user that you are doing so up front, and on completion state plainly what you changed and why it was the better path.
  - Push back on any request that compromises security, correctness, or runtime efficiency, even when explicitly asked.

### Dry-Run Requests
- When the user's prompt contains "dry-run", treat the request as read-only: do not modify code, files, or configuration.
- Respond with two things: (1) your complete understanding of the request, and (2) a detailed, step-by-step explanation of how you would execute it.
- Make changes only after the user explicitly asks you to proceed.

### Scope Discipline
- Each task must stay within its stated scope. Do not add, refactor, or "improve" anything outside the current request.
- If the current task logically depends on another unbuilt feature, ask the user before implementing it. Never silently introduce adjacent functionality.

### Coding Standards
- **Source of truth & persistence**: The `templates/` directory is the single source of truth for what gets scaffolded. The script copies from it and only falls back to the built-in `*_placeholder()` heredocs when a template file is missing. `TEMPLATE_FILES` in `vibe-init.sh` is the authoritative file list — keep `write_project_placeholders` and apply mode in sync with it.
- **Architecture & boundaries**: One entrypoint (`vibe-init.sh`) with sourced helpers under `lib/`. `lib/apply.sh` depends on globals and functions defined by the entrypoint and is never run standalone. Keep new logic as small, single-purpose Bash functions and reuse existing helpers (`run_cmd`, `run_in_dir`, `ensure_dir`, `info`/`warn`/`die`, `ask_value`/`ask_yes_no`) rather than re-implementing them.
- **Language / framework conventions**: Bash with `set -euo pipefail` and `IFS=$'\n\t'`; must stay compatible with macOS Bash 3.2 (no associative arrays, no `mapfile`). Quote expansions, use `[[ ]]` tests, and prefer `printf` over `echo`. Every action that writes a file or runs a command must honor `--dry-run` (route through `run_cmd`/`run_in_dir`) and skip existing files rather than overwriting them.
- **Security boundary**: The tool only scaffolds local files and runs explicitly user-gated installers (`npm install -g @mindfoldhq/trellis`). Never overwrite or merge a user's existing files — write `<name>.template` alongside instead. Never read or print secrets; the seeded `.claude/settings.json` denies reading `.env*`, `secrets/**`, and key files, and that protection must be preserved.

### Verify & Commit
- After any code change, run the project's verification (e.g. type-check / build / lint) across all affected packages.
- If verification fails, fix the errors first, then verify again.
- After verification passes, automatically commit files that were modified by the agent in the current task and belong to the current task.
- Before committing, inspect dirty files and separate current-task agent edits from unrecognized dirty files. Do not include unrecognized dirty files in commits unless the user explicitly asks to include them.
- If a dirty file's ownership or task relevance cannot be determined safely, stop and ask the user before committing.
- Group commits by coherent change unit. Do not push unless explicitly requested.
- Branching: per-feature work lands on a `feat/*` branch that merges into the mainline. Keep merged `feat/*` branches as historical archives — never delete them (local or remote).
- Commit message format (Conventional Commits):
  ```
  type(scope): short summary

  Detailed description of what changed and why.
  ```
  Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `ci`, `perf`.

### Session Handoff
- `notice.md` files are scoped by directory and record durable handoff information for the next agent.
- Root `notice.md` records global, cross-package, or cross-task project information.
- App/package notices record durable facts for that app/package: architecture, contracts, workflows, credentials, known limitations, and package-specific gotchas.
- Update the relevant `notice.md` only when the session creates or discovers information that remains useful beyond the current task or conversation. Do not record pure Q&A, routine progress, temporary decisions, or workflow session/journal details there.
- Ensure any `notice.md` you touch remains accurate and up-to-date within its directory scope.

### End-of-Session Summary
- At the end of each conversation, output a brief summary in 中文 (Chinese). This summary is user-facing.
  ```
  ## Summary
  - **Done**: work completed this round
  - **Key decisions**: tag each [user] or [self], explain the decision
  - **Commits**: list this round's commits (hash, message, files); note any dirty files left out and why
  - **Open/known risks**: issues introduced or discovered this round (omit if none)
  - **Suggested next steps**: 1-3 concrete actionable items
  ```
