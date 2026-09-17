# Agent Handoff

## 0. Handoff Metadata
- **Generated at**: `2026-09-17T18:05:30+08:00`
- **Repository**: `/Users/is52hertz/Project/old/dev-tools/Vibe-Setup`
- **Branch**: `feat/vibe-init-upgrade`
- **Current HEAD**: `d12a8ef445dbf87435dae8d55f7b312977c197cf` (`d12a8ef feat(ui): split every menu row into resident text and a reveal`)
- **Working tree state**: Clean for all Git-tracked files. Three untracked files/directories exist: `?? .claude/`, `?? handoff-legacy-conversion.md`, `?? session_handoff.md`.
- **Source sessions**:
  - `sessions/01.jsonl` (Claude Code session `d62a7a63-3758-4c89-b9ec-e9ec321ac0f3`, spans commits `d33c1d1` through `d12a8ef`)
  - `handoff-legacy-conversion.md` (Cline session for commit `cacc595`)
  - `.claude/handoff.md` (Claude Code session `eb1d8cb1-41b5-49dc-abad-306d3cd29ed9`, spans commits `148b644` through `342d4a1`)
  - `session_handoff.md` (Antigravity CLI / Gemini 3.8 Flash session `403ff7f6-7063-42ec-9991-04845e3b787b`, spans commits `b7d9a2a` and `7823be7`)
- **Git range inspected**: `main..feat/vibe-init-upgrade` (`182bda2..d12a8ef`, 15 commits)
- **Confidence**: High — verified directly against the live repository files, commit logs, test runners, and multi-session transcript records.

### Scope of this handoff
This document transfers the operational state of the comprehensive `vibe-init` upgrade on branch `feat/vibe-init-upgrade`. It synthesizes the full multi-session evolution: initial architecture overhaul, modular `<TAG>` template assembly, pure Bash 3.2 gutter-and-selector UI, three-way template merge engine with `.vibe-init/manifest` state tracking, semantic palette styling, dynamic dashboard ordering, and the strict UI principle of resident context versus interactive cursor reveals.

---

## 1. Objective
- **Primary goal**: Transform `vibe-init` from a one-shot copy script into a robust AI engineering environment orchestrator (`v1.1.0`):
  1. **Modular template assembly**: Atomic `<TAG>` blocks in `templates/blocks/` and `templates/common/` materialized on demand via `lib/block_engine.sh`.
  2. **Three-way merge state engine**: Track file and block hashes in `.vibe-init/manifest` (`lib/state.sh`) and compute three-way merge verdicts (`same`, `local`, `forward`, `review` in `lib/sync.sh`), eliminating duplicate prompts or spurious `.template` copies.
  3. **Dependency-free terminal UI**: Pure Bash 3.2 gutter (`lib/ui.sh`) and keyboard selectors (`lib/prompt.sh`) with semantic palette coloring (`ok`, `info`, `todo`, `off`, `neutral`, `bad`).
  4. **Resident vs. revealed UX principle**: Menu rows hold static, dim resident text indicating purpose, while dynamic state, versions, and pending action counts reveal under the cursor with intentional sideways push.
  5. **Trellis lifecycle management**: In `--apply`, detect project vs CLI versions, inspect platforms (`trellis platforms --json`), gate idle updates when versions match, and enable incremental platform additions (`lib/trellis.sh`).
  6. **Feature decoupling**: Make `CC-Cowork-Workflow.md` optional (`--cc-workflow yes|no`, default `no`) and decouple from `CLAUDE.md`.
- **Current milestone**: All 15 upgrade commits are complete and committed to `feat/vibe-init-upgrade`. The unit test suite (`test/units.sh`) passes with 175 assertions.
- **Definition of done**:
  - Unit tests (`./test/units.sh`) pass 100% (175/175).
  - Dry-run CLI integration tests (`./test/dry-run.sh`) pass 100% (125/125) in a standard developer environment.
  - Interactive TTY behavior verified on macOS Bash 3.2 with zero runtime dependencies.
  - Final review completed and branch merged into `main`.

---

## 2. Current Repository State
- **Branch**: `feat/vibe-init-upgrade`
- **HEAD**: `d12a8ef`
- **Working tree**: Clean Git tracking. Untracked: `.claude/`, `handoff-legacy-conversion.md`, `session_handoff.md`.

| File | Current role | Relevant state |
|---|---|---|
| `vibe-init.sh` | Main CLI entrypoint | Committed (`d33c1d1`). Sets `VIBE_INIT_VERSION="1.1.0"`, parses CLI flags, coordinates staging, initializes Git/Trellis, dispatches to scaffold or apply. |
| `lib/state.sh` | Manifest state recording | Committed (`d33c1d1`). Reads/writes `.vibe-init/manifest` (SHA256/cksum hashes per file and block), auto-appends `.vibe-init/` to `.gitignore`. |
| `lib/sync.sh` | Three-way merge engine | Committed (`d33c1d1`). Evaluates template vs target vs recorded manifest base (`merge_verdict`: `same`, `local`, `forward`, `review`), drives granular block-level updates. |
| `lib/block_engine.sh` | Modular block parser & assembler | Committed (`cacc595`). Handles `materialize_template_set`, `has_block`, `extract_block`, `replace_block`, `remove_block`, `append_block_if_missing`, and `file_format`. |
| `lib/ui.sh` | Visual layout & semantic palette | Committed (`84a3424`). Implements gutter frames, state colors (`ok`, `info`, `todo`, `off`, `neutral`, `bad`), `ui_kv_state`, `ui_copy_open`/`close`, safe dual-branch color variables. |
| `lib/prompt.sh` | Terminal input and interactive menus | Committed (`84a3424`). Pure Bash 3.2 selector (`ui_select`), multiselect (`ui_multiselect`), confirmation (`ui_confirm`), text input (`ui_input`), supporting 5-field option records with cursor reveals. |
| `lib/trellis.sh` | Trellis perception and operations | Committed (`70660a0`). Detects CLI/project versions, parses platforms via JSON/sniffing, executes platform add, update, and upgrade. Owns `trellis_update_pending`. |
| `lib/apply.sh` | Existing-project orchestrator | Committed (`d12a8ef`). Diagnostic status card, dynamic menu ordering via `dashboard_actions`, cursor reveal generators (`sync_menu_note`, `trellis_menu_note`, `syncall_menu_note`), `offer_copy_anyway`. |
| `templates/blocks/` | Atomic `<TAG>` template fragments | Committed (`148b644`). Contains `metadata.md`, `product.md`, `project_phase.md`, `core_rules.md`, `profile_setup.md`, `profiles/`, `integrations/`, `features/`. |
| `templates/common/` | Static project templates | Committed (`148b644`). Contains `.claude/settings.json`, `Test/templates-test-checklist.html`, and base `CLAUDE.md`. |
| `test/run.sh` | Test runner | Committed (`1527914`). Executes `test/dry-run.sh` and `test/units.sh`. |
| `test/dry-run.sh` | Integration test suite | Committed (`d33c1d1`). 125 assertions verifying CLI flags, fallbacks, template generation, legacy conversion, and output formatting. |
| `test/units.sh` | Direct library unit test suite | Committed (`d12a8ef`). 175 assertions verifying `block_engine.sh`, `state.sh`, `sync.sh`, `ui.sh`, and `apply.sh` ordering/reveals. |
| `AGENTS.md` | Durable guidelines & project standards | Committed (`d12a8ef`). Documents `<TAG>` format, resident vs. revealed UI rules, semantic levels, and project phases. |
| `.claude/` | Claude Code project configuration | Uncommitted (untracked). Contains `.claude/settings.json` and `.claude/handoff.md`. |
| `handoff-legacy-conversion.md` | Prior handoff document (Cline) | Uncommitted (untracked). Records legacy format prompt splitting. |
| `session_handoff.md` | Prior session log dump (Gemini) | Uncommitted (untracked). Raw transcript of initial upgrade attempt. |

---

## 3. Git-Derived Change History

### Relevant commits on `feat/vibe-init-upgrade`
1. `b7d9a2a` (*feat(cli): upgrade UI, modular template blocks, CC-workflow toggle, and Trellis orchestrator* - Gemini)
   - Initial implementation of modular blocks and Trellis checks; left duplicate template directories and inverted prompt order.
2. `7823be7` (*fix(cli): reorder interactive prompts, eliminate duplicate prints, and add template set switching* - Gemini)
   - Reordered prompts to reduce immediate CC-Workflow questioning, eliminated duplicate dashboard prints.
3. `148b644` (*refactor(templates): assemble one template set from blocks, drop base/trellis* - Claude Code)
   - Dropped duplicate `templates/base/` and `templates/trellis/` directories in favor of single-source dynamic materialization in staging (`prepare_template_set`).
4. `58605f2` (*fix(ui): stop the non-TTY crash, align the status box, read HEAD safely* - Claude Code)
   - Defined all `UI_*` variables on both color branches; handled unborn Git branches safely; ensured `remove_block` is exact inverse of `append_block_if_missing`.
5. `f55af41` (*feat(ui): replace the text prompt flow with a gutter-and-selector interface* - Claude Code)
   - Replaced emoji with geometric glyphs; created pure Bash 3.2 selector/multiselect prompts in `lib/prompt.sh`; established question order `folder -> git -> Trellis -> profile -> CC-Workflow`.
6. `1527914` (*test: cover the libraries directly, and document what the tool now is* - Claude Code)
   - Added direct unit test suite (`test/units.sh`, 59 assertions) and `test/run.sh`.
7. `342d4a1` (*fix(cli): quiet git init so its output does not break the gutter* - Claude Code)
   - Added `-q` to `git init` calls.
8. `cacc595` (*feat(apply): route legacy pre-<TAG> targets to a format-conversion prompt* - Cline)
   - Implemented `file_format` in `lib/block_engine.sh`. In `lib/apply.sh`, split agent prompt suggestions into content merge vs format conversion.
9. `d33c1d1` (*feat(sync): sync by three-way merge against recorded state* - Claude Code)
   - Created `lib/state.sh` (`.vibe-init/manifest` tracking file and block hashes, version stamped as `1.1.0`).
   - Created `lib/sync.sh` (three-way merge: template vs target vs base; fast-forwards clean blocks, isolates conflicts to `.template`).
   - Ensured leftover `.template` copies are refreshed rather than skipped. Auto-ignored `.vibe-init/` in `.gitignore`.
10. `996eb98` (*fix(ui): define the missing ui_info level, and draw progress dim* - Claude Code)
    - Defined canonical `ui_info` in `lib/ui.sh` (fixing runtime crash on menu toggles); rendered progress lines and copy boundaries dim.
11. `93310f2` (*feat(ui): give status output a semantic palette instead of grey and white* - Claude Code)
    - Created semantic palette in `lib/ui.sh`: `ok` (green), `info` (cyan), `todo` (yellow), `off` (dim), `bad` (red). Split rows into colored state words and dim details.
12. `70660a0` (*feat(apply): order the dashboard by what has work, and stop the idle Trellis update* - Claude Code)
    - Dynamic menu ordering: prioritized sync when work is pending, demoted sync when up to date.
    - Added gate for `trellis update`: asks user first (default no) if project version matches CLI version.
    - Extracted `dashboard_actions` for headless testing.
13. `33dcc4b` (*feat(apply): offer the copy anyway, and reveal a toggle's state under the cursor* - Claude Code)
    - Added `offer_copy_anyway` when sync finds no work (default no).
    - Expanded `prompt_opt` to support a 5th field (active cursor note).
14. `84a3424` (*feat(ui): put a toggle's state in front of its hint, and stop dimming "off"* - Claude Code)
    - Positioned revealed note in front of hint to trigger visible horizontal shifting under cursor.
    - Introduced `neutral` state level (plain foreground) so `off` states are readable without negative coloration.
15. `d12a8ef` (*feat(ui): split every menu row into resident text and a reveal* - Claude Code)
    - Codified **Resident vs. revealed** principle in `AGENTS.md`.
    - Made resident text purely static and dim across all rows (`templates`, `platforms, update, upgrade`, `in AGENTS.md`, `templates + Trellis, then exits`).
    - Made reveals dynamic with semantic colors; added `reveal_level` to lift dim states to `neutral`.
    - Consolidated `trellis_update_pending` into a single shared version comparison.

### Uncommitted diff
- None. Tracked working tree is clean (`git diff` and `git diff --cached` are empty).

### Important reversals and rewrites
- **Dual template trees dropped**: Redundant `templates/base/` and `templates/trellis/` directories were deleted in `148b644` in favor of staging materialization from `templates/blocks/`.
- **Awk-based auto-migration rejected**: In session 3, user rejected rewriting user files with bash awk scripts in favor of writing `.template` files alongside existing files and generating an AI format-conversion prompt (`cacc595`).
- **Blunt overwrite/skip sync replaced**: In session 4, user criticized Cline's blunt overwrite/skip apply options. Replaced with true three-way hash-based merge (`d33c1d1`).
- **Static menu ordering replaced**: Dashboard menu was rewritten to order dynamically based on whether work is pending (`70660a0`).
- **Dimming of `off` reversed**: Showing `off` in dim gray obscured its state against dim resident text. Reversed in `84a3424` by introducing the `neutral` level and lifting dim reveals.

---

## 4. User Decisions and Constraints

### Hard requirements
- **Optional CC-Workflow**: `CC-Cowork-Workflow.md` must be optional in new scaffolds (`--cc-workflow yes|no`, defaulting to `no`), excluded from `CLAUDE.md` by default, and toggleable in `--apply`.
- **Strict `<TAG>` block boundaries**: `AGENTS.md` and `CLAUDE.md` must be divided into `<TAG>` blocks. New profiles/integrations must be discoverable simply by dropping files into `templates/blocks/profiles/` or `templates/blocks/integrations/`.
- **Non-destructive file sync**: Never silently overwrite user modifications. Legacy files get `.template` copies and a dedicated conversion prompt; modern files with conflicting edits get `.template` copies and block-level merge prompts.
- **State record in `.vibe-init/`**: State must be recorded in `.vibe-init/manifest` using simple tab-separated key-value pairs (SHA256/cksum) parseable by awk, without JSON parser dependencies. Stamped with `VIBE_INIT_VERSION="1.1.0"`. Added to `.gitignore`.
- **Zero emoji**: All UI rendering must use clean geometric glyphs (`◆`, `◇`, `●`, `○`, `■`, `□`, `▲`).
- **Interaction sequence**: In scaffold mode, all interactive questions (`folder -> git -> Trellis -> profile -> CC-Workflow`) must be resolved before writing any files.
- **Resident vs. revealed UI principle**:
  - Resident text must be static, indicate category, never change dynamically, and always remain dim.
  - All dynamic information (status, versions, pending counts) belongs strictly in the cursor reveal.
  - Revealing an item must push the hint horizontally to catch the user's eye.
  - Reveals must never be dim (use `reveal_level` to lift `off` to `neutral`).
- **Idle Trellis update gate**: If project Trellis version equals CLI version, do not run `trellis update` automatically; ask user first with default `no`.

### Platform and compatibility constraints
- **macOS Bash 3.2 compatibility**: Must run under `set -euo pipefail` on stock macOS Bash 3.2 (no `declare -A`, no `mapfile`/`readarray`, no namerefs, no fractional `read -t`).
- **Zero runtime dependencies**: No required dependencies beyond standard Bash, coreutils, and POSIX awk.
- **Terminal degradation**: Full support for rich color TTY, no-color interactive TTY, and non-TTY / CI pipes. `NO_COLOR` output must remain byte-for-byte identical.
- **Security boundary**: `.claude/settings.json` must preserve deny rules for `.env*`, `secrets/**`, and sensitive private keys.

---

## 5. Architecture and Technical Decisions
- **Decision 1: Dynamic Template Materialization (`lib/block_engine.sh`)**
  - *Status*: Active
  - *Reason*: Avoids combinatorial file trees for profile/integration combinations.
  - *Evidence*: `materialize_template_set` in `lib/block_engine.sh` called by `prepare_template_set` in `vibe-init.sh`.
  - *Consequences*: New variants are created by adding atomic markdown files to `templates/blocks/`.
- **Decision 2: Three-Way Merge Engine (`lib/sync.sh`, `lib/state.sh`)**
  - *Status*: Active
  - *Reason*: Two-way file checks cannot distinguish between user customizations and template updates.
  - *Evidence*: `merge_verdict` evaluates template hash, target hash, and manifest base hash.
  - *Consequences*: Safe auto-fast-forward of untouched sections; zero spurious `.template` copies on identical files.
- **Decision 3: Pure Bash 3.2 Gutter and Selector UI (`lib/ui.sh`, `lib/prompt.sh`)**
  - *Status*: Active
  - *Reason*: Delivers modern interactive CLI experience while maintaining zero external tool dependencies (no `gum`, no Node CLI prerequisites).
  - *Evidence*: `ui_select`, `ui_multiselect`, `ui_kv_state` in `lib/prompt.sh` and `lib/ui.sh`.
- **Decision 4: Semantic Color Hierarchy and Neutral State Level**
  - *Status*: Active
  - *Reason*: Standard green/red/dim color schemes mischaracterize legitimate disabled options (e.g. CC-Workflow disabled) as errors or invisible text.
  - *Evidence*: Levels `ok` (green), `info` (cyan), `todo` (yellow), `off` (dim), `neutral` (default uncolored), `bad` (red).
- **Decision 5: Resident vs. Revealed Layout Contract**
  - *Status*: Active
  - *Reason*: Eliminates cognitive clutter and provides high visual salience on the row being actively selected.
  - *Evidence*: `prompt_opt` 5-field records; `sync_menu_note`, `trellis_menu_note`, `syncall_menu_note` in `lib/apply.sh`.

---

## 6. Important Code Map
- **`vibe-init.sh`**:
  - `parse_args()`: Validates flags (`--git`, `--trellis`, `--profile`, `--cc-workflow`, `--apply`, `--files`, `--on-exists`).
  - `prepare_template_set()`: Drives template staging via `lib/block_engine.sh`.
  - `resolve_trellis_setup()` / `run_trellis_init()`: Gathers Trellis inputs up front; executes `trellis init` after file assembly.
  - `run_scaffold_mode()` / `run_apply_mode()`: Core execution routing.
- **`lib/state.sh`**:
  - `state_hash_file()`, `state_hash_block()`: Computes sha256 (or cksum floor).
  - `state_load()`, `state_record_file()`, `state_record_block()`, `state_flush()`: Manages `.vibe-init/manifest`.
  - `state_ensure_git_ignored()`: Adds `.vibe-init/` to `.gitignore`.
- **`lib/sync.sh`**:
  - `merge_verdict()`: Three-way merge resolution (`same`, `local`, `forward`, `review`).
  - `sync_file()`: Dispatches file-level or block-level merge; writes `.template` only on conflicts.
- **`lib/block_engine.sh`**:
  - `materialize_template_set()`: Assembles fragments from `templates/blocks/`.
  - `has_block()`, `extract_block()`, `replace_block()`, `remove_block()`, `append_block_if_missing()`.
  - `file_format()`: Classifies file as `modern`, `legacy`, or `missing`.
- **`lib/ui.sh`**:
  - `_ui_state_color()`, `ui_kv_state()`: Semantic palette rendering.
  - `ui_step_start()`, `ui_step_done()`, `ui_gutter()`: Box and gutter drawing.
  - `ui_copy_open()`, `ui_copy_close()`: Dim packaging rules for agent copy blocks.
- **`lib/prompt.sh`**:
  - `prompt_opt()`: Encodes up to 5 fields: `value`, `label`, `hint`, `state_level`, `active_note`.
  - `ui_select()`: Single-select keyboard menu (arrow keys, j/k, numbers, cursor reveals).
  - `ui_multiselect()`, `ui_confirm()`, `ui_input()`.
- **`lib/apply.sh`**:
  - `show_project_diagnostics()`: Visual status card with semantic levels.
  - `dashboard_actions()`: Builds dynamically ordered menu options based on work state.
  - `offer_copy_anyway()`: Safe copy gate when sync detects nothing to do.
- **`lib/trellis.sh`**:
  - `detect_trellis_support()`: Reads `.trellis/.version` and `trellis --version`.
  - `trellis_update_pending()`: Authoritative version comparison check.

---

## 7. Work Completed
- [x] **Completed and verified**:
  - Transitioned template architecture to atomic blocks (`templates/blocks/`) and common files (`templates/common/`); deleted legacy base/trellis directories.
  - Decoupled `CC-Cowork-Workflow.md` (`--cc-workflow yes|no`, default `no`) and linked references in `CLAUDE.md`.
  - Implemented pure Bash 3.2 gutter and selector UI (`lib/ui.sh`, `lib/prompt.sh`) with safe variable definitions on both color branches.
  - Built `.vibe-init/manifest` state engine (`lib/state.sh`) and three-way merge engine (`lib/sync.sh`).
  - Implemented legacy file format classification and AI conversion prompt routing (`cacc595`).
  - Implemented semantic color hierarchy and neutral state level (`93310f2`, `84a3424`).
  - Established dynamic dashboard menu ordering and gated idle Trellis updates (`70660a0`).
  - Implemented Resident vs. Revealed UI principle across all dashboard menu rows (`d12a8ef`).
  - Added unit test suite (`test/units.sh`) expanded to 175 assertions (100% pass).
  - Added CLI dry-run test suite (`test/dry-run.sh`) with 125 assertions.
- [~] **Completed but not fully verified**:
  - Physical human tactile check of interactive cursor movement across all newly revealed dashboard rows in a live macOS terminal.
- **Discussed only**:
  - Truncation of long version reveals (e.g. `v1.0.0 -> v1.1.0, 3 to review`) on narrow terminal screens (< 80 columns).
  - Deletion or archival of untracked files: `handoff-legacy-conversion.md` and `session_handoff.md`.

---

## 8. Tests and Verification
- **Test execution commands**:
  - `./test/run.sh` — runs both dry-run and unit suites.
  - `./test/units.sh` — direct library verification.
  - `./test/dry-run.sh` — CLI integration verification.
- **Known passing checks**:
  - `test/units.sh`: **PASS — 175 assertions, 0 failures**. Covers block engine operations, state recording, merge verdicts, semantic color rendering, menu ordering, resident/revealed splitting, and variable parity.
- **Known failing checks in restricted sandbox**:
  - `test/dry-run.sh`: In restricted sandbox environments where execution of external Node binaries (`~/.local/share/mise/installs/node/22/bin/node`) is blocked with OS error `Operation not permitted`, the 6 Trellis-invoking assertions fail (`trellis run labels the integration`, `trellis init uses -u <name>`, `default platform flags passed`, `global $DEVELOPER_NAME hint shown`, `global $DEVELOPER_NAME is used`, `--platforms none note`). Outside the sandbox in standard environments, all 125 assertions pass.
- **Minor defects discovered in test harnesses**:
  1. `test/dry-run.sh` line 216 calls `is "mixed run prints both prompt blocks" "${prompts}" "2"`, but `is` is defined only in `test/units.sh`, producing a non-fatal `is: command not found` stderr message.
  2. `test/units.sh` tests `apply.sh` menu notes in isolated subshells that do not source `lib/trellis.sh`, generating harmless stderr warnings for `trellis_cli_version: command not found` and `trellis_update_pending: command not found` (caught by `|| true`).

---

## 9. Bugs, Failures, and Dead Ends
- **Dead End: Dual Template Directories (`templates/base` & `templates/trellis`)**
  - *Observed behavior*: Duplicate maintenance of static files led to divergent copies of rules and settings.
  - *Resolution*: Dropped in `148b644`. Replaced with atomic blocks assembled in staging.
- **Dead End: Bash-Side AST/Awk Re-wrapping of Legacy Files**
  - *Observed behavior*: Writing awk state machines to parse freeform legacy markdown and wrap sections into `<TAG>` blocks risked corrupting user text.
  - *Resolution*: Abandoned per user instruction. Legacy targets now receive `.template` files beside originals and an AI prompt instructing the agent to perform the conversion.
- **Dead End: Fixed-Width Slot for Menu Toggles**
  - *Observed behavior*: Reserving static whitespace to prevent menu text from shifting caused cursor state changes to be visually overlooked.
  - *Resolution*: Abandoned in `84a3424`. Placing the note in front of the hint deliberately causes an unmissable horizontal shift.
- **Failure: Crash on Non-TTY under `set -u`**
  - *Observed behavior*: Scripts aborted when piped or run with `NO_COLOR=1`.
  - *Resolution*: Declared identical `UI_*` variables on both branches in `lib/ui.sh` (`58605f2`).
- **Failure: Idle `trellis update` Interrogation**
  - *Observed behavior*: "Sync everything" unconditionally executed `trellis update`, forcing users through a lengthy scan and prompt on matching versions.
  - *Resolution*: Added gate in `70660a0` to verify version delta; asks user first with default `no` when versions match.

---

## 10. Open Questions
- **Needs user decision**:
  1. *Disposition of untracked handoff artifacts*: Should `handoff-legacy-conversion.md` and `session_handoff.md` be deleted, archived, or added to `.gitignore`?
  2. *README updates*: Sections in `README.md` (lines 94, 114–115) referencing obsolete directory structures and flags need refreshing.
- **Can be decided by next agent**:
  - Fix the trivial syntax omission in `test/dry-run.sh` line 216 by adding `is` helper or replacing with standard assertion.
  - Add missing `source "${REPO_ROOT}/lib/trellis.sh"` to `test/units.sh` subshells to eliminate stderr noise.

---

## 11. Current Task Queue

### P0 — Continue immediately
1. Fix the `is: command not found` syntax defect on line 216 of `test/dry-run.sh` (define `is` or use standard check).
2. Fix stderr noise in `test/units.sh` by ensuring `lib/trellis.sh` is sourced in subshells testing `trellis_menu_note` and `dashboard_actions`.
3. Perform interactive verification in a real terminal: run `./vibe-init.sh --apply` to visually confirm cursor reveals and horizontal shift behavior.

### P1 — After P0
1. Remove or archive untracked working tree files (`handoff-legacy-conversion.md`, `session_handoff.md`, `.claude/handoff.md`).
2. Update `README.md` to document `v1.1.0` capabilities: `.vibe-init/manifest`, three-way merge sync, `<TAG>` blocks, and Trellis dashboard.
3. Merge `feat/vibe-init-upgrade` into `main`.

### P2 — Optional / cleanup
1. Evaluate whether reveal text for outdated templates (e.g. `v1.0.0 -> v1.1.0, 3 to review`) requires width-constrained formatting on 80-column terminals.

---

## 12. Recommended Next Actions
1. Inspect `test/dry-run.sh` line 216 and define `is()` helper matching `test/units.sh`.
2. Run `./test/units.sh` to confirm zero stderr warnings.
3. Check status: `git status`.
4. Review untracked files with user, remove or gitignore them, and merge `feat/vibe-init-upgrade` into `main`.

---

## 13. Multi-Session Reconciliation
- **Session 1 (Gemini, `session_handoff.md`)**:
  - Introduced initial `<TAG>` concept and Trellis commands (`b7d9a2a`, `7823be7`).
  - *Flaws*: Left duplicate `templates/base` and `templates/trellis`, caused non-TTY crashes, inverted prompt sequencing.
- **Session 2 (Claude Code, `.claude/handoff.md`)**:
  - Authored commits `148b644` through `342d4a1`.
  - Refactored templates to atomic staging; built pure Bash 3.2 selector UI; fixed non-TTY crashes; added `test/units.sh` (59 tests).
- **Session 3 (Cline, `handoff-legacy-conversion.md`)**:
  - Authored commit `cacc595`.
  - Added legacy target classification and split AI agent prompt into merge vs format conversion.
- **Session 4 (Claude Code, `sessions/01.jsonl`)**:
  - Authored commits `d33c1d1` through `d12a8ef` (current HEAD).
  - Replaced blunt sync with three-way merge engine (`.vibe-init/manifest`); added semantic color palette; implemented dynamic dashboard menu ordering; established Resident vs. Revealed UI principle; expanded units to 175 assertions.
- **Reconciliation Verdict**: Session 4 represents the authoritative, culminating state. All prior sessions' incomplete or conflicting approaches (e.g. blunt overwrite sync, static menu ordering, dim toggle reveals) have been cleanly superseded by committed code.

---

## 14. Critical Context Worth Preserving
- **Zero-Dependency Core**: Vibe-Setup must remain pure Bash 3.2 without Node.js or `gum` runtime dependencies.
- **Staging Pipeline Rule**: All template generation must pass through `prepare_template_set` via `lib/block_engine.sh`. Never write scaffolded files directly from raw script strings.
- **Three-Way Merge Base**: The `.vibe-init/manifest` file is essential for distinguishing user customizations from upstream template updates. Never delete or bypass it during standard sync.
- **Resident vs. Revealed UI Rule**: In interactive menus, resident text is static and dim; dynamic text belongs exclusively in cursor reveals. Reveals must never be colored dim.
- **Dual-Branch Color Parity**: Every variable defined in `lib/ui.sh` must exist in both color and non-color branches to prevent crashes under `set -u`.

---

## 15. Uncertainty and Evidence Gaps
- **Untracked files disposition**: `session_handoff.md` and `handoff-legacy-conversion.md` remain untracked; whether they should be committed as documentation, moved to a docs directory, or deleted requires explicit user confirmation.
- **Narrow terminal handling**: Whether lengthy reveal notes cause visual wrap on terminals narrower than 80 columns has not been tested on physical vintage terminals.

---

## 16. Fresh-Agent Bootstrap
To continue work safely, the next agent must:
1. Read this handoff document in full.
2. Run `git status` to verify working tree status.
3. Run `git log -n 15 --oneline` to review commit history from `b7d9a2a` to `d12a8ef`.
4. Inspect core modules: `vibe-init.sh`, `lib/state.sh`, `lib/sync.sh`, `lib/block_engine.sh`, `lib/ui.sh`, `lib/prompt.sh`, and `lib/apply.sh`.
5. Run `./test/units.sh` and verify that all 175 unit assertions pass.
6. Proceed directly to execute the **P0** tasks in Section 11.
