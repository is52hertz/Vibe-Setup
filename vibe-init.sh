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

ASSUME_DEFAULTS=0
DRY_RUN=0
APPLY_MODE=0
# Optional comma/space separated subset of TEMPLATE_FILES to copy in apply mode.
# Empty means "ask interactively" (or "all" under -y / non-TTY). Requires --apply.
APPLY_FILES=""
# How apply mode resolves a file that already exists: overwrite|template|skip.
# Empty means "ask per file" (or "template" under -y / non-TTY). Requires --apply.
ON_EXISTS=""
# Single source of truth for the template files vibe-init manages. apply mode
# iterates this list; the explicit calls in write_project_placeholders must stay
# in sync with it (kept explicit there because each init copy pairs with its own
# built-in placeholder, and bash 3.2 has no reliable associative arrays).
TEMPLATE_FILES=(
  "AGENTS.md"
  "CLAUDE.md"
  "CC-Cowork-Workflow.md"
  ".claude/settings.json"
  "Test/templates-test-checklist.html"
)
PROJECT_NAME=""
TRELLIS_CHOICE=""
# Whether to run `git init` in a freshly scaffolded project. Empty means "ask"
# (default yes); --git yes|no sets it non-interactively. Ignored in --apply mode.
GIT_CHOICE=""
# Honor a default developer name from the environment (e.g. export DEVELOPER_NAME
# in ~/.zshrc). The --developer-name flag still overrides it; an empty value falls
# back to auto-detection (git config user.name, then $USER).
DEVELOPER_NAME="${DEVELOPER_NAME:-}"
TRELLIS_PLATFORMS=""
TEMPLATE_DIR=""
TEMPLATE_DIR_EXPLICIT=0
TRELLIS_INITIALIZED=0

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} [options]

Options:
  --name NAME              Project folder name when current directory is not empty.
  --git yes|no             Whether to run git init in the new project (default: yes).
                           Ignored with --apply. Skipped if already a git repository.
  --trellis yes|no         Whether to install/init Trellis.
  --developer-name NAME    Developer identity passed to: trellis init -u NAME.
                           Defaults to \$DEVELOPER_NAME, then git user.name, then \$USER.
  --platforms "FLAGS"      Trellis platform flags, for example: "--claude --codex".
  --template-dir DIR       Override the template directory. Default: templates/trellis when
                           Trellis is enabled, otherwise templates/base. Missing files fall
                           back to built-in placeholders.
  --apply                  Copy the template files into the CURRENT directory (an existing
                           project) instead of scaffolding a new one. Asks base vs Trellis
                           template set (or use --template-dir), then lists the managed files
                           with their status and asks which to copy. Existing files are left
                           untouched; the copy is written as <name>.template instead.
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
EOF
}

info() {
  printf '[vibe-init] %s\n' "$*" >&2
}

warn() {
  printf '[vibe-init] warning: %s\n' "$*" >&2
}

die() {
  printf '[vibe-init] error: %s\n' "$*" >&2
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
      PROJECT_NAME="$2"
      shift 2
      ;;
    --name=*)
      PROJECT_NAME="${1#*=}"
      require_arg "--name" "${PROJECT_NAME}"
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
    --developer-name)
      require_arg "$1" "${2:-}"
      DEVELOPER_NAME="$2"
      shift 2
      ;;
    --developer-name=*)
      DEVELOPER_NAME="${1#*=}"
      require_arg "--developer-name" "${DEVELOPER_NAME}"
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
      TEMPLATE_DIR="$2"
      TEMPLATE_DIR_EXPLICIT=1
      shift 2
      ;;
    --template-dir=*)
      TEMPLATE_DIR="${1#*=}"
      require_arg "--template-dir" "${TEMPLATE_DIR}"
      TEMPLATE_DIR_EXPLICIT=1
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
      die "unknown option: $1"
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

ask_value() {
  local question="$1"
  local default_value="${2:-}"
  local value=""

  if [[ "${ASSUME_DEFAULTS}" -eq 1 && -n "${default_value}" ]]; then
    printf '%s\n' "${default_value}"
    return
  fi

  if [[ ! -t 0 ]]; then
    [[ -n "${default_value}" ]] || die "missing required value in non-interactive mode: ${question}"
    printf '%s\n' "${default_value}"
    return
  fi

  if [[ -n "${default_value}" ]]; then
    printf '%s [%s]: ' "${question}" "${default_value}" >&2
  else
    printf '%s: ' "${question}" >&2
  fi

  read -r value
  if [[ -z "${value}" ]]; then
    value="${default_value}"
  fi
  printf '%s\n' "${value}"
}

ask_yes_no() {
  local question="$1"
  local default_value="$2"
  local normalized_default=""
  local value=""
  local normalized_value=""
  local prompt_suffix=""

  normalized_default="$(normalize_yes_no "${default_value}")" || die "invalid yes/no default: ${default_value}"

  if [[ "${ASSUME_DEFAULTS}" -eq 1 ]]; then
    [[ "${normalized_default}" == "yes" ]]
    return
  fi

  if [[ ! -t 0 ]]; then
    [[ "${normalized_default}" == "yes" ]]
    return
  fi

  if [[ "${normalized_default}" == "yes" ]]; then
    prompt_suffix='[Y/n]'
  else
    prompt_suffix='[y/N]'
  fi

  while true; do
    printf '%s %s: ' "${question}" "${prompt_suffix}" >&2
    read -r value
    if [[ -z "${value}" ]]; then
      value="${normalized_default}"
    fi
    if normalized_value="$(normalize_yes_no "${value}")"; then
      [[ "${normalized_value}" == "yes" ]]
      return
    fi
    warn "please answer yes or no"
  done
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
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    {
      printf '[vibe-init] dry-run:'
      printf ' %q' "$@"
      printf '\n'
    } >&2
    return
  fi
  "$@"
}

run_in_dir() {
  local dir="$1"
  shift

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    {
      printf '[vibe-init] dry-run: cd %q &&' "${dir}"
      printf ' %q' "$@"
      printf '\n'
    } >&2
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
      info "dry-run: copy ${source} -> ${destination}"
    else
      cp "${source}" "${destination}"
      info "copied ${destination}"
    fi
    return
  fi

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
    info "dry-run: copy ${source} -> ${destination}"
  else
    cp "${source}" "${destination}"
    info "copied ${destination}"
  fi
}

agents_placeholder() {
  cat <<'EOF'
# AGENTS.md

> Placeholder generated by vibe-init. Replace this with project-specific guidance.

## Project Overview

- Purpose: TODO
- Tech stack: TODO
- Important directories: TODO

## Setup Commands

- Install dependencies: TODO
- Run the app: TODO
- Run tests: TODO
- Run lint/typecheck: TODO

## Workflow

- Explore the existing project before editing when context is unclear.
- Prefer small, reviewable, verifiable changes.
- Run the most relevant checks before finishing.
- Leave unrelated files and user changes untouched.

## Code Style

- Follow existing conventions in this repository.
- Keep changes scoped to the requested work.
- Add tests when changing behavior.

## Safety

- Do not read, print, or commit secrets from `.env*`, credentials, private keys, or local-only files.
- Ask before destructive operations, production deployments, or broad dependency upgrades.
EOF
}

claude_placeholder() {
  cat <<'EOF'
@AGENTS.md

## Claude Code

- This file imports AGENTS.md so Claude Code and other coding agents share one source of project instructions.
- Add Claude-specific instructions here only when they are truly needed.
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
    info "dry-run: merge permissions.deny from ${template_settings} into ${settings}"
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

install_and_init_trellis() {
  local project_dir="$1"
  local developer_name="${DEVELOPER_NAME}"
  local default_name=""
  local platform_input="${TRELLIS_PLATFORMS}"
  local normalized_platforms=""
  local platform_args=()
  local installed_version=""

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
  fi
  validate_developer_name "${developer_name}"

  if [[ -z "${platform_input}" ]]; then
    platform_input="$(ask_value "Trellis platform flags" "--claude --codex")"
  fi

  normalized_platforms="${platform_input//,/ }"
  if [[ -n "${normalized_platforms// /}" ]]; then
    IFS=' ' read -r -a platform_args <<< "${normalized_platforms}"
  fi

  # Seed AGENTS.md before trellis init so trellis (skip-existing) preserves our
  # guidance and only manages the TRELLIS block inside it. Done here, after the
  # install gate, so a declined install never leaves a stray TRELLIS block.
  copy_or_write_placeholder "AGENTS.md" "${project_dir}/AGENTS.md" "$(agents_placeholder)"

  local init_args=()
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
  # ${platform_args[@]+...} expands to nothing (not an error) when the array is
  # empty under set -u on bash 3.2.
  run_in_dir "${project_dir}" trellis init "${init_args[@]}" -u "${developer_name}" ${platform_args[@]+"${platform_args[@]}"}

  merge_secret_deny_rules "${project_dir}"
  TRELLIS_INITIALIZED=1
}

resolve_template_dir() {
  local install_trellis="$1"

  if [[ "${TEMPLATE_DIR_EXPLICIT}" -eq 1 ]]; then
    return
  fi

  if [[ "${install_trellis}" -eq 1 ]]; then
    TEMPLATE_DIR="${TEMPLATE_ROOT}/trellis"
  else
    TEMPLATE_DIR="${TEMPLATE_ROOT}/base"
  fi

  if [[ ! -d "${TEMPLATE_DIR}" ]]; then
    warn "template dir not found: ${TEMPLATE_DIR}; falling back to built-in placeholders"
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
  run_in_dir "${project_dir}" git init
}

write_project_placeholders() {
  local project_dir="$1"

  # Keep this file list in sync with TEMPLATE_FILES (used by apply mode).
  copy_or_write_placeholder "AGENTS.md" "${project_dir}/AGENTS.md" "$(agents_placeholder)"
  copy_or_write_placeholder "CLAUDE.md" "${project_dir}/CLAUDE.md" "$(claude_placeholder)"
  copy_optional_template "CC-Cowork-Workflow.md" "${project_dir}/CC-Cowork-Workflow.md"
  copy_or_write_placeholder ".claude/settings.json" "${project_dir}/.claude/settings.json" "$(claude_settings_placeholder)"
  copy_optional_template "Test/templates-test-checklist.html" "${project_dir}/Test/templates-test-checklist.html"
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

  # Pick the source template set. An explicit --template-dir wins; otherwise ask
  # base vs Trellis (ask_yes_no returns the default under -y / non-TTY, i.e. base).
  if [[ "${TEMPLATE_DIR_EXPLICIT}" -eq 1 ]]; then
    resolve_template_dir 0
  elif ask_yes_no "Apply from the Trellis template set instead of base?" "no"; then
    resolve_template_dir 1
  else
    resolve_template_dir 0
  fi

  [[ -f "${apply_lib}" ]] || die "apply library not found: ${apply_lib}"
  # shellcheck source=lib/apply.sh
  . "${apply_lib}"

  info "applying template set: ${TEMPLATE_DIR}"
  apply_templates "${target_dir}"

  hint_if_not_git_repo "${target_dir}"

  info "done"
  info "target directory: ${target_dir}"
}

main() {
  local project_dir=""
  local normalized_trellis_choice=""
  local install_trellis=0

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

  if [[ "${APPLY_MODE}" -eq 1 ]]; then
    run_apply_mode
    return
  fi

  project_dir="$(choose_project_dir)"

  maybe_init_git "${project_dir}"

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
    resolve_template_dir 1
    install_and_init_trellis "${project_dir}"
  fi

  # Use the non-Trellis template set unless Trellis was actually initialized
  # (e.g. the user chose Trellis but declined to install it).
  if [[ "${TRELLIS_INITIALIZED}" -eq 0 ]]; then
    resolve_template_dir 0
  fi

  write_project_placeholders "${project_dir}"

  info "done"
  info "project directory: ${project_dir}"
  info "next: edit AGENTS.md with real project guidance"
}

main "$@"
