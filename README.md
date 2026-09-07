# Vibe-Setup

A small Bash CLI that bootstraps a project for AI-assisted development. It seeds
a shared set of AI-agent instruction files (`AGENTS.md`, `CLAUDE.md`), a
secrets-deny Claude Code settings file, and a manual test checklist — and can
optionally install and initialize [Trellis](https://www.npmjs.com/package/@mindfoldhq/trellis).
The files under `templates/` are the source of truth the script copies from.

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

You will be asked whether to `git init` the project (default **yes**) and
whether to install/initialize Trellis (default **no**); then the template files
are copied in.

### Seed an existing project

```sh
vibe-init --apply
```

`--apply` lists the managed files with their status and lets you sync **all or a
subset**.

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

### Options

| Option | Description |
| --- | --- |
| `PROJECT` | Bare positional project name (equivalent to `--name`); only used when the current directory is not empty. Cannot be combined with `--name` or `--apply`. |
| `--name NAME` | Project folder name when the current directory is not empty. |
| `--git yes\|no` | Whether to run `git init` in the new project (default: yes). Skipped if already a repo; ignored with `--apply`. |
| `--trellis yes\|no` | Whether to install/initialize Trellis. |
| `--developer-name NAME` | Developer identity passed to `trellis init -u NAME`. Defaults to `$DEVELOPER_NAME`, then `git config user.name`, then `$USER`. |
| `--platforms "FLAGS"` | Trellis platform flags, e.g. `"--claude --codex"`. |
| `--template-dir DIR` | Override the template directory (default: `templates/trellis` with Trellis, else `templates/base`). |
| `--apply` | Copy templates into the current directory instead of scaffolding a new project. |
| `--files "A,B"` | With `--apply`, copy only this subset of the managed files instead of prompting. |
| `-y`, `--yes` | Accept safe defaults for all prompts. |
| `--dry-run` | Print actions without writing files or running installers. |
| `-h`, `--help` | Show help. |

## What gets created

| File | Purpose |
| --- | --- |
| `AGENTS.md` | Single source of truth for all AI coding assistants — product, rules, standards, security, handoff. |
| `CLAUDE.md` | Imports `AGENTS.md`; holds Claude Code-specific instructions only when needed. |
| `.claude/settings.json` | Denies agents from reading secrets (`.env*`, `secrets/**`, `*.pem`/`*.key`/`*.p12`/`*.pfx`). |
| `Test/templates-test-checklist.html` | A manual test checklist. |

## Templates

Two template sets live under `templates/`:

- **`base`** — plain projects.
- **`trellis`** — adds Trellis workflow instructions to `AGENTS.md`.

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
block assembly and editing, the state manifest, the merge verdicts, and the
non-interactive contracts of the prompts. Exit code 0 means every assertion
passed.

## License

[MIT](LICENSE) © Teethe
