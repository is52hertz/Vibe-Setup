#!/usr/bin/env bash
# lib/apply.sh — Project Orchestrator & Template Manager for existing projects.
# Sourced by vibe-init.sh (not run standalone).
# Compatible with macOS Bash 3.2.

# Source helper modules if not already loaded
if ! command -v ui_box_start >/dev/null 2>&1; then
  [[ -f "${SCRIPT_DIR}/lib/ui.sh" ]] && . "${SCRIPT_DIR}/lib/ui.sh"
fi
if ! command -v has_block >/dev/null 2>&1; then
  [[ -f "${SCRIPT_DIR}/lib/block_engine.sh" ]] && . "${SCRIPT_DIR}/lib/block_engine.sh"
fi
if ! command -v trellis_is_installed >/dev/null 2>&1; then
  [[ -f "${SCRIPT_DIR}/lib/trellis.sh" ]] && . "${SCRIPT_DIR}/lib/trellis.sh"
fi

APPLY_SELECTED=()
APPLIED_TEMPLATES=()
RESOLVED_DISPOSITION=""

resolve_on_exists() {
  local relative_path="$1"
  local input=""
  local default_choice="t"

  if [[ -n "${ON_EXISTS}" ]]; then
    RESOLVED_DISPOSITION="${ON_EXISTS}"
    return
  fi
  if [[ "${ASSUME_DEFAULTS}" -eq 1 || ! -t 0 ]]; then
    RESOLVED_DISPOSITION="template"
    return
  fi

  while true; do
    input="$(ask_value "${relative_path} exists — [o]verwrite / [t]emplate / [s]kip?" "${default_choice}")"
    case "${input}" in
      o|overwrite) RESOLVED_DISPOSITION="overwrite"; return ;;
      t|template)  RESOLVED_DISPOSITION="template";  return ;;
      s|skip)      RESOLVED_DISPOSITION="skip";      return ;;
      *) warn "please answer o, t, or s" ;;
    esac
  done
}

copy_template_file() {
  local relative_path="$1"
  local destination="$2"
  local disposition="$3"
  local source="${TEMPLATE_DIR}/${relative_path}"
  local target="${destination}"
  local is_template=0

  if [[ ! -f "${source}" ]]; then
    info "skip ${relative_path}: not present in template dir"
    return
  fi

  if [[ -e "${destination}" ]]; then
    case "${disposition}" in
      overwrite)
        target="${destination}"
        ;;
      skip)
        info "skip ${relative_path}: ${destination} exists (kept)"
        return
        ;;
      template|*)
        target="${destination}.template"
        if [[ -e "${target}" ]]; then
          warn "skip ${relative_path}: both ${destination} and ${target} exist (won't overwrite)"
          return
        fi
        is_template=1
        ;;
    esac
  fi

  ensure_dir "$(dirname -- "${target}")"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run: copy ${source} -> ${target}"
  else
    cp "${source}" "${target}"
    info "copied ${target}"
  fi

  if [[ "${is_template}" -eq 1 ]]; then
    APPLIED_TEMPLATES+=("${relative_path}")
  fi
}

apply_file_status() {
  local relative_path="$1"
  local project_dir="$2"

  if [[ ! -f "${TEMPLATE_DIR}/${relative_path}" ]]; then
    printf 'missing-source\n'
  elif [[ -e "${project_dir}/${relative_path}" ]]; then
    printf 'exists\n'
  else
    printf 'new\n'
  fi
}

select_from_files_flag() {
  local raw="${APPLY_FILES//,/ }"
  local want="" rel="" known="" known_list=""
  local -a requested=()

  IFS=' ' read -r -a requested <<< "${raw}"
  known_list="$(IFS=' '; printf '%s' "${TEMPLATE_FILES[*]}")"
  APPLY_SELECTED=()

  for want in "${requested[@]+"${requested[@]}"}"; do
    known=0
    for rel in "${TEMPLATE_FILES[@]}"; do
      if [[ "${rel}" == "${want}" ]]; then
        known=1
        break
      fi
    done
    [[ "${known}" -eq 1 ]] || die "--files: unknown template file: ${want} (known: ${known_list})"

    if [[ ! -f "${TEMPLATE_DIR}/${want}" ]]; then
      warn "skip ${want}: not present in template set ${TEMPLATE_DIR}"
      continue
    fi
    APPLY_SELECTED+=("${want}")
  done
}

choose_apply_files() {
  local project_dir="$1"
  local rel="" status="" label="" input="" token="" ok=""
  local -a available=()
  local -a tokens=()

  if [[ -n "${APPLY_FILES}" ]]; then
    select_from_files_flag
    return
  fi

  printf '[vibe-init] template files (set: %s):\n' "${TEMPLATE_DIR}" >&2
  for rel in "${TEMPLATE_FILES[@]}"; do
    status="$(apply_file_status "${rel}" "${project_dir}")"
    case "${status}" in
      exists)
        if [[ -n "${ON_EXISTS}" ]]; then
          label="already exists -> ${ON_EXISTS}"
        else
          label="already exists (choose overwrite / template / skip)"
        fi
        ;;
      new)
        label="new -> creates ${rel}"
        ;;
      missing-source)
        printf '       %-38s %s\n' "${rel}" "(not in this template set)" >&2
        continue
        ;;
    esac
    available+=("${rel}")
    printf '  [%d]  %-38s %s\n' "${#available[@]}" "${rel}" "${label}" >&2
  done

  if [[ "${#available[@]}" -eq 0 ]]; then
    APPLY_SELECTED=()
    return
  fi

  if [[ "${ASSUME_DEFAULTS}" -eq 1 || ! -t 0 ]]; then
    APPLY_SELECTED=("${available[@]}")
    return
  fi

  if ask_yes_no "Copy all of these files?" "yes"; then
    APPLY_SELECTED=("${available[@]}")
    return
  fi

  while true; do
    input="$(ask_value "Enter numbers to copy (e.g. 1 3), or 'all'" "all")"
    if [[ "${input}" == "all" ]]; then
      APPLY_SELECTED=("${available[@]}")
      return
    fi

    input="${input//,/ }"
    IFS=' ' read -r -a tokens <<< "${input}"
    if [[ "${#tokens[@]}" -eq 0 ]]; then
      warn "please enter one or more valid numbers"
      continue
    fi

    APPLY_SELECTED=()
    ok=1
    for token in "${tokens[@]}"; do
      if [[ "${token}" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#available[@]} )); then
        APPLY_SELECTED+=("${available[$((token - 1))]}")
      else
        warn "invalid selection: ${token}"
        ok=0
        break
      fi
    done

    if [[ "${ok}" -eq 1 && "${#APPLY_SELECTED[@]}" -gt 0 ]]; then
      return
    fi
    warn "please enter one or more valid numbers"
  done
}

apply_templates() {
  local project_dir="$1"
  local rel="" destination="" disposition=""

  choose_apply_files "${project_dir}"

  if [[ "${#APPLY_SELECTED[@]}" -eq 0 ]]; then
    info "no files selected; nothing to apply"
    return
  fi

  for rel in "${APPLY_SELECTED[@]}"; do
    destination="${project_dir}/${rel}"
    disposition="template"

    if [[ -e "${destination}" ]]; then
      resolve_on_exists "${rel}"
      disposition="${RESOLVED_DISPOSITION}"
    fi
    copy_template_file "${rel}" "${destination}" "${disposition}"
  done
}

suggest_template_merges() {
  local rel="" count="" noun="files were"

  count="${#APPLIED_TEMPLATES[@]}"
  [[ "${count}" -gt 0 ]] || return 0
  [[ "${count}" -eq 1 ]] && noun="file was"

  info "${count} ${noun} written as <name>.template beside an existing file."
  info "copy the prompt between the lines below and give it to your AI agent:"

  {
    printf '%s\n' "────────── suggested prompt for your AI agent ──────────"
    printf '%s\n' "Bring my files up to date with vibe-init's latest templates. For each pair,"
    printf '%s\n' "the .template is the NEW template version and the plain file is MY current"
    printf '%s\n' "one (which may hold my customizations):"
    for rel in "${APPLIED_TEMPLATES[@]}"; do
      printf '  - %s.template  ->  %s\n' "${rel}" "${rel}"
    done
    printf '%s\n' "Merge the template into my file: keep my customizations, fold in new/changed"
    printf '%s\n' "guidance, and respect each file's format (e.g. JSON for settings). Where they"
    printf '%s\n' "genuinely conflict, do not choose silently — list each conflict and ask me to"
    printf '%s\n' "decide. When you ask me anything, write it in Simplified Chinese (中文); keep"
    printf '%s\n' "code, identifiers, and your own reasoning in English. After I confirm, delete"
    printf '%s\n' "the .template files."
    printf '%s\n' "────────────────────────────────────────────────────────"
  } >&2
}

# -----------------------------------------------------------------------------
# Diagnostics & Dashboard
# -----------------------------------------------------------------------------

show_project_diagnostics() {
  local project_dir="$1"
  local git_status="Not initialized"
  local branch=""
  local trellis_status="Not configured"
  local trellis_tools="None"
  local cc_workflow_status="Disabled"
  local agents_status="Missing"

  # Git check
  if command -v git >/dev/null 2>&1 && git -C "${project_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch="$(git -C "${project_dir}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "git")"
    git_status="Initialized (${branch})"
  fi

  # Trellis check
  local p_ver c_ver
  c_ver="$(trellis_cli_version || echo "none")"
  if trellis_has_project "${project_dir}"; then
    p_ver="$(trellis_project_version "${project_dir}" || echo "unknown")"
    trellis_status="Active (Project v${p_ver} / CLI v${c_ver})"
    trellis_tools="$(trellis_configured_platforms "${project_dir}")"
  elif [[ "${c_ver}" != "none" ]]; then
    trellis_status="Not initialized (CLI v${c_ver} ready)"
  else
    trellis_status="CLI not installed"
  fi

  # CC-Workflow check
  if [[ -f "${project_dir}/CC-Cowork-Workflow.md" ]]; then
    cc_workflow_status="Active"
  fi

  # AGENTS.md check
  if [[ -f "${project_dir}/AGENTS.md" ]]; then
    if has_block "${project_dir}/AGENTS.md" "CORE_RULES"; then
      agents_status="Modern (<TAG> format)"
    else
      agents_status="Present (Legacy format)"
    fi
  fi

  ui_box_start "Project AI Environment Status"
  ui_box_row "Git Repo" "${git_status}"
  ui_box_row "Trellis" "${trellis_status}"
  ui_box_row "Trellis Tools" "${trellis_tools}"
  ui_box_row "CC-Workflow" "${cc_workflow_status}"
  ui_box_row "AGENTS.md" "${agents_status}"
  ui_box_end
}

# -----------------------------------------------------------------------------
# Feature Toggles: CC-Workflow
# -----------------------------------------------------------------------------

toggle_cc_workflow() {
  local project_dir="$1"
  local current_state=0
  local choice=""

  [[ -f "${project_dir}/CC-Cowork-Workflow.md" ]] && current_state=1

  if [[ "${current_state}" -eq 1 ]]; then
    ui_warn "CC-Workflow is currently ENABLED."
    if ask_yes_no "Disable CC-Workflow and backup the workflow file?" "yes"; then
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        ui_info "dry-run: mv ${project_dir}/CC-Cowork-Workflow.md -> ${project_dir}/CC-Cowork-Workflow.md.disabled"
        ui_info "dry-run: remove CC-Workflow reference from ${project_dir}/CLAUDE.md"
      else
        mv "${project_dir}/CC-Cowork-Workflow.md" "${project_dir}/CC-Cowork-Workflow.md.disabled"
        if [[ -f "${project_dir}/CLAUDE.md" ]]; then
          remove_block "${project_dir}/CLAUDE.md" "FEATURE" "cc-workflow"
        fi
        ui_ok "CC-Workflow disabled. File backed up to CC-Cowork-Workflow.md.disabled"
      fi
    fi
  else
    ui_info "CC-Workflow is currently DISABLED."
    if ask_yes_no "Enable CC-Workflow and inject into CLAUDE.md?" "yes"; then
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        ui_info "dry-run: copy CC-Cowork-Workflow.md into project"
        ui_info "dry-run: inject CC-Workflow block into CLAUDE.md"
      else
        cp "${TEMPLATE_ROOT}/CC-Cowork-Workflow.md" "${project_dir}/CC-Cowork-Workflow.md"
        if [[ -f "${project_dir}/CLAUDE.md" ]]; then
          append_block_if_missing "${project_dir}/CLAUDE.md" "FEATURE" "cc-workflow" "${TEMPLATE_ROOT}/blocks/features/cc-workflow.md"
        else
          assemble_claude_md "${project_dir}/CLAUDE.md" 1
        fi
        ui_ok "CC-Workflow enabled and linked."
      fi
    fi
  fi
}

# -----------------------------------------------------------------------------
# Trellis Operations Menu
# -----------------------------------------------------------------------------

manage_trellis() {
  local project_dir="$1"
  local choice=""

  if ! trellis_has_project "${project_dir}"; then
    ui_warn "Trellis is not initialized in this project."
    if ask_yes_no "Initialize Trellis now?" "yes"; then
      install_and_init_trellis "${project_dir}"
    fi
    return
  fi

  while true; do
    printf '\n%s--- Trellis Management ---%s\n' "${UI_BOLD}" "${UI_RESET}" >&2
    printf '  [1] Add AI platform(s) (e.g. --codex, --cursor)\n' >&2
    printf '  [2] Update project configuration (trellis update)\n' >&2
    printf '  [3] Upgrade global Trellis CLI\n' >&2
    printf '  [0] Return to main menu\n' >&2

    choice="$(ask_value "Select an option" "0")"
    case "${choice}" in
      1)
        local plat
        plat="$(ask_value "Enter platform flag (e.g. --cursor, --codex)" "--cursor")"
        if [[ -n "${plat}" ]]; then
          trellis_add_platform "${project_dir}" "${plat}"
        fi
        ;;
      2)
        trellis_update_project "${project_dir}"
        ;;
      3)
        trellis_upgrade_cli
        ;;
      0|q|quit)
        break
        ;;
      *)
        ui_warn "Invalid selection."
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Interactive Dashboard Main Hub
# -----------------------------------------------------------------------------

orchestrator_dashboard() {
  local project_dir="$1"
  local choice=""

  show_project_diagnostics "${project_dir}"

  # In non-interactive mode or if specific flags were given, fall back to safe standard apply
  if [[ "${ASSUME_DEFAULTS}" -eq 1 || ! -t 0 || -n "${APPLY_FILES}" || -n "${ON_EXISTS}" ]]; then
    apply_templates "${project_dir}"
    suggest_template_merges
    hint_if_not_git_repo "${project_dir}"
    return
  fi

  while true; do
    ui_banner "Project Orchestrator Dashboard"
    show_project_diagnostics "${project_dir}"

    printf '\n%sActions:%s\n' "${UI_BOLD}" "${UI_RESET}" >&2
    printf '  [1] 📋 Sync / Apply Template Files (AGENTS.md, CLAUDE.md, etc.)\n' >&2
    printf '  [2] 🌿 Trellis Management (Platforms, Updates, Upgrade)\n' >&2
    printf '  [3] ⚙️  Toggle CC-Workflow Feature\n' >&2
    printf '  [4] 🚀 Safe Sync All (Templates + Checks)\n' >&2
    printf '  [0] Exit\n\n' >&2

    choice="$(ask_value "Select action" "1")"
    case "${choice}" in
      1)
        apply_templates "${project_dir}"
        suggest_template_merges
        ;;
      2)
        manage_trellis "${project_dir}"
        ;;
      3)
        toggle_cc_workflow "${project_dir}"
        ;;
      4)
        apply_templates "${project_dir}"
        suggest_template_merges
        if trellis_has_project "${project_dir}"; then
          trellis_update_project "${project_dir}"
        fi
        ui_ok "All sync tasks finished."
        break
        ;;
      0|q|exit)
        ui_info "Exiting."
        break
        ;;
      *)
        ui_warn "Invalid choice."
        ;;
    esac
  done

  hint_if_not_git_repo "${project_dir}"
}
