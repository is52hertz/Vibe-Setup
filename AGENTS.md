# AI Agent Instructions

This file is the single source of truth for all AI coding assistants working on this project.
Tool-specific files (`CLAUDE.md`) point here.

Keep it to durable, cross-session guidance — product, rules, standards, security, handoff. Session scratch (current branch, this round's progress, temporary state) does not belong here; put it in the End-of-Session Summary or `notice.md`.

## Product

Vibe-Setup is a project-bootstrapping tool for AI-assisted development. Its centerpiece is `vibe-init.sh`, a Bash CLI that scaffolds a new project — or seeds an existing one via `--apply` — with a shared set of AI-agent instruction files (`AGENTS.md`, `CLAUDE.md`), a secrets-deny `.claude/settings.json`, and a manual test checklist, and can optionally install and initialize [Trellis](https://www.npmjs.com/package/@mindfoldhq/trellis). It targets local developer machines (macOS/Linux, Bash 3.2+), is single-user and run from the terminal, and writes only into the chosen project directory. The files under `templates/` are the durable source of truth, held as atomic `<TAG>` blocks the script assembles per run.

## Project Phase

<!-- A terse, kept-current snapshot of each app/package — not a log. Update in place; don't append history. -->
- **vibe-init.sh**: Built — the entrypoint, version `1.2.0` (`VIBE_INIT_VERSION`, stamped into every project's `.vibe-init/manifest`). Scaffold mode (empty dir or named subfolder), optional `git init` (`--git yes|no`, default yes), `--profile service|tool|ask`, `--cc-workflow yes|no` (default no), optional Trellis install/init, `$DEVELOPER_NAME` support, `--template-dir`, `--dry-run`, `-y`. Interactive order: folder, git, Trellis, profile, CC-Workflow — every question is asked before anything is written.
- **lib/block_engine.sh**: Built — assembles one concrete template set out of `templates/blocks/` and `templates/common/` into a staging directory (`materialize_template_set`), and edits `<TAG>` blocks inside an existing project file (`has_block`, `replace_block`, `remove_block`, `append_block_if_missing`). Removal is the exact inverse of the append, so toggling a feature off restores the file byte for byte.
- **lib/ui.sh, lib/prompt.sh**: Built — the gutter-and-selector interface. `ui.sh` renders messages three ways (rich gutter / plain `[vibe-init] …`) and owns the semantic state palette (`_ui_state_color`, `ui_kv_state`): `ok` green, `info` cyan, `todo` yellow, `off` dim, `bad` red, `neutral` plain (a value to be read rather than judged — a toggle's `off` must not be dimmed away, nor libelled with red). A status row is a state word in its level's color plus dim detail in parentheses, which is what gives the dense cards a reading order. `prompt.sh` supplies `ui_select`, `ui_multiselect`, `ui_input`, `ui_confirm`, each with a rich, a no-color-but-interactive, and a non-terminal path; an option record carries an optional fourth field naming the hint's state level.
- **lib/state.sh**: Built — schema-2 tab-separated manifest with file/block hashes and immutable upstream content under `.vibe-init/base/<hash>`. Empty flushes retain old records; no-op flushes preserve the manifest timestamp. Schema 1 migrates conservatively, preserving unknown hashes without inventing base text; unknown schemas are rejected. `version` means last tool used. Manifest, policy, and bases are portable project state; pending proposals, backups and locks are ignored. Never record a customized merge result as upstream.
- **lib/sync.sh**: Built — file/block three-way comparison, project-owned PRODUCT/PROJECT_PHASE defaults, explicit ownership checks before whole-file refresh, preservation of local deletion, and retirement of unchanged nonoptional upstream blocks. Optional missing blocks remain opt-outs, and absent optional template blocks may mean a variant change, so only explicit toggles remove those. Frozen reviews block further writes to that file until acknowledged; deleting a hand-out is never a completion signal.
- **lib/upgrade.sh**: Built — explicit review IDs bound to frozen upstream content and review kind, expected-current-file fingerprints, `merged`/`keep`/`converted` acknowledgements, project pause/resume, file/block ownership, portable policy, managed-path checks, per-project locks and recovery snapshots. `--pending` is read-only. Resolve and policy commands require `--apply`. Recovery refuses to overwrite later edits; a hard-killed incomplete operation needs manual inspection of `before/`. The lock is released only at process exit, never when a template staging directory is refreshed. No semantic or arbitrary-format validation is promised. File renames require explicit release migrations, not guessed similarity.
- **lib/apply.sh**: Built — the orchestrator dashboard for an existing project: environment diagnostics (vibe-init/project version, git, Trellis, platforms, CC-Workflow, AGENTS.md and CLAUDE.md format), template sync driven by lib/sync.sh with a per-file checklist that only offers files with something to do, a menu (`dashboard_actions`, split out so its ordering is testable without a terminal) that leads with whatever has work and splits every row into resident text and a reveal (`sync_menu_note`, `trellis_menu_note`, `syncall_menu_note`) shown in front of the hint on the row under the cursor — the sideways shift that causes is the point, being what makes the state impossible to miss on the one row where Enter changes something — a `copy anyway` gate (`offer_copy_anyway`) mirroring the Trellis one for when the plan finds nothing to do, Trellis lifecycle (add platform, update, CLI upgrade, pause/restore, uninstall — each judged by whether `.trellis/` is on disk afterwards, since Trellis exits 0 when the user declines at its own prompt, and followed by an offer to remove or re-add the integration block), and the CC-Workflow and Trellis-integration toggles (both record the block they write, so the tool's own edit is never mistaken for the user's). Non-interactive runs (`-y`, no TTY, `--files`, `--on-exists`) skip the menu and do the safe standard sync. A pre-`<TAG>` (legacy) AGENTS.md/CLAUDE.md target gets its .template pair plus a dedicated end-of-run format-conversion prompt for the project's AI agent — the script never rewrites the file itself. `<name>.template` is restored from the frozen pending proposal on repeated syncs. Upgrade controls expose reviews, pause/resume and ownership; unresolved review counts are shown independently from the last tool version. Template upgrade operations are snapshotted, while Trellis lifecycle and feature-toggle archives keep their existing behavior.
- **lib/trellis.sh**: Built — Trellis perception and operations: CLI and project version, configured platforms (via `trellis platforms --json`, with a directory-sniffing fallback), add platform, update, upgrade, and the two ways out: pause (`trellis ablate`, which keeps a recovery transaction under `~/.trellis` for `trellis restore`) for switching away mid-project, and uninstall (`trellis uninstall`, which deletes `.trellis/`) — asked first when `trellis_has_unprotected_data` finds tasks, specs or journals git could not give back. None of them pass `--yes`; Trellis confirms itself. `trellis_update_pending` is the single version comparison the menu reveal and the update gate both read. `trellis update` is gated on it: at the CLI's own version it only re-scans and interrogates the user about files they edited, so a matching version asks first and defaults to no.
- **templates/**: The single source of truth for what gets scaffolded. `blocks/` holds the atomic `<TAG>` fragments (`metadata`, `product`, `project_phase`, `core_rules`, `profile_setup`, `profiles/`, `integrations/`, `features/`); `common/` holds the static files (`CLAUDE.md` skeleton, `.claude/settings.json`, the test checklist). Adding a profile or an integration is dropping a file into the matching directory — nothing in the script enumerates them. `features/cc-workflow/` is the one feature that ships more than a block: the workflow document in two variants, plus `agent.md` → `.claude/agents/codex-run.md`, the subagent that document delegates through. The pair ships and retires together — a document pointing at an absent agent is worse than neither.
- **test/**: Built — `test/run.sh` runs the CLI suite (`test/dry-run.sh`), library suite (`test/units.sh`), and upgrade lifecycle suite (`test/upgrades.sh`). Upgrade regressions cover repeated/cross-release sync, explicit review decisions, portable state, pause/ownership, conservative migration and recovery.

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
- **Source of truth & persistence**: The `templates/` directory is the single source of truth for what gets scaffolded — never hard-code scaffolded content in the script. A run assembles the fragments it needs into a staging directory (`prepare_template_set`), and everything downstream copies from there, so a variant is decided in exactly one place; the built-in `*_placeholder()` heredocs are an emergency fallback for a missing template, not a second copy of it. `TEMPLATE_FILES` in `vibe-init.sh` is the authoritative file list — keep `write_project_placeholders` and apply mode in sync with it.
- **Architecture & boundaries**: One entrypoint (`vibe-init.sh`) with sourced helpers under `lib/`, each with one job: `ui.sh` renders, `prompt.sh` asks, `block_engine.sh` assembles and edits blocks, `trellis.sh` knows about Trellis, `apply.sh` is the dashboard. They depend on globals and functions defined by the entrypoint and are never run standalone. Keep new logic as small, single-purpose Bash functions and reuse the existing helpers (`run_cmd`, `run_in_dir`, `ensure_dir`, `info`/`warn`/`die`, `ask_value`/`ask_yes_no`, `ui_*`) rather than re-implementing them.
- **Language / framework conventions**: Bash with `set -euo pipefail` and `IFS=$'\n\t'`; must stay compatible with macOS Bash 3.2 (no associative arrays, no `mapfile`, no namerefs, no fractional `read -t`, and no command substitution that closes immediately inside another one — build option lists in an array instead). No runtime dependency beyond Bash, coreutils and awk. Quote expansions, use `[[ ]]` tests, and prefer `printf` over `echo`. Every action that writes a file or runs a command must honor `--dry-run` (route through `run_cmd`/`run_in_dir`) and skip existing files rather than overwriting them.
- **Terminal output**: Everything the user reads goes through `lib/ui.sh`, never a bare `printf` to stderr, and every variable it defines must exist on both branches of the color check — one that exists only in the rich branch aborts the run under `set -u` the first time output is piped. Anything interactive needs all three paths: rich, no-color-but-interactive, and non-terminal (take the default). Color carries meaning, so pick a state level (`ok`/`info`/`todo`/`off`/`neutral`/`bad`) rather than a color: `off` covers deliberately-off and absent states, `neutral` is for a value to be read rather than judged (a toggle's `off` must not be dimmed away, nor libelled with red), and red is reserved for what actually blocks the user — a card that reddens the ordinary case spends the one color that should mean "act now". The plain rendering is a contract: adding color must not change a byte of what `NO_COLOR` prints, because the dry-run suite and anything else greps that.
- **Resident vs. revealed**: a menu row has two parts, and what belongs in each is decided by whether it changes. **Resident text — the part visible on every row — states what the row is about and never varies**: `templates`, `in AGENTS.md`, `platforms, update, pause, uninstall`. It is always dim, because static context needs no semantic color. **Everything dynamic belongs in the revealed part**, shown only while the row is under the cursor: a toggle's `on`/`off`, a version, a count of pending changes. That is where the state levels apply. A row that changes its resident text as the project changes is a design error — the reader learns to re-read the whole column instead of trusting it, and the reveal stops meaning anything. Keep reveals scarce for the same reason red is scarce: if every row does something on selection, selection stops signalling.
- **Security boundary**: The tool only scaffolds local files and runs explicitly user-gated installers (`npm install -g @mindfoldhq/trellis`). Never overwrite or merge a user's existing files — write `<name>.template` alongside instead. Never read or print secrets; the seeded `.claude/settings.json` denies reading `.env*`, `secrets/**`, and key files, and that protection must be preserved.

### Verify & Commit
- After any code change, run `./test/run.sh` (CLI, library, and upgrade lifecycle suites). A new assertion has to be able to fail: break the thing it covers, watch it go red, put it back.
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
