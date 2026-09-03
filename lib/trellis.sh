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

trellis_update_project() {
  local project_dir="$1"

  if ! trellis_is_installed; then
    ui_error "Trellis CLI is not installed."
    return 1
  fi

  ui_info "Updating Trellis configuration in ${project_dir}..."
  run_in_dir "${project_dir}" trellis update
}

trellis_upgrade_cli() {
  if ! command -v npm >/dev/null 2>&1; then
    ui_error "npm not found. Cannot upgrade Trellis."
    return 1
  fi

  ui_info "Upgrading Trellis CLI (npm install -g @mindfoldhq/trellis)..."
  run_cmd npm install -g @mindfoldhq/trellis
}
