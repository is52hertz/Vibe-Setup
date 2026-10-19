# Vibe-Setup

A small Bash CLI that bootstraps a project for AI-assisted development. It seeds
a shared set of AI-agent instruction files (`AGENTS.md`, `CLAUDE.md`), a
secrets-deny Claude Code settings file, and optional extras such as a manual
test checklist — and can optionally install and initialize [Trellis](https://www.npmjs.com/package/@mindfoldhq/trellis).
The files under `templates/` are the source of truth the script assembles each
project's files from.

## Why

Every new project needs the same baseline so AI coding assistants behave
consistently: one source of truth for product rules and coding standards, a
guardrail that keeps agents from reading secrets, and a place for handoff notes.
`vibe-init` lays that down in one step, for a brand-new project or an existing
one.

## Requirements

- **Bash** — works on the system Bash that ships with macOS (3.2+).
- **git** — optional; only needed for the `git init` step.
- **Trellis (optional)** — Node.js 18+, npm, and Python 3.9+.

## Install

```sh
git clone https://github.com/is52hertz/Vibe-Setup.git
cd Vibe-Setup

# Run it directly,
./vibe-init.sh

# …or put it on your PATH:
ln -s "$PWD/vibe-init.sh" ~/.local/bin/vibe-init
```

The script resolves symlinks, so it always finds its sibling `templates/`
directory even when invoked through a symlink on your `PATH`.

## Usage

### Scaffold a new project

Run inside an empty directory (it initializes in place) or a non-empty one (it
creates a project subfolder):

```sh
vibe-init
# or, in a non-empty directory, name the project directly:
vibe-init my-project
```

You will be asked, in order: the project folder (when the directory is not
empty), whether to `git init` it (default **yes**), whether to install/initialize
Trellis (default **no**), which profile the project is, and whether to include
CC-Cowork-Workflow (default **no**). Every question is answered before anything
is written; then the template set is assembled for those answers and copied in.

The profile picks the rule set `AGENTS.md` carries: `service` (backends, APIs,
anything with a datastore or external callers) or `tool` (scripts, small CLIs,
utilities). `ask` — the default under `-y` or without a terminal — keeps both,
behind a one-time setup note telling the project's AI agent to confirm the
profile with you and delete the rest.

### Seed an existing project

```sh
vibe-init --apply
```

In a terminal, `--apply` opens a dashboard: a diagnostics card (vibe-init and
project versions, git, Trellis and its platforms, CC-Workflow, and whether
`AGENTS.md` / `CLAUDE.md` are in the `<TAG>` block format), then a menu that
leads with whatever has work:

- **Sync template files** — pick from the files that have something to do.
- **Trellis management** — add an AI platform, `trellis update`, upgrade the CLI,
  pause, or uninstall. When the project is already at the CLI's version, the
  update asks first and defaults to no.
  - **Pause** runs `trellis ablate`: every Trellis file leaves the project and a
    recovery copy is kept in `~/.trellis` on this machine. **Restore** (offered
    while paused) runs `trellis restore` and brings tasks, specs, journals and
    memory back exactly as they were. Use it to switch away mid-project.
  - **Uninstall** runs `trellis uninstall`, which deletes `.trellis/` for good.
    If the work under it is not committed, vibe-init says so and asks first
    (default no).
  - Trellis asks for its own confirmation either way. Afterwards vibe-init
    offers to remove (or, after a restore, re-add) the Trellis block in
    `AGENTS.md`.
- **Toggle CC-Workflow** / **Toggle Trellis block** — add or remove the feature.
  Turning one off removes exactly the block it added; CC-Workflow's own document
  is kept as `CC-Cowork-Workflow.md.disabled`.
- **Sync everything and exit**.

Each row shows what it is about; its live state — a toggle's on/off, a version,
the pending changes — appears on the row under the cursor. With `-y`, without a
terminal, or with `--files` / `--on-exists`, there is no menu: the diagnostics
print once and the standard sync runs.

The sync is a three-way merge, not a copy. `vibe-init` records what it wrote in
`.vibe-init/manifest` (content hashes, per file and per `<TAG>` block), so it can
tell a template change from your own edits:

| Situation | What happens |
| --- | --- |
| The file already matches the template | Nothing — it is not touched or listed. |
| The template has not moved since it was written | Nothing — the differences are yours. |
| The template moved and you did not touch it | Refreshed in place, per block for `AGENTS.md` / `CLAUDE.md`. |
| Both moved | Left alone; the new template lands beside it as `<name>.template` with a prompt for your AI agent naming the blocks still open. |

Nothing you wrote is ever overwritten. A project with no manifest yet (an older
one, or a clone whose state was not committed) has no merge base, so its first sync treats every
existing file that differs as needing review, and records what already matches.
`--on-exists overwrite|template|skip` bypasses the merge and applies the older
blunt file-level policy instead.

**Explicit review completion.** Each review freezes its upstream template under
`.vibe-init/pending/`. Later releases cannot replace an open proposal. Deleting
`<name>.template` does **not** acknowledge it; the next sync restores the hand-out.
Your AI edits the project file, using the old upstream objects in `.vibe-init/base/`
and the frozen new proposal to distinguish upstream edits from project edits.
Block hashes in the manifest are authoritative; a whole-file base can be older
than individually updated blocks. A missing base object means the old content is
unknown, not that the current file should be treated as the old template.

After reviewing the result, obtain the review ID and **current** file fingerprint:

```sh
vibe-init --apply --pending
vibe-init --apply --resolve REVIEW_ID --expect FILE_HASH --resolution merged
```

Replace `REVIEW_ID` and `FILE_HASH` with the values shown by `--pending`. This
acknowledges that exact file content against that frozen upstream version. A
stale fingerprint, changed proposal, duplicate/unclosed managed tags, or merge
conflict markers rejects the acknowledgement. The tool does not prove semantic
correctness or validate arbitrary configuration formats (including JSON); review
those before acknowledging. An AI should resolve only after the user's approval
or under an existing authorization to make that decision.

There are three resolution choices:

- `merged`: the content merge has been reviewed and completed.
- `keep`: keep the project version **this time**, including intentional deletion.
  The same upstream proposal stops recurring; future upstream changes are still
  compared with the accepted upstream base. This never copies template text over
  the project's file.
- `converted`: acknowledge only a legacy format conversion. It does not accept
  the upstream content; run `--apply` again for the content review.

The acknowledged **upstream template**, never the customized result, becomes the
next baseline. A newly released template can therefore produce another review
immediately after acknowledging an older frozen proposal. To defer an update,
leave its review unresolved or exit the menu; no baseline is advanced.

### Pause updates or own your rules

The dashboard's **Upgrade controls** offers pending reviews, project pause/resume,
and file/block ownership. The same operations are available to scripts and agents:

```sh
vibe-init --apply --pause-updates
vibe-init --apply --resume-updates
vibe-init --apply --self-manage AGENTS.md:CORE_RULES
vibe-init --apply --follow AGENTS.md:CORE_RULES
```

Pause persists until resumed, including noninteractive `--apply -y` runs. Resume
only changes the policy; the next ordinary `--apply` checks the latest templates.
This pauses **template sync**, not explicitly requested Trellis lifecycle commands.

A scope is `FILE` or `FILE:TAG[:ID]`, for example `AGENTS.md:PROFILE:tool`.
Project ownership leaves the scope untouched during normal sync. A whole-file
ownership rule takes precedence over its block rules; restore file following
first if you want to follow individual blocks. Changing ownership does not
silently resolve an existing review; acknowledge it separately with `keep`.
`PRODUCT` and `PROJECT_PHASE` in AGENTS.md are project-owned by default. Use
`--follow` if a project deliberately wants to follow either template block.
Ordinary edits to other rules need no policy: if upstream has not changed, sync
already preserves them. Explicit `--on-exists` remains a legacy copy override,
so do not use `overwrite` as your normal upgrade command.

### Portable state and older projects

Commit `.vibe-init/manifest`, `.vibe-init/policy` (when present), and
`.vibe-init/base/` with your project. They store hashes, decisions, and **upstream**
text, not copies of your customized project files. The tool does not commit for
you. Only `pending/`, `backups/`, and `lock/` are ignored. Existing exact
`.vibe-init/` ignore rules emitted by older versions are migrated; broader custom
or global ignore rules remain yours to adjust. For non-Git directories, include
the durable state in your normal backups.

Schema-1 manifests migrate without losing their hashes. Matching templates fill
in recoverable base objects; unknown historical content is not invented. Legacy
pending copies require explicit acknowledgement even if their `.template` is
already gone. Future, unsupported schemas are rejected before project writes.
Projects without state are conservatively adopted: matching content is recorded,
and divergent content needs review. Skipped releases require no intermediate CLI
installation for ordinary template changes.

An `AGENTS.md` or `CLAUDE.md` written before the `<TAG>` format takes two rounds:

1. **Convert.** The sync writes `<name>.template` and instructions for wrapping
   existing sections in blocks without changing their content. Review the diff,
   then resolve with `--resolution converted`.
2. **Merge.** Run `--apply` again, review the content changes, then resolve with
   `merged` or `keep`.

Previously managed, nonoptional blocks retired upstream are removed only if
unchanged locally; edited ones require review. Local file deletion is preserved,
with a review if upstream subsequently changes. Optional block absence remains a
conservative opt-out: a missing profile/feature/integration is never re-enabled
implicitly. An optional block absent from the assembled template may reflect a
variant change, so it is not automatically removed. File renames, retired files,
and ambiguous block renames require an explicit migration in the release that
introduces them; this version does not guess rename intent from similar text.

The displayed project version is the **last tool used**, not a claim that all
updates were accepted. Pending review counts remain visible independently.

### Recovery

Template sync, resolution and policy changes save a local recovery snapshot and
print its directory. Restore a completed snapshot by its directory name:

```sh
vibe-init --apply --rollback 20260920T120000Z.12345
```

Rollback restores managed files and mutable bookkeeping only if they still match
the snapshot's post-operation fingerprints. It refuses to overwrite later edits.
An incomplete snapshot or a project changed after the operation requires manual
inspection of its `before/` directory; it is not safe to force automatic rollback.
Immutable, unreferenced base objects may remain after restoration. Snapshots can
contain project-specific content and remain ignored; retain or remove them locally
as needed. Recovery covers template upgrade operations, not Trellis's own lifecycle
or feature-toggle archives.

A per-project lock prevents concurrent upgrade processes. After a hard kill, check
that no upgrade is running before removing `.vibe-init/lock/`. Managed paths and
upgrade state containing symlinks are rejected to prevent redirected writes.

### Options

| Option | Description |
| --- | --- |
| `PROJECT` | Bare positional project name (equivalent to `--name`); only used when the current directory is not empty. Cannot be combined with `--name` or `--apply`. |
| `--name NAME` | Project folder name when the current directory is not empty. |
| `--git yes\|no` | Whether to run `git init` in the new project (default: yes). Skipped if already a repo; ignored with `--apply`. |
| `--profile service\|tool\|ask` | Profile for a new project: `service` or `tool` assembles `AGENTS.md` with just that rule set; `ask` (the `-y` / non-TTY default) keeps all of them for the project's AI agent to resolve. Not valid with `--apply`. |
| `--trellis yes\|no` | Whether to install/initialize Trellis. |
| `--cc-workflow yes\|no` | Whether to include `CC-Cowork-Workflow.md` and its `CLAUDE.md` reference (default: no). With `--apply`, the default follows the project: the file is offered only if the project already has it. |
| `--test-checklist yes\|no` | Whether to include `Test/templates-test-checklist.html`, the standalone manual-test page (default: no). With `--apply`, the default follows the project the same way. |
| `--developer-name NAME` | Developer identity passed to `trellis init -u NAME`. Defaults to `$DEVELOPER_NAME`, then `git config user.name`, then `$USER`. |
| `--platforms "FLAGS"` | Trellis platform flags, e.g. `"--claude --codex"`. `none` passes no platform flags. |
| `--template-dir DIR` | Override the template root — the directory holding `blocks/` and `common/` (default: `templates/` next to the script). |
| `--apply` | Work on the project in the current directory instead of scaffolding a new one: open the dashboard, or sync without it (see above). |
| `--files "A,B"` | With `--apply`, sync only this subset of the managed files instead of prompting. |
| `--pending` | With `--apply`, list frozen reviews and current fingerprints without writing project files. |
| `--resolve ID --expect HASH --resolution MODE` | Acknowledge a reviewed file as `merged`, `keep`, or `converted`. |
| `--pause-updates` / `--resume-updates` | Persistently pause or resume project template upgrades. |
| `--self-manage SCOPE` / `--follow SCOPE` | Set ownership for a file or `FILE:TAG[:ID]` scope. |
| `--rollback ID` | Restore a completed recovery snapshot when no later edits would be lost. |
| `--on-exists MODE` | With `--apply`, skip the merge and resolve every existing file with one policy: `overwrite`, `template` (write `<name>.template`), or `skip`. |
| `-y`, `--yes` | Accept safe defaults for all prompts. |
| `--dry-run` | Print actions without writing files or running installers. |
| `-h`, `--help` | Show help. |

### Interface language

Press **Shift+L** in any interactive menu to switch the interface between
English and Simplified Chinese (in a plain numbered menu, type `L` and Enter).
The switch lasts for the rest of the run; every run starts in English unless
`VIBE_INIT_LANG=zh` is set. The prompts printed for your AI agent stay in
English — they are written for the model, and already ask it to talk to you in
Chinese.

## What gets created

| File | Purpose |
| --- | --- |
| `AGENTS.md` | Single source of truth for all AI coding assistants — product, rules, standards, security, handoff. |
| `CLAUDE.md` | Imports `AGENTS.md`; holds Claude Code-specific instructions only when needed. |
| `CC-Cowork-Workflow.md` | Optional (`--cc-workflow yes`): how Claude Code delegates execution and review to an external executor. |
| `.claude/settings.json` | Denies agents from reading secrets (`.env*`, `secrets/**`, `*.pem`/`*.key`/`*.p12`/`*.pfx`). |
| `Test/templates-test-checklist.html` | Optional (`--test-checklist yes`): a standalone manual test checklist page. |
| `.vibe-init/` | Portable `manifest`, `policy`, and upstream `base/` objects. Local `pending/`, `backups/`, and `lock/` are ignored. |

## Templates

There is one set of templates, assembled per run rather than copied as-is:

- **`templates/blocks/`** — the `<TAG>` blocks `AGENTS.md` is built from:
  `metadata`, `product`, `project_phase`, `core_rules`, then the profile
  (`profiles/`, plus `profile_setup` when the profile is `ask`), then any
  integrations (`integrations/`, e.g. Trellis). `features/cc-workflow/` holds
  `CC-Cowork-Workflow.md` — a plain and a Trellis variant — the `codex-run`
  subagent it delegates through, and the block it adds to `CLAUDE.md`;
  `features/test-checklist/` holds the manual test page.
- **`templates/common/`** — the static files every project gets:
  `.claude/settings.json` and the `CLAUDE.md` skeleton (the CC-Workflow block,
  when on, is appended to it). Anything optional lives under `features/`
  instead, because `common/` is copied whole and cannot be switched off.

Adding a profile or an integration is dropping a file into `profiles/` or
`integrations/`; nothing in the script lists them. Because every block is
delimited, `--apply` can update the blocks the tool owns and leave the ones you
wrote alone.

When Trellis is initialized, the secret-deny rules from the template's
`.claude/settings.json` are merged into the settings file Trellis generates,
rather than overwriting it.

## Safety

- Existing project files are skipped, never overwritten. `--apply` only edits a
  file where a content hash proves the text is the tool's own and untouched;
  anything you changed is left for you, with a `<name>.template` copy beside it.
- `--dry-run` shows exactly what would happen without changing anything.
- The seeded `.claude/settings.json` blocks agents from reading common secret
  files.

## Tests

```sh
./test/run.sh
```

Runs all three suites. `test/dry-run.sh` drives the CLI and asserts on what it prints
— scaffold, `--apply` file selection and `--on-exists`, the sync verdicts, flag
guards, and Trellis init. `test/units.sh` exercises the libraries directly —
block assembly and editing, the state manifest, the merge verdicts, the
dashboard's menu order and reveals, the Trellis update gate, and the
non-interactive contracts of the prompts. Exit code 0 means every assertion
passed. `test/upgrades.sh` exercises cross-release reviews, ownership, pause,
legacy adoption, clone portability, validation, locking, previews, and recovery.

## License

[MIT](LICENSE) © Teethe
