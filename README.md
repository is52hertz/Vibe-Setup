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
```

You will be asked whether to `git init` the project (default **yes**) and
whether to install/initialize Trellis (default **no**); then the template files
are copied in.

### Seed an existing project

```sh
vibe-init --apply
```

`--apply` lists the managed files with their status and lets you copy **all or a
subset**. Existing files are never overwritten or merged — when a target already
exists, the copy lands alongside it as `<name>.template` instead.

### Options

| Option | Description |
| --- | --- |
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

- Existing project files are skipped, never overwritten; `--apply` writes a
  `<name>.template` copy instead of touching what you already have.
- `--dry-run` shows exactly what would happen without changing anything.
- The seeded `.claude/settings.json` blocks agents from reading common secret
  files.

## License

[MIT](LICENSE) © Teethe
