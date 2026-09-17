# Vibe-Setup

A small Bash CLI that bootstraps a project for AI-assisted development. It seeds
a shared set of AI-agent instruction files (`AGENTS.md`, `CLAUDE.md`), a
secrets-deny Claude Code settings file, and a manual test checklist — and can
optionally install and initialize [Trellis](https://www.npmjs.com/package/@mindfoldhq/trellis).
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
- **Trellis management** — add an AI platform, `trellis update`, upgrade the CLI.
  When the project is already at the CLI's version, the update asks first and
  defaults to no.
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
one, or a fresh clone) has no merge base, so its first sync treats every
existing file as needing review and adopts what already matches — later runs are
quiet. `--on-exists overwrite|template|skip` bypasses the merge and applies the
older blunt file-level policy instead.

`.vibe-init/` is local bookkeeping and is added to the project's `.gitignore`.

An `AGENTS.md` or `CLAUDE.md` written before the `<TAG>` format has no blocks to
merge. It gets its `<name>.template` beside it and a separate prompt asking your
AI agent to restructure it — the script never rewrites the file itself.

### Options

| Option | Description |
| --- | --- |
| `PROJECT` | Bare positional project name (equivalent to `--name`); only used when the current directory is not empty. Cannot be combined with `--name` or `--apply`. |
| `--name NAME` | Project folder name when the current directory is not empty. |
| `--git yes\|no` | Whether to run `git init` in the new project (default: yes). Skipped if already a repo; ignored with `--apply`. |
| `--profile service\|tool\|ask` | Profile for a new project: `service` or `tool` assembles `AGENTS.md` with just that rule set; `ask` (the `-y` / non-TTY default) keeps all of them for the project's AI agent to resolve. Not valid with `--apply`. |
| `--trellis yes\|no` | Whether to install/initialize Trellis. |
| `--cc-workflow yes\|no` | Whether to include `CC-Cowork-Workflow.md` and its `CLAUDE.md` reference (default: no). With `--apply`, the default follows the project: the file is offered only if the project already has it. |
| `--developer-name NAME` | Developer identity passed to `trellis init -u NAME`. Defaults to `$DEVELOPER_NAME`, then `git config user.name`, then `$USER`. |
| `--platforms "FLAGS"` | Trellis platform flags, e.g. `"--claude --codex"`. `none` passes no platform flags. |
| `--template-dir DIR` | Override the template root — the directory holding `blocks/` and `common/` (default: `templates/` next to the script). |
| `--apply` | Work on the project in the current directory instead of scaffolding a new one: open the dashboard, or sync without it (see above). |
| `--files "A,B"` | With `--apply`, sync only this subset of the managed files instead of prompting. |
| `--on-exists MODE` | With `--apply`, skip the merge and resolve every existing file with one policy: `overwrite`, `template` (write `<name>.template`), or `skip`. |
| `-y`, `--yes` | Accept safe defaults for all prompts. |
| `--dry-run` | Print actions without writing files or running installers. |
| `-h`, `--help` | Show help. |

## What gets created

| File | Purpose |
| --- | --- |
| `AGENTS.md` | Single source of truth for all AI coding assistants — product, rules, standards, security, handoff. |
| `CLAUDE.md` | Imports `AGENTS.md`; holds Claude Code-specific instructions only when needed. |
| `CC-Cowork-Workflow.md` | Optional (`--cc-workflow yes`): how Claude Code delegates execution and review to an external executor. |
| `.claude/settings.json` | Denies agents from reading secrets (`.env*`, `secrets/**`, `*.pem`/`*.key`/`*.p12`/`*.pfx`). |
| `Test/templates-test-checklist.html` | A manual test checklist. |
| `.vibe-init/manifest` | What vibe-init last wrote, as content hashes — the merge base for `--apply`. Added to `.gitignore` in a git project. |

## Templates

There is one set of templates, assembled per run rather than copied as-is:

- **`templates/blocks/`** — the `<TAG>` blocks `AGENTS.md` is built from:
  `metadata`, `product`, `project_phase`, `core_rules`, then the profile
  (`profiles/`, plus `profile_setup` when the profile is `ask`), then any
  integrations (`integrations/`, e.g. Trellis). `features/cc-workflow/` holds
  `CC-Cowork-Workflow.md` — a plain and a Trellis variant — and the block it adds
  to `CLAUDE.md`.
- **`templates/common/`** — the static files: `.claude/settings.json`, the test
  checklist, and the `CLAUDE.md` skeleton (the CC-Workflow block, when on, is
  appended to it).

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

Runs both suites. `test/dry-run.sh` drives the CLI and asserts on what it prints
— scaffold, `--apply` file selection and `--on-exists`, the sync verdicts, flag
guards, and Trellis init. `test/units.sh` exercises the libraries directly —
block assembly and editing, the state manifest, the merge verdicts, the
dashboard's menu order and reveals, the Trellis update gate, and the
non-interactive contracts of the prompts. Exit code 0 means every assertion
passed.

## License

[MIT](LICENSE) © Teethe
