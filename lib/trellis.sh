#!/usr/bin/env bash
# lib/trellis.sh — Trellis diagnosis, inspection, and operations.
# Compatible with macOS Bash 3.2. Sourced by vibe-init.sh and lib/apply.sh.

trellis_is_installed() {
  command -v trellis >/dev/null 2>&1
}

trellis_cli_version() {
  if ! trellis_is_installed; then
    return 1
  fi
  trellis --version 2>/dev/null | awk 'NF { print; found=1; exit } END { exit found ? 0 : 1 }'
}

trellis_has_project() {
  local project_dir="$1"
  [[ -d "${project_dir}/.trellis" ]]
}

trellis_project_version() {
  local project_dir="$1"
  local ver_file="${project_dir}/.trellis/.version"

  if [[ -f "${ver_file}" ]]; then
    tr -d '[:space:]' < "${ver_file}"
    return 0
  fi

  if [[ -d "${project_dir}/.trellis" ]]; then
    printf 'legacy\n'
    return 0
  fi

  return 1
}

trellis_configured_platforms() {
  local project_dir="$1"
  local -a platforms=()

  if trellis_is_installed && trellis_has_project "${project_dir}"; then
    # Try trellis platforms --json
    local json_out=""
    json_out="$( (cd "${project_dir}" && trellis platforms --json 2>/dev/null) || true )"
    if [[ -n "${json_out}" ]] && command -v python3 >/dev/null 2>&1; then
      local parsed=""
      parsed="$(python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
    plats = [p.get("displayName", p.get("id")) for p in data.get("platforms", [])]
    print(", ".join(plats))
except Exception:
    pass
' <<< "${json_out}")"
      if [[ -n "${parsed}" ]]; then
        printf '%s\n' "${parsed}"
        return 0
      fi
    fi
  fi

  # Fallback to directory inspection
  [[ -d "${project_dir}/.claude" ]] && platforms+=("Claude Code")
  [[ -d "${project_dir}/.codex" ]] && platforms+=("Codex")
  [[ -d "${project_dir}/.cursor" ]] && platforms+=("Cursor")
  [[ -d "${project_dir}/.opencode" ]] && platforms+=("OpenCode")
  [[ -d "${project_dir}/.gemini" ]] && platforms+=("Gemini CLI")

  if [[ "${#platforms[@]}" -gt 0 ]]; then
    local IFS=", "
    printf '%s\n' "${platforms[*]}"
  else
    printf 'None\n'
  fi
}

trellis_add_platform() {
  local project_dir="$1"
  local platform_flag="$2" # e.g. "--codex" or "--cursor"

  if ! trellis_is_installed; then
    ui_error "Trellis CLI is not installed."
    return 1
  fi

  ui_info "Adding platform ${platform_flag} via Trellis..."
  # Running trellis init without --skip-existing triggers handleReinit (add platform) safely
  run_in_dir "${project_dir}" trellis init "${platform_flag}"
}

# Run `trellis update` against the project.
#
# `trellis update` is not a no-op when there is nothing to update: it rescans
# every managed file, prints the whole inventory, and stops to ask about each
# file the user has edited. On a project already at the CLI's version that is a
# long interrogation for no gain, and "Sync everything and exit" used to walk
# into it every single time. So when the two versions match, say so and ask
# first — the answer defaults to no, and a scripted run therefore skips it.
# True when `trellis update` would actually move the project: it has a Trellis
# directory, the CLI is installed, and the two versions differ. The menu reveals
# it and the gate below asks about its inverse, so the comparison lives in one
# place rather than two that can drift.
trellis_update_pending() {
  local project_dir="$1"
  local cli_version="" project_version=""

  trellis_has_project "${project_dir}" || return 1
  cli_version="$(trellis_cli_version || true)"
  [[ -n "${cli_version}" ]] || return 1
  project_version="$(trellis_project_version "${project_dir}" 2>/dev/null || true)"
  [[ -n "${project_version}" ]] || return 0
  [[ "${project_version}" != "${cli_version}" ]]
}

trellis_update_project() {
  local project_dir="$1"
  local project_version=""

  if ! trellis_is_installed; then
    ui_error "Trellis CLI is not installed."
    return 1
  fi

  if ! trellis_update_pending "${project_dir}"; then
    project_version="$(trellis_project_version "${project_dir}" 2>/dev/null || true)"
    ui_info "Trellis is already at v${project_version}; an update would only re-scan"
    ui_info "and ask about the files you have edited."
    ask_yes_no "Run 'trellis update' anyway?" "no" || return 0
  fi

  ui_info "Updating Trellis configuration in ${project_dir}..."
  run_in_dir "${project_dir}" trellis update
}

# Taking Trellis out of a project comes in two kinds, because the work it holds
# matters very differently. On a project just started, .trellis/ is little more
# than scaffolding. Mid-project it holds the task PRDs, specs, journals and
# memory, and `trellis uninstall` deletes all of it with no backup. Trellis
# ships the reversible kind itself — `ablate` moves every Trellis surface out
# and keeps a recovery transaction under ~/.trellis, `restore` puts the project
# back byte for byte — so pausing is that, not a copy this tool would have to
# keep in step with Trellis's own layout.
#
# None of these pass --yes: Trellis asks, and refuses a scripted uninstall while
# .trellis/ holds uncommitted work.

# True when .trellis/ holds user work that git could not give back after an
# uninstall: the project is not a repository, or something under spec/, tasks/
# or workspace/ — where Trellis keeps that work — is uncommitted or ignored.
# Usage: trellis_has_unprotected_data <project_dir>
trellis_has_unprotected_data() {
  local project_dir="$1"
  local dir="" found=0
  local -a data_dirs=()

  for dir in spec tasks workspace; do
    if [[ -d "${project_dir}/.trellis/${dir}" ]]; then
      data_dirs+=(".trellis/${dir}")
      found=1
    fi
  done
  [[ "${found}" -eq 1 ]] || return 1

  if ! command -v git >/dev/null 2>&1 \
      || ! git -C "${project_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  [[ -n "$(git -C "${project_dir}" status --porcelain --ignored -- "${data_dirs[@]}" 2>/dev/null)" ]]
}

# Pause Trellis: `trellis ablate`, which Trellis can undo.
# Usage: trellis_pause_project <project_dir>
trellis_pause_project() {
  local project_dir="$1"

  if ! trellis_is_installed; then
    ui_error "Trellis CLI is not installed."
    return 1
  fi
  ui_info "Pausing moves every Trellis file out of the project and keeps a recovery"
  ui_info "copy in ~/.trellis on this machine; Restore brings back tasks, specs,"
  ui_info "journals and memory exactly as they are now."
  run_in_dir "${project_dir}" trellis ablate
}

# Undo a pause: `trellis restore`. Trellis itself reports when there is nothing
# to restore, which also covers a pause made outside this tool.
# Usage: trellis_restore_project <project_dir>
trellis_restore_project() {
  local project_dir="$1"

  if ! trellis_is_installed; then
    ui_error "Trellis CLI is not installed."
    return 1
  fi
  run_in_dir "${project_dir}" trellis restore
}

# Remove Trellis for good: `trellis uninstall`. When the work under .trellis/
# is not safe in git, say what is lost and ask first — the answer defaults to
# no, and pausing is named as the way to keep it.
# Usage: trellis_uninstall_project <project_dir>
trellis_uninstall_project() {
  local project_dir="$1"

  if ! trellis_is_installed; then
    ui_error "Trellis CLI is not installed."
    return 1
  fi
  if trellis_has_unprotected_data "${project_dir}"; then
    ui_warn "The tasks, specs, journals and memory under .trellis/ are not all committed."
    ui_warn "Uninstalling deletes them permanently. To keep them, pause Trellis instead,"
    ui_warn "or commit .trellis/ first."
    ask_yes_no "Uninstall and delete them anyway?" "no" || return 1
  fi
  run_in_dir "${project_dir}" trellis uninstall
}

trellis_upgrade_cli() {
  if ! command -v npm >/dev/null 2>&1; then
    ui_error "npm not found. Cannot upgrade Trellis."
    return 1
  fi

  ui_info "Upgrading Trellis CLI (npm install -g @mindfoldhq/trellis)..."
  run_cmd npm install -g @mindfoldhq/trellis
}
