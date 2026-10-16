#!/usr/bin/env bash
set -euo pipefail

IFS=$'\n\t'

SCRIPT_NAME="$(basename -- "$0")"

# Resolve symlinks so the script finds its sibling templates/ directory even when
# invoked through a symlink (e.g. ~/.local/bin/vibe-init -> .../vibe-init.sh).
# pwd -P alone follows the directory but not a symlinked script file.
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "${SCRIPT_SOURCE}" ]]; do
  script_link_dir="$(cd -P -- "$(dirname -- "${SCRIPT_SOURCE}")" && pwd)"
  SCRIPT_SOURCE="$(readlink -- "${SCRIPT_SOURCE}")"
  [[ "${SCRIPT_SOURCE}" != /* ]] && SCRIPT_SOURCE="${script_link_dir}/${SCRIPT_SOURCE}"
done
SCRIPT_DIR="$(cd -P -- "$(dirname -- "${SCRIPT_SOURCE}")" && pwd)"
SCRIPT_PATH="${SCRIPT_SOURCE}"
TEMPLATE_ROOT="${SCRIPT_DIR}/templates"

# Recorded into every scaffolded project (.vibe-init/manifest) and shown in the
# apply diagnostics, so a project can say which vibe-init last touched it.
# Bump the minor for a template or behavior change projects should pick up.
VIBE_INIT_VERSION="1.1.0"

ASSUME_DEFAULTS=0
DRY_RUN=0
APPLY_MODE=0
# Whether the scaffolded project gets CC-Cowork-Workflow.md and the CLAUDE.md
# block that points at it. Empty CHOICE means "ask" (default no); --cc-workflow
# yes|no sets it non-interactively. In apply mode an unset choice follows what
# the target project already has.
CC_WORKFLOW_CHOICE=""
CC_WORKFLOW_ENABLED=0
# Whether the scaffolded project gets Test/templates-test-checklist.html, the
# standalone manual-test page. Same shape as CC-Workflow: empty CHOICE means
# "ask" (default no), --test-checklist yes|no sets it non-interactively, and in
# apply mode an unset choice follows what the target project already has.
TEST_CHECKLIST_CHOICE=""
TEST_CHECKLIST_ENABLED=0

# Source helper modules
[[ -f "${SCRIPT_DIR}/lib/ui.sh" ]] && . "${SCRIPT_DIR}/lib/ui.sh"
[[ -f "${SCRIPT_DIR}/lib/prompt.sh" ]] && . "${SCRIPT_DIR}/lib/prompt.sh"
[[ -f "${SCRIPT_DIR}/lib/block_engine.sh" ]] && . "${SCRIPT_DIR}/lib/block_engine.sh"
[[ -f "${SCRIPT_DIR}/lib/state.sh" ]] && . "${SCRIPT_DIR}/lib/state.sh"
[[ -f "${SCRIPT_DIR}/lib/sync.sh" ]] && . "${SCRIPT_DIR}/lib/sync.sh"
[[ -f "${SCRIPT_DIR}/lib/trellis.sh" ]] && . "${SCRIPT_DIR}/lib/trellis.sh"
# Optional comma/space separated subset of TEMPLATE_FILES to copy in apply mode.
# Empty means "ask interactively" (or "all" under -y / non-TTY). Requires --apply.
APPLY_FILES=""
# How apply mode resolves a file that already exists: overwrite|template|skip.
# Empty means "ask per file" (or "template" under -y / non-TTY). Requires --apply.
ON_EXISTS=""
# Project profile for a NEW project: service|tool|ask. Empty means "ask"
# interactively, or "ask" (keep every profile block for the AI) under -y / non-TTY.
# A concrete service|tool assembles AGENTS.md with only that PROFILE block.
# Rejected with --apply, where the AI resolves the profile from the codebase.
PROFILE=""
# Single source of truth for the template files vibe-init manages. apply mode
# iterates this list; the explicit calls in write_project_placeholders must stay
# in sync with it (kept explicit there because each init copy pairs with its own
# built-in placeholder, and bash 3.2 has no reliable associative arrays).
TEMPLATE_FILES=(
  "AGENTS.md"
  "CLAUDE.md"
  "CC-Cowork-Workflow.md"
  ".claude/agents/codex-run.md"
  ".claude/settings.json"
  "Test/templates-test-checklist.html"
)
PROJECT_NAME=""
# Set when the project name came from a bare positional <PROJECT> argument
# (e.g. `vibe-init myproject`) rather than --name. Used to reject a conflicting
# --name and a positional PROJECT with --apply.
PROJECT_NAME_POSITIONAL=0
TRELLIS_CHOICE=""
# Whether to run `git init` in a freshly scaffolded project. Empty means "ask"
# (default yes); --git yes|no sets it non-interactively. Ignored in --apply mode.
GIT_CHOICE=""
# Honor a default developer name from the environment (e.g. export DEVELOPER_NAME
# in ~/.zshrc). The --developer-name flag still overrides it; an empty value falls
# back to auto-detection (git config user.name, then $USER).
DEVELOPER_NAME="${DEVELOPER_NAME:-}"
# Remember whether the developer name came from a global $DEVELOPER_NAME. That
# path skips the interactive prompt, so we surface a hint instead of using it
# silently. The --developer-name flag (explicit) clears this.
DEVELOPER_NAME_FROM_ENV=0
if [[ -n "${DEVELOPER_NAME}" ]]; then
  DEVELOPER_NAME_FROM_ENV=1
fi
TRELLIS_PLATFORMS=""
# The concrete template set for this run, materialized out of templates/blocks/
# and templates/common/ into a staging directory by prepare_template_set. Every
# copy (scaffold and apply alike) reads from here, so a variant is decided in
# exactly one place. Cleaned up on exit.
TEMPLATE_DIR=""
TEMPLATE_STAGE_DIR=""
# Human-readable description of what went into TEMPLATE_DIR, for log lines that
# would otherwise print a meaningless staging path.
TEMPLATE_SET_LABEL=""
# Integration blocks to assemble into AGENTS.md (comma separated ids from
# templates/blocks/integrations/). Currently just "trellis" or empty.
TEMPLATE_INTEGRATIONS=""
TRELLIS_INITIALIZED=0
# Filled in by resolve_trellis_setup, consumed by run_trellis_init.
TRELLIS_READY=0
TRELLIS_DEVELOPER_NAME=""
TRELLIS_PLATFORM_ARGS=()

# Remove the materialized template set. Registered on EXIT, so an interrupted or
# failed run does not leave a staging directory behind.
cleanup_template_stage() {
  if [[ -n "${TEMPLATE_STAGE_DIR}" && -d "${TEMPLATE_STAGE_DIR}" ]]; then
    rm -rf "${TEMPLATE_STAGE_DIR}"
  fi
}

# Shift+L flips the interface language inside a selector, which runs in a
# subshell; the flip reaches the rest of the run through a file in this private
# directory (see lib/i18n.sh). Made only when there is a terminal to press the
# key in, so a scripted run does no extra work. Removed on EXIT only — not by
# cleanup_template_stage, which also runs mid-run whenever the set is rebuilt.
UI_RUN_DIR=""
prepare_ui_run_dir() {
  [[ -t 0 ]] || return 0
  UI_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe-init-ui.XXXXXX" 2>/dev/null)" || {
    UI_RUN_DIR=""
    return 0
  }
  UI_LANG_FILE="${UI_RUN_DIR}/lang"
}

cleanup_on_exit() {
  cleanup_template_stage
  if [[ -n "${UI_RUN_DIR}" && -d "${UI_RUN_DIR}" ]]; then
    rm -rf "${UI_RUN_DIR}"
  fi
}
trap cleanup_on_exit EXIT

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} [options] [PROJECT]

PROJECT is an optional bare positional project folder name (like --name NAME);
used only when the current directory is not empty. Cannot be combined with
--name or --apply.

Options:
  --name NAME              Project folder name when current directory is not empty.
                           Equivalent to the bare PROJECT argument, but they cannot
                           be used together.
  --git yes|no             Whether to run git init in the new project (default: yes).
                           Ignored with --apply. Skipped if already a git repository.
  --profile MODE           Project profile for a NEW project: service | tool | ask.
                           service/tool assemble AGENTS.md with just that rule set;
                           ask (the -y / non-TTY default) keeps all profiles for
                           the project's AI to resolve later. Not valid with --apply.
  --trellis yes|no         Whether to install/init Trellis.
  --cc-workflow yes|no     Whether to include CC-Cowork-Workflow (default: no).
                           With --apply, the default follows the target project:
                           the file is offered only if the project already has it.
  --test-checklist yes|no  Whether to include Test/templates-test-checklist.html,
                           the standalone manual-test page (default: no).
                           With --apply, the default follows the target project:
                           the file is offered only if the project already has it.
  --developer-name NAME    Developer identity passed to: trellis init -u NAME.
                           Defaults to \$DEVELOPER_NAME, then git user.name, then \$USER.
  --platforms "FLAGS"      Trellis platform flags, for example: "--claude --codex".
                           Use "none" (or "n") to pass no platform flags.
  --template-dir DIR       Override the template root (the directory holding blocks/ and
                           common/). Default: templates/ next to this script. The set for a
                           run is assembled from those blocks; missing ones fall back to
                           built-in placeholders.
  --apply                  Copy the template files into the CURRENT directory (an existing
                           project) instead of scaffolding a new one. Opens the orchestrator
                           dashboard: project diagnostics, then template sync, Trellis
                           management, and feature toggles. The set is assembled to match the
                           project (Trellis block when it is Trellis-managed). Existing files
                           are left untouched; the copy is written as <name>.template instead.
  --files "A,B"            Apply only this subset of the managed files (comma/space separated,
                           e.g. "AGENTS.md,CLAUDE.md") instead of prompting. Requires --apply.
  --on-exists MODE         How --apply resolves a file that already exists, without prompting:
                           overwrite | template (write <name>.template) | skip. Default: ask
                           per file (template under -y / non-TTY). Requires --apply.
  -y, --yes                Accept safe defaults for prompts.
  --dry-run                Print actions without writing files or running installers.
  -h, --help               Show this help.

Behavior:
  - If the current directory is effectively empty, initialize in ".".
  - If it is not empty, create a project folder under the current directory.
  - The script ignores itself, .DS_Store, and .localized when checking emptiness.
  - Existing project files are skipped, not overwritten.
  - Asks whether to run git init in the new project (default yes); skipped when
    the project is already a git repository. Not done in --apply mode.
  - With --apply: lists the managed files (and whether each already exists) and
    asks which to copy; --files preselects a subset and -y / non-TTY copies all.
    Copies into the current directory. For a file that already exists you choose
    per file: overwrite, write <name>.template, or skip (default template, also
    the -y / non-TTY behavior); --on-exists sets this for the whole run. Does not
    install or initialize Trellis. Notes (but does not act on) a target that is
    not a git repository.
  - Shift+L in any interactive menu switches the interface between English and
    Simplified Chinese for the rest of the run (in a plain numbered menu, type L
    and Enter). VIBE_INIT_LANG=zh starts in Chinese. Agent prompts stay English.
EOF
}

# The three message levels. lib/ui.sh renders them: a gutter line for a human at
# a terminal, the familiar `[vibe-init] …` line everywhere else. The body of the
# message is identical either way, so anything that greps the output still works.
info() {
  ui_log "$*"
}

warn() {
  ui_warn "$*"
}

die() {
  ui_error "$*"
  exit 1
}

require_arg() {
  local option="$1"
  local value="${2:-}"
  [[ -n "${value}" ]] || die "${option} requires a value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      require_arg "$1" "${2:-}"
      [[ "${PROJECT_NAME_POSITIONAL}" -eq 1 ]] && die "conflicting project name: ${PROJECT_NAME} (use one of <PROJECT> or --name)"
      PROJECT_NAME="$2"
      shift 2
      ;;
    --name=*)
      PROJECT_NAME="${1#*=}"
      require_arg "--name" "${PROJECT_NAME}"
      [[ "${PROJECT_NAME_POSITIONAL}" -eq 1 ]] && die "conflicting project name: ${PROJECT_NAME} (use one of <PROJECT> or --name)"
      shift
      ;;
    --trellis)
      require_arg "$1" "${2:-}"
      TRELLIS_CHOICE="$2"
      shift 2
      ;;
    --trellis=*)
      TRELLIS_CHOICE="${1#*=}"
      require_arg "--trellis" "${TRELLIS_CHOICE}"
      shift
      ;;
    --cc-workflow)
      require_arg "$1" "${2:-}"
      CC_WORKFLOW_CHOICE="$2"
      shift 2
      ;;
    --cc-workflow=*)
      CC_WORKFLOW_CHOICE="${1#*=}"
      require_arg "--cc-workflow" "${CC_WORKFLOW_CHOICE}"
      shift
      ;;
    --test-checklist)
      require_arg "$1" "${2:-}"
      TEST_CHECKLIST_CHOICE="$2"
      shift 2
      ;;
    --test-checklist=*)
      TEST_CHECKLIST_CHOICE="${1#*=}"
      require_arg "--test-checklist" "${TEST_CHECKLIST_CHOICE}"
      shift
      ;;
    --git)
      require_arg "$1" "${2:-}"
      GIT_CHOICE="$2"
      shift 2
      ;;
    --git=*)
      GIT_CHOICE="${1#*=}"
      require_arg "--git" "${GIT_CHOICE}"
      shift
      ;;
    --profile)
      require_arg "$1" "${2:-}"
      PROFILE="$2"
      shift 2
      ;;
    --profile=*)
      PROFILE="${1#*=}"
      require_arg "--profile" "${PROFILE}"
      shift
      ;;
    --developer-name)
      require_arg "$1" "${2:-}"
      DEVELOPER_NAME="$2"
      DEVELOPER_NAME_FROM_ENV=0
      shift 2
      ;;
    --developer-name=*)
      DEVELOPER_NAME="${1#*=}"
      require_arg "--developer-name" "${DEVELOPER_NAME}"
      DEVELOPER_NAME_FROM_ENV=0
      shift
      ;;
    --platforms)
      require_arg "$1" "${2:-}"
      TRELLIS_PLATFORMS="$2"
      shift 2
      ;;
    --platforms=*)
      TRELLIS_PLATFORMS="${1#*=}"
      require_arg "--platforms" "${TRELLIS_PLATFORMS}"
      shift
      ;;
    --template-dir)
      require_arg "$1" "${2:-}"
      TEMPLATE_ROOT="$2"
      shift 2
      ;;
    --template-dir=*)
      TEMPLATE_ROOT="${1#*=}"
      require_arg "--template-dir" "${TEMPLATE_ROOT}"
      shift
      ;;
    --apply)
      APPLY_MODE=1
      shift
      ;;
    --files)
      require_arg "$1" "${2:-}"
      APPLY_FILES="$2"
      shift 2
      ;;
    --files=*)
      APPLY_FILES="${1#*=}"
      require_arg "--files" "${APPLY_FILES}"
      shift
      ;;
    --on-exists)
      require_arg "$1" "${2:-}"
      ON_EXISTS="$2"
      shift 2
      ;;
    --on-exists=*)
      ON_EXISTS="${1#*=}"
      require_arg "--on-exists" "${ON_EXISTS}"
      shift
      ;;
    -y|--yes)
      ASSUME_DEFAULTS=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      case "$1" in
        -*)
          die "unknown option: $1"
          ;;
        *)
          # Bare positional project name: `vibe-init <PROJECT>`.
          [[ -n "${PROJECT_NAME}" ]] && die "conflicting project name: ${PROJECT_NAME} (use one of <PROJECT> or --name)"
          PROJECT_NAME="$1"
          PROJECT_NAME_POSITIONAL=1
          shift
          ;;
      esac
      ;;
  esac
done

normalize_yes_no() {
  local value="$1"
  local lower_value=""

  lower_value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  case "${lower_value}" in
    y|yes|true|1) printf 'yes' ;;
    n|no|false|0) printf 'no' ;;
    *) return 1 ;;
  esac
}

# Ask for a free-text value; echoes the answer.
#
#   --yes with a default        take it, ask nothing
#   --yes without a default     still ask, because there is nothing to fall back
#                               on (a project name has no sensible default)
#   no terminal on stdin        take the default, or die if there is none
#   otherwise                   ask
ask_value() {
  local question="$1"
  local default_value="${2:-}"

  if [[ "${ASSUME_DEFAULTS}" -eq 1 && -n "${default_value}" ]]; then
    printf '%s\n' "${default_value}"
    return
  fi

  if [[ ! -t 0 ]]; then
    [[ -n "${default_value}" ]] || die "missing required value in non-interactive mode: ${question}"
    printf '%s\n' "${default_value}"
    return
  fi

  ui_input "${question}" "${default_value}"
}

# Ask a yes/no question; returns 0 for yes. --yes and a non-terminal stdin both
# take the default without asking.
ask_yes_no() {
  local question="$1"
  local default_value="$2"
  local normalized_default=""

  normalized_default="$(normalize_yes_no "${default_value}")" || die "invalid yes/no default: ${default_value}"

  if [[ "${ASSUME_DEFAULTS}" -eq 1 || ! -t 0 ]]; then
    [[ "${normalized_default}" == "yes" ]]
    return
  fi

  ui_confirm "${question}" "${normalized_default}"
}

validate_project_name() {
  local name="$1"
  [[ -n "${name}" ]] || die "project name cannot be empty"
  case "${name}" in
    .|..|*/*|*\\*)
      die "project name must be a simple folder name, got: ${name}"
      ;;
  esac
}

validate_developer_name() {
  local name="$1"
  [[ -n "${name}" ]] || die "developer name cannot be empty"
  case "${name}" in
    .|..|*/*|*\\*)
      die "developer name must not contain path separators, got: ${name}"
      ;;
  esac
}

is_effectively_empty_dir() {
  local dir="$1"
  local entry=""
  local base=""

  while IFS= read -r -d '' entry; do
    base="$(basename -- "${entry}")"
    case "${base}" in
      .DS_Store|.localized)
        continue
        ;;
    esac
    if [[ "${entry}" == "${SCRIPT_PATH}" ]]; then
      continue
    fi
    return 1
  done < <(find "${dir}" -mindepth 1 -maxdepth 1 -print0)

  return 0
}

run_cmd() {
  local rendered=""

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    rendered="$(printf ' %q' "$@")"
    info "dry-run:${rendered}"
    return
  fi
  "$@"
}

run_in_dir() {
  local dir="$1"
  local rendered=""
  shift

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    rendered="$(printf ' %q' "$@")"
    info "dry-run: cd $(printf '%q' "${dir}") &&${rendered}"
    return
  fi

  (cd "${dir}" && "$@")
}

ensure_dir() {
  local dir="$1"
  if [[ -d "${dir}" ]]; then
    return
  fi
  run_cmd mkdir -p "${dir}"
}

write_file_if_missing() {
  local path="$1"
  local content="$2"
  local parent=""

  if [[ -e "${path}" ]]; then
    info "skip existing ${path}"
    return
  fi

  parent="$(dirname -- "${path}")"
  ensure_dir "${parent}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run: write ${path}"
    return
  fi

  printf '%s\n' "${content}" > "${path}"
  info "created ${path}"
}

copy_or_write_placeholder() {
  local relative_path="$1"
  local destination="$2"
  local placeholder="$3"
  local source="${TEMPLATE_DIR}/${relative_path}"

  if [[ -e "${destination}" ]]; then
    info "skip existing ${destination}"
    return
  fi

  if [[ -f "${source}" ]]; then
    ensure_dir "$(dirname -- "${destination}")"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      info "dry-run: copy ${relative_path} -> ${destination}"
    else
      cp "${source}" "${destination}"
      info "copied ${destination}"
    fi
    return
  fi

  # Template missing: fall back to the built-in placeholder. This is an emergency
  # stub (intentionally minimal, not a mirror of the template), so warn that the
  # rich template was not used.
  warn "${relative_path}: template not found at ${source}; writing a minimal fallback stub"
  write_file_if_missing "${destination}" "${placeholder}"
}

# Copy a template file that has no built-in placeholder fallback (e.g. the manual
# test-checklist HTML). Honors skip-existing and dry-run; if the template dir does
# not ship the file, it is simply skipped rather than written from a placeholder.
copy_optional_template() {
  local relative_path="$1"
  local destination="$2"
  local source="${TEMPLATE_DIR}/${relative_path}"

  if [[ -e "${destination}" ]]; then
    info "skip existing ${destination}"
    return
  fi

  if [[ ! -f "${source}" ]]; then
    info "skip ${relative_path}: not present in template dir"
    return
  fi

  ensure_dir "$(dirname -- "${destination}")"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run: copy ${relative_path} -> ${destination}"
  else
    cp "${source}" "${destination}"
    info "copied ${destination}"
  fi
}

agents_placeholder() {
  cat <<'EOF'
# AI Agent Instructions

> vibe-init fallback: the AGENTS.md template was missing, so this is a minimal
> emergency stub — not the full ruleset. Replace it with the real template from
> the Vibe-Setup repo (templates/blocks/), or fill in the sections below.

## Product

<!-- TODO: what this project is, who uses it, platform/runtime target, key constraints. -->

## Development Rules

<!-- TODO: this project's coding standards, scope discipline, and verify & commit policy. -->

## Security

- Never read, print, log, or commit secrets (`.env*`, `secrets/**`, key files).
EOF
}

claude_placeholder() {
  cat <<'EOF'
@AGENTS.md

## Claude Code

> vibe-init fallback: the CLAUDE.md template was missing, so this is a minimal
> emergency stub. Replace it with the real template from the Vibe-Setup repo
> (templates/common/CLAUDE.md).

- This file imports AGENTS.md so Claude Code and other coding agents share one source of project instructions.
- When you need to ask the user something, prefer Claude Code's built-in question tool (AskUserQuestion).
EOF
}

claude_settings_placeholder() {
  cat <<'EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "deny": [
      "Read(./.env)",
      "Read(./.env.*)",
      "Read(./secrets/**)",
      "Read(./**/*.pem)",
      "Read(./**/*.key)",
      "Read(./**/*.p12)",
      "Read(./**/*.pfx)"
    ]
  }
}
EOF
}

default_developer_name() {
  local candidate=""

  if command -v git >/dev/null 2>&1; then
    candidate="$(git config --global user.name 2>/dev/null || true)"
  fi

  if [[ -z "${candidate}" ]]; then
    candidate="${USER:-developer}"
  fi

  candidate="${candidate// /-}"
  printf '%s\n' "${candidate}"
}

check_trellis_prerequisites() {
  local node_major=""

  if ! command -v node >/dev/null 2>&1; then
    warn "Node.js was not found. Trellis requires Node.js 18+."
  else
    node_major="$(node -v | sed 's/^v//' | cut -d '.' -f 1)"
    if [[ "${node_major}" =~ ^[0-9]+$ ]] && (( node_major < 18 )); then
      warn "Node.js $(node -v) found. Trellis requires Node.js 18+."
    fi
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 was not found. Trellis requires Python 3.9+."
  fi

  if ! command -v npm >/dev/null 2>&1; then
    warn "npm was not found. It is required only if Trellis is not already installed."
  fi
}

trellis_version() {
  if ! command -v trellis >/dev/null 2>&1; then
    return 1
  fi

  trellis --version 2>/dev/null | awk 'NF { print; found=1; exit } END { exit found ? 0 : 1 }'
}

install_trellis_installer() {
  local installed_version=""

  if ! command -v npm >/dev/null 2>&1; then
    die "npm was not found. Install Node.js/npm before installing Trellis."
  fi

  info "installing Trellis with npm install -g @mindfoldhq/trellis"
  run_cmd npm install -g @mindfoldhq/trellis

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return
  fi

  installed_version="$(trellis_version)" || die "Trellis install finished, but trellis --version still did not return a version."
  info "installed Trellis: ${installed_version}"
}

merge_secret_deny_rules() {
  local project_dir="$1"
  local settings="${project_dir}/.claude/settings.json"
  local template_settings="${TEMPLATE_DIR}/.claude/settings.json"

  # The template's settings.json is the source of the deny rules. Trellis owns
  # the generated .claude/settings.json (hooks/env), so we merge our
  # permissions.deny into it rather than overwriting it.
  if [[ ! -f "${template_settings}" ]]; then
    return
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run: merge permissions.deny from the template set into ${settings}"
    return
  fi

  if [[ ! -f "${settings}" ]]; then
    warn "trellis did not create ${settings}; skipping deny-rule merge"
    return
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found; skipping deny-rule merge into ${settings}"
    return
  fi

  if python3 - "${settings}" "${template_settings}" <<'PY'
import json, sys

settings_path, template_path = sys.argv[1], sys.argv[2]

with open(settings_path) as fh:
    settings = json.load(fh)
with open(template_path) as fh:
    template = json.load(fh)

deny = template.get("permissions", {}).get("deny", [])
if not deny:
    sys.exit(0)

perms = settings.setdefault("permissions", {})
existing = perms.setdefault("deny", [])
added = [rule for rule in deny if rule not in existing]
if not added:
    sys.exit(0)

existing.extend(added)
with open(settings_path, "w") as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")
PY
  then
    info "merged secret-deny rules into ${settings}"
  else
    warn "failed to merge deny rules into ${settings}"
  fi
}

# Ask which AI platforms Trellis should wire up. Offers the combinations people
# actually pick, with an escape hatch for anything else; --platforms and the
# non-interactive paths bypass it entirely.
ask_platforms() {
  local default_flags="--claude --codex"
  local choice=""
  local -a options=()

  if [[ "${ASSUME_DEFAULTS}" -eq 1 || ! -t 0 ]]; then
    printf '%s\n' "${default_flags}"
    return
  fi

  options+=("$(prompt_opt "--claude --codex" "Claude Code + Codex")")
  options+=("$(prompt_opt "--claude" "Claude Code only")")
  options+=("$(prompt_opt "--claude --codex --cursor" "Claude Code + Codex + Cursor")")
  options+=("$(prompt_opt "none" "No platform flags")")
  options+=("$(prompt_opt "custom" "Something else" "type the flags yourself")")

  choice="$(ui_select "Trellis platforms" "${default_flags}" "${options[@]}")"
  if [[ "${choice}" == "custom" ]]; then
    choice="$(ui_input "Trellis platform flags" "${default_flags}")"
  fi

  printf '%s\n' "${choice}"
}

# Ask everything Trellis needs, up front and in one block: the install gate,
# the developer identity and the platform flags. Sets TRELLIS_READY when the run
# should go on to initialize, plus TRELLIS_DEVELOPER_NAME and
# TRELLIS_PLATFORM_ARGS for run_trellis_init.
#
# Separated from the initialization itself because AGENTS.md has to be assembled
# and seeded before `trellis init` runs, and the profile that goes into it is
# asked after this block. Keeping the questions together is worth the split.
resolve_trellis_setup() {
  local developer_name="${DEVELOPER_NAME}"
  local default_name=""
  local platform_input="${TRELLIS_PLATFORMS}"
  local normalized_platforms=""
  local installed_version=""

  TRELLIS_READY=0
  TRELLIS_PLATFORM_ARGS=()

  check_trellis_prerequisites

  if installed_version="$(trellis_version)"; then
    info "found Trellis: ${installed_version}"
  elif command -v trellis >/dev/null 2>&1; then
    warn "trellis exists, but trellis --version did not return a version."
    if ask_yes_no "Reinstall the Trellis installer with npm install -g @mindfoldhq/trellis?" "yes"; then
      install_trellis_installer
    else
      warn "skipping Trellis initialization because the existing trellis command is not reporting a version."
      return
    fi
  else
    warn "trellis command was not found."
    if ask_yes_no "Install the Trellis installer with npm install -g @mindfoldhq/trellis?" "yes"; then
      install_trellis_installer
    else
      warn "skipping Trellis initialization because Trellis is not installed."
      return
    fi
  fi

  if [[ -z "${developer_name}" ]]; then
    default_name="$(default_developer_name)"
    developer_name="$(ask_value "Trellis developer name" "${default_name}")"
  elif [[ "${DEVELOPER_NAME_FROM_ENV}" -eq 1 ]]; then
    info "using Trellis developer name from \$DEVELOPER_NAME: ${developer_name} (override with --developer-name)"
  fi
  validate_developer_name "${developer_name}"
  TRELLIS_DEVELOPER_NAME="${developer_name}"

  if [[ -z "${platform_input}" ]]; then
    platform_input="$(ask_platforms)"
  fi

  # 'n' / 'none' (any case) opts out: pass no platform flags to trellis init.
  case "$(printf '%s' "${platform_input}" | tr '[:upper:]' '[:lower:]')" in
    n|none)
      info "no Trellis platform flags will be passed"
      platform_input=""
      ;;
  esac

  normalized_platforms="${platform_input//,/ }"
  if [[ -n "${normalized_platforms// /}" ]]; then
    IFS=' ' read -r -a TRELLIS_PLATFORM_ARGS <<< "${normalized_platforms}"
  fi

  TRELLIS_READY=1
}

# Seed AGENTS.md and run `trellis init` with the answers resolved earlier. The
# seeding has to happen first so trellis (skip-existing) preserves our guidance
# and only manages the TRELLIS block inside the file.
run_trellis_init() {
  local project_dir="$1"
  local init_args=()

  copy_or_write_placeholder "AGENTS.md" "${project_dir}/AGENTS.md" "$(agents_placeholder)"

  if [[ "${ASSUME_DEFAULTS}" -eq 1 || ! -t 0 ]]; then
    # Non-interactive: -y accepts trellis prompts (e.g. spec template) and
    # already implies skip-existing, so our seeded AGENTS.md is preserved.
    init_args=(-y)
  else
    # Interactive: skip our seeded files silently but still let the user
    # pick a spec template.
    init_args=(--skip-existing)
  fi

  info "initializing Trellis in ${project_dir}"
  # ${TRELLIS_PLATFORM_ARGS[@]+...} expands to nothing (not an error) when the
  # array is empty under set -u on bash 3.2.
  run_in_dir "${project_dir}" trellis init "${init_args[@]}" -u "${TRELLIS_DEVELOPER_NAME}" ${TRELLIS_PLATFORM_ARGS[@]+"${TRELLIS_PLATFORM_ARGS[@]}"}

  merge_secret_deny_rules "${project_dir}"
  TRELLIS_INITIALIZED=1
}

# Materialize the template set this run needs (profile x integrations x
# features) into a staging directory and point TEMPLATE_DIR at it. Safe under
# --dry-run: it only ever writes inside the staging directory, never into the
# user's project, and it makes dry-run output reflect the real files.
#
# Can be called again to rebuild the set when a choice changes (e.g. the user
# declined the Trellis install after asking for it).
prepare_template_set() {
  local profile="$1"
  local integrations="$2"
  local enable_cc="$3"
  local enable_checklist="${4:-0}"
  local tmp_root="${TMPDIR:-/tmp}"

  if [[ ! -d "${TEMPLATE_ROOT}/blocks" ]]; then
    warn "template blocks not found under ${TEMPLATE_ROOT}; falling back to built-in placeholders"
  fi

  # Rebuild from scratch so a second call cannot inherit stale files.
  cleanup_template_stage
  tmp_root="${tmp_root%/}"
  TEMPLATE_STAGE_DIR="$(mktemp -d "${tmp_root}/vibe-init-set.XXXXXX")" \
    || die "could not create a staging directory for the template set"

  TEMPLATE_DIR="${TEMPLATE_STAGE_DIR}"
  materialize_template_set "${TEMPLATE_DIR}" "${profile}" "${integrations}" "${enable_cc}" "${enable_checklist}"

  TEMPLATE_SET_LABEL="profile=${profile}"
  if [[ -n "${integrations}" ]]; then
    TEMPLATE_SET_LABEL="${TEMPLATE_SET_LABEL}, integrations=${integrations}"
  fi
  if [[ "${enable_cc}" -eq 1 ]]; then
    TEMPLATE_SET_LABEL="${TEMPLATE_SET_LABEL}, cc-workflow=on"
  else
    TEMPLATE_SET_LABEL="${TEMPLATE_SET_LABEL}, cc-workflow=off"
  fi
  if [[ "${enable_checklist}" -eq 1 ]]; then
    TEMPLATE_SET_LABEL="${TEMPLATE_SET_LABEL}, test-checklist=on"
  else
    TEMPLATE_SET_LABEL="${TEMPLATE_SET_LABEL}, test-checklist=off"
  fi
}

# Optionally `git init` a freshly scaffolded project. Skips when the directory
# is already a git repository; honors --git yes|no, -y / non-TTY (default yes),
# and --dry-run. Warns and skips if git is not installed.
maybe_init_git() {
  local project_dir="$1"
  local normalized_choice=""

  if [[ -e "${project_dir}/.git" ]]; then
    info "skip git init: ${project_dir} is already a git repository"
    return
  fi

  if [[ -n "${GIT_CHOICE}" ]]; then
    normalized_choice="$(normalize_yes_no "${GIT_CHOICE}")" || die "--git must be yes or no"
    if [[ "${normalized_choice}" != "yes" ]]; then
      info "skip git init (per --git no)"
      return
    fi
  elif ! ask_yes_no "Initialize a git repository?" "yes"; then
    info "skip git init"
    return
  fi

  if ! command -v git >/dev/null 2>&1; then
    warn "git was not found; skipping git init"
    return
  fi

  info "initializing git repository in ${project_dir}"
  # -q because we have already said what is happening: git's own line would be
  # the one thing in the run that does not hang off the gutter.
  run_in_dir "${project_dir}" git init -q
}

# Resolve which profile the scaffolded AGENTS.md is assembled with, and echo it.
# --profile wins; otherwise -y / non-TTY default to "ask" (every profile block
# plus the one-time PROFILE_SETUP note, for the project's AI to resolve later);
# an interactive run is prompted. Nothing is written here — the choice is an
# input to the assembly, not a post-hoc edit of a generated file.
resolve_profile() {
  local choice="" lower=""
  local -a options=()

  if [[ -n "${PROFILE}" ]]; then
    lower="$(printf '%s' "${PROFILE}" | tr '[:upper:]' '[:lower:]')"
  elif [[ "${ASSUME_DEFAULTS}" -eq 1 || ! -t 0 ]]; then
    lower="ask"
  else
    options+=("$(prompt_opt service "Service / backend" "APIs, datastores, long-running")")
    options+=("$(prompt_opt tool "Tool / script" "small CLIs, utilities")")
    options+=("$(prompt_opt ask "Decide later" "keep both, let the project's AI resolve it")")
    choice="$(ui_select "What kind of project is this?" "ask" "${options[@]}")"
    lower="$(printf '%s' "${choice}" | tr '[:upper:]' '[:lower:]')"
  fi

  printf '%s\n' "${lower}"
}

# Resolve whether this run includes the CC-Cowork-Workflow feature, and echo
# 1 or 0. --cc-workflow wins; otherwise -y / non-TTY default to off and an
# interactive run is prompted (default no — it is a Claude-Code-only extra, not
# part of the baseline every project wants).
resolve_cc_workflow() {
  local normalized=""

  if [[ -n "${CC_WORKFLOW_CHOICE}" ]]; then
    normalized="$(normalize_yes_no "${CC_WORKFLOW_CHOICE}")" || die "--cc-workflow must be yes or no"
    if [[ "${normalized}" == "yes" ]]; then
      printf '1\n'
    else
      printf '0\n'
    fi
    return
  fi

  if [[ "${ASSUME_DEFAULTS}" -eq 1 || ! -t 0 ]]; then
    printf '0\n'
    return
  fi

  if ask_yes_no "Include CC-Cowork-Workflow (Claude Code external executor co-work)?" "no"; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

# Resolve whether this run includes the manual test checklist, and echo 1 or 0.
# Same contract as resolve_cc_workflow: --test-checklist wins; otherwise -y /
# non-TTY default to off and an interactive run is prompted (default no — it is
# a page the user fills in by hand, not something every project wants sitting
# in its tree unused).
resolve_test_checklist() {
  local normalized=""

  if [[ -n "${TEST_CHECKLIST_CHOICE}" ]]; then
    normalized="$(normalize_yes_no "${TEST_CHECKLIST_CHOICE}")" || die "--test-checklist must be yes or no"
    if [[ "${normalized}" == "yes" ]]; then
      printf '1\n'
    else
      printf '0\n'
    fi
    return
  fi

  if [[ "${ASSUME_DEFAULTS}" -eq 1 || ! -t 0 ]]; then
    printf '0\n'
    return
  fi

  if ask_yes_no "Include the manual test checklist (Test/templates-test-checklist.html)?" "no"; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

write_project_placeholders() {
  local project_dir="$1"

  # Keep this file list in sync with TEMPLATE_FILES (used by apply mode).
  copy_or_write_placeholder "AGENTS.md" "${project_dir}/AGENTS.md" "$(agents_placeholder)"
  copy_or_write_placeholder "CLAUDE.md" "${project_dir}/CLAUDE.md" "$(claude_placeholder)"
  # Only in the materialized set when the feature is on; guarded here too so an
  # opt-out reads as a choice rather than as a missing template.
  if [[ "${CC_WORKFLOW_ENABLED}" -eq 1 ]]; then
    copy_optional_template "CC-Cowork-Workflow.md" "${project_dir}/CC-Cowork-Workflow.md"
    # The workflow document delegates through this subagent, so the two ship and
    # retire together — a document pointing at an absent agent is worse than neither.
    copy_optional_template ".claude/agents/codex-run.md" "${project_dir}/.claude/agents/codex-run.md"
  fi
  copy_or_write_placeholder ".claude/settings.json" "${project_dir}/.claude/settings.json" "$(claude_settings_placeholder)"
  # Guarded the same way as the CC-Workflow files: only in the materialized set
  # when the feature is on, so an opt-out reads as a choice rather than as a
  # missing template.
  if [[ "${TEST_CHECKLIST_ENABLED}" -eq 1 ]]; then
    copy_optional_template "Test/templates-test-checklist.html" "${project_dir}/Test/templates-test-checklist.html"
  fi
}

# Record what the scaffold just wrote into .vibe-init/manifest. This is the whole
# point of the manifest: the next --apply gets a merge base and can tell "the
# template moved" from "the user edited it" instead of treating every existing
# file as a conflict.
record_scaffold_state() {
  local project_dir="$1"
  local profile="$2"
  local rel="" source_of_truth="" file_hash=""

  STATE_SET_PROFILE="${profile}"
  STATE_SET_INTEGRATIONS="${TEMPLATE_INTEGRATIONS}"
  if [[ "${CC_WORKFLOW_ENABLED}" -eq 1 ]]; then
    STATE_SET_CC="on"
  else
    STATE_SET_CC="off"
  fi
  if [[ "${TEST_CHECKLIST_ENABLED}" -eq 1 ]]; then
    STATE_SET_CHECKLIST="on"
  else
    STATE_SET_CHECKLIST="off"
  fi

  for rel in "${TEMPLATE_FILES[@]}"; do
    # A dry run wrote nothing, so the template is what would have landed; using
    # it here keeps the reported count honest instead of silently zero.
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      source_of_truth="${TEMPLATE_DIR}/${rel}"
    else
      source_of_truth="${project_dir}/${rel}"
    fi
    [[ -f "${source_of_truth}" ]] || continue
    file_hash="$(hash_file "${source_of_truth}")" || continue
    state_record_file "${rel}" "${file_hash}"
    state_record_all_blocks "${source_of_truth}" "${rel}"
  done

  state_flush "${project_dir}"
}

choose_project_dir() {
  local cwd=""
  local project_dir=""

  cwd="$(pwd -P)"

  if is_effectively_empty_dir "${cwd}"; then
    printf '%s\n' "${cwd}"
    return
  fi

  if [[ -z "${PROJECT_NAME}" ]]; then
    PROJECT_NAME="$(ask_value "Current directory is not empty. Project folder name" "")"
  fi
  validate_project_name "${PROJECT_NAME}"

  project_dir="${cwd}/${PROJECT_NAME}"
  if [[ -e "${project_dir}" && ! -d "${project_dir}" ]]; then
    die "target exists and is not a directory: ${project_dir}"
  fi
  if [[ -d "${project_dir}" ]] && ! is_effectively_empty_dir "${project_dir}"; then
    die "target project directory already exists and is not empty: ${project_dir}"
  fi

  ensure_dir "${project_dir}"
  printf '%s\n' "${project_dir}"
}

# Apply mode is non-destructive and never touches git. If the target is not a
# git repository, surface a hint — detection only; we do NOT run git init here.
hint_if_not_git_repo() {
  local target_dir="$1"

  command -v git >/dev/null 2>&1 || return
  if git -C "${target_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return
  fi
  info "note: ${target_dir} is not a git repository; run 'git init' yourself if you want version control (--apply does not)"
}

run_apply_mode() {
  local target_dir=""
  local apply_lib="${SCRIPT_DIR}/lib/apply.sh"

  target_dir="$(pwd -P)"

  # The existing project's shape decides the set, so apply mode never offers a
  # file the project has no use for: the Trellis integration block only for a
  # Trellis-managed project, and the CC-Workflow document only when the project
  # already uses it — unless --cc-workflow says otherwise.
  if [[ -d "${target_dir}/.trellis" ]]; then
    TEMPLATE_INTEGRATIONS="trellis"
  fi
  if [[ -f "${target_dir}/CC-Cowork-Workflow.md" ]]; then
    CC_WORKFLOW_ENABLED=1
  fi
  if [[ -n "${CC_WORKFLOW_CHOICE}" ]]; then
    CC_WORKFLOW_ENABLED="$(resolve_cc_workflow)"
  fi
  # Same rule for the checklist, and by the file rather than the manifest: a
  # project scaffolded before the checklist was optional has no such header,
  # and the file on disk is the honest answer either way.
  if [[ -f "${target_dir}/Test/templates-test-checklist.html" ]]; then
    TEST_CHECKLIST_ENABLED=1
  fi
  if [[ -n "${TEST_CHECKLIST_CHOICE}" ]]; then
    TEST_CHECKLIST_ENABLED="$(resolve_test_checklist)"
  fi

  # Apply mode never prunes profiles: the project's AI resolves that from the
  # codebase, which is also why --profile is rejected with --apply.
  prepare_template_set "ask" "${TEMPLATE_INTEGRATIONS}" "${CC_WORKFLOW_ENABLED}" "${TEST_CHECKLIST_ENABLED}"

  ui_intro "vibe-init" "project orchestrator"

  [[ -f "${apply_lib}" ]] || die "apply library not found: ${apply_lib}"
  # shellcheck source=lib/apply.sh
  . "${apply_lib}"

  orchestrator_dashboard "${target_dir}"

  ui_outro "done  ${target_dir}"
}

main() {
  local project_dir=""
  local normalized_trellis_choice=""
  local install_trellis=0
  local profile=""

  prepare_ui_run_dir

  if [[ -n "${APPLY_FILES}" && "${APPLY_MODE}" -eq 0 ]]; then
    die "--files requires --apply"
  fi

  if [[ -n "${ON_EXISTS}" ]]; then
    [[ "${APPLY_MODE}" -eq 1 ]] || die "--on-exists requires --apply"
    case "${ON_EXISTS}" in
      overwrite|template|skip) ;;
      *) die "--on-exists must be overwrite, template, or skip" ;;
    esac
  fi

  if [[ -n "${PROFILE}" ]]; then
    [[ "${APPLY_MODE}" -eq 0 ]] || die "--profile is not valid with --apply (apply leaves profiles for the AI to resolve)"
    case "$(printf '%s' "${PROFILE}" | tr '[:upper:]' '[:lower:]')" in
      service|tool|ask) ;;
      *) die "--profile must be service, tool, or ask" ;;
    esac
  fi

  # Validated up front (rather than where it is consumed) so a typo fails before
  # the run creates directories or prompts for anything.
  if [[ -n "${CC_WORKFLOW_CHOICE}" ]]; then
    normalize_yes_no "${CC_WORKFLOW_CHOICE}" >/dev/null || die "--cc-workflow must be yes or no"
  fi
  if [[ -n "${TEST_CHECKLIST_CHOICE}" ]]; then
    normalize_yes_no "${TEST_CHECKLIST_CHOICE}" >/dev/null || die "--test-checklist must be yes or no"
  fi

  if [[ "${PROJECT_NAME_POSITIONAL}" -eq 1 && "${APPLY_MODE}" -eq 1 ]]; then
    die "the <PROJECT> name argument is not valid with --apply (--apply targets the current directory)"
  fi

  if [[ "${APPLY_MODE}" -eq 1 ]]; then
    run_apply_mode
    return
  fi

  # Everything the user is asked comes first, cheapest and most fundamental
  # question outward: where the project lives, version control, what kind of
  # project it is, one optional extra, then the heavyweight Trellis block (which
  # asks its own follow-ups and installs software). Nothing is written until the
  # whole shape of the project is settled.
  ui_intro "vibe-init" "AI agent setup for a new project"

  project_dir="$(choose_project_dir)"

  maybe_init_git "${project_dir}"

  # Trellis first among the content questions: it is the heaviest choice, it can
  # install software, and it asks its own follow-ups — all of which belong in one
  # uninterrupted block rather than split around the lighter questions.
  if [[ -n "${TRELLIS_CHOICE}" ]]; then
    normalized_trellis_choice="$(normalize_yes_no "${TRELLIS_CHOICE}")" || die "--trellis must be yes or no"
    if [[ "${normalized_trellis_choice}" == "yes" ]]; then
      install_trellis=1
    fi
  else
    if ask_yes_no "Install and initialize Trellis for this project?" "no"; then
      install_trellis=1
    fi
  fi

  if [[ "${install_trellis}" -eq 1 ]]; then
    resolve_trellis_setup
    if [[ "${TRELLIS_READY}" -eq 1 ]]; then
      TEMPLATE_INTEGRATIONS="trellis"
    else
      # Declined at the install gate: carry on without the integration block.
      install_trellis=0
    fi
  fi

  profile="$(resolve_profile)"

  CC_WORKFLOW_ENABLED="$(resolve_cc_workflow)"
  TEST_CHECKLIST_ENABLED="$(resolve_test_checklist)"

  prepare_template_set "${profile}" "${TEMPLATE_INTEGRATIONS}" "${CC_WORKFLOW_ENABLED}" "${TEST_CHECKLIST_ENABLED}"
  info "template set: ${TEMPLATE_SET_LABEL}"

  if [[ "${install_trellis}" -eq 1 ]]; then
    run_trellis_init "${project_dir}"
  fi

  write_project_placeholders "${project_dir}"
  record_scaffold_state "${project_dir}" "${profile}"

  if [[ "${profile}" == "ask" ]]; then
    info "AGENTS.md keeps every profile block for the project's AI to resolve"
  else
    info "AGENTS.md assembled with the '${profile}' profile"
  fi

  info "next: edit AGENTS.md with real project guidance"
  ui_outro "done  ${project_dir}"
}

main "$@"
