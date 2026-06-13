#!/usr/bin/env bash
set -euo pipefail

IFS=$'\n\t'

SCRIPT_NAME="$(basename -- "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
DEFAULT_TEMPLATE_DIR="${SCRIPT_DIR}/templates"

ASSUME_DEFAULTS=0
DRY_RUN=0
PROJECT_NAME=""
TRELLIS_CHOICE=""
DEVELOPER_NAME=""
TRELLIS_PLATFORMS=""
TEMPLATE_DIR="${DEFAULT_TEMPLATE_DIR}"

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} [options]

Options:
  --name NAME              Project folder name when current directory is not empty.
  --trellis yes|no         Whether to install/init Trellis.
  --developer-name NAME    Developer identity passed to: trellis init -u NAME.
  --platforms "FLAGS"      Trellis platform flags, for example: "--claude --codex".
  --template-dir DIR       Optional template directory. Missing templates use placeholders.
  -y, --yes                Accept safe defaults for prompts.
  --dry-run                Print actions without writing files or running installers.
  -h, --help               Show this help.

Behavior:
  - If the current directory is effectively empty, initialize in ".".
  - If it is not empty, create a project folder under the current directory.
  - The script ignores itself, .DS_Store, and .localized when checking emptiness.
  - Existing project files are skipped, not overwritten.
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
      shift
      ;;
    --trellis)
      require_arg "$1" "${2:-}"
      TRELLIS_CHOICE="$2"
      shift 2
      ;;
    --trellis=*)
      TRELLIS_CHOICE="${1#*=}"
      shift
      ;;
    --developer-name)
      require_arg "$1" "${2:-}"
      DEVELOPER_NAME="$2"
      shift 2
      ;;
    --developer-name=*)
      DEVELOPER_NAME="${1#*=}"
      shift
      ;;
    --platforms)
      require_arg "$1" "${2:-}"
      TRELLIS_PLATFORMS="$2"
      shift 2
      ;;
    --platforms=*)
      TRELLIS_PLATFORMS="${1#*=}"
      shift
      ;;
    --template-dir)
      require_arg "$1" "${2:-}"
      TEMPLATE_DIR="$2"
      shift 2
      ;;
    --template-dir=*)
      TEMPLATE_DIR="${1#*=}"
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

## Trellis

- If `.trellis/` exists, follow `.trellis/workflow.md` and use the active task context.
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

  info "initializing Trellis in ${project_dir}"
  run_in_dir "${project_dir}" trellis init -u "${developer_name}" "${platform_args[@]}"
}

write_project_placeholders() {
  local project_dir="$1"

  copy_or_write_placeholder "AGENTS.md" "${project_dir}/AGENTS.md" "$(agents_placeholder)"
  copy_or_write_placeholder "CLAUDE.md" "${project_dir}/CLAUDE.md" "$(claude_placeholder)"
  copy_or_write_placeholder ".claude/settings.json" "${project_dir}/.claude/settings.json" "$(claude_settings_placeholder)"
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

main() {
  local project_dir=""
  local normalized_trellis_choice=""
  local install_trellis=0

  project_dir="$(choose_project_dir)"
  ensure_dir "${project_dir}"

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
    install_and_init_trellis "${project_dir}"
  fi

  write_project_placeholders "${project_dir}"

  info "done"
  info "project directory: ${project_dir}"
  info "next: edit AGENTS.md with real project guidance"
}

main "$@"
