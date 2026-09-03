#!/usr/bin/env bash
# lib/apply.sh — the orchestrator dashboard for an EXISTING project.
#
# Sourced by vibe-init.sh (not run standalone). Relies on helpers and globals
# defined there: info, warn, die, ensure_dir, ask_yes_no, ask_value, run_cmd,
# run_in_dir, DRY_RUN, ASSUME_DEFAULTS, TEMPLATE_DIR, TEMPLATE_SET_LABEL,
# TEMPLATE_FILES, TEMPLATE_INTEGRATIONS, CC_WORKFLOW_ENABLED, APPLY_FILES,
# ON_EXISTS — plus lib/ui.sh, lib/block_engine.sh and lib/trellis.sh.
#
# Two shapes, one for each way the command is used:
#
#   Non-interactive (-y, no TTY, or a --files / --on-exists policy): print the
#   diagnostics once and do the safe standard sync, so scripts keep working.
#
#   Interactive: a dashboard loop — project diagnostics, then template sync,
#   Trellis lifecycle management, and feature toggles, until the user exits.
#
# Copying is non-destructive throughout. For a file that already exists in the
# target the user chooses per file: overwrite it, write the template alongside
# as <name>.template, or skip it. The default (and the -y / non-TTY behavior) is
# the non-destructive <name>.template; --on-exists sets it for the whole run.
#
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

# Files chosen for this apply run (relative paths). Declared so expansions are
# safe under set -u before choose_apply_files populates it.
APPLY_SELECTED=()

# Relative paths that were written as <name>.template because the target already
# existed and the user chose / defaulted to the non-destructive template
# disposition. Drives the end-of-run "merge these into your real files" hint.
APPLIED_TEMPLATES=()

# How the most recent resolve_on_exists call decided to handle a pre-existing
# file: "overwrite" | "template" | "skip".
RESOLVED_DISPOSITION=""

# Decide how to handle a pre-existing destination for one file; sets
# RESOLVED_DISPOSITION to "overwrite" | "template" | "skip". A run-wide policy
# (ON_EXISTS, from --on-exists) wins; otherwise -y / non-TTY default to the
# non-destructive "template"; otherwise ask per file (default template).
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

# Copy one template file into the target project. When the destination already
# exists, `disposition` ("overwrite" | "template" | "skip") decides what happens:
#   - source missing in the template set -> skip (info)
#   - destination does not exist          -> copy to destination
#   - exists + overwrite                  -> copy over destination
#   - exists + template                   -> copy to <destination>.template
#                                            (skip + warn if that also exists)
#   - exists + skip                       -> leave the existing file untouched
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

# Classify a managed file relative to the target project. Echoes one of:
#   missing-source  source absent in this template set (cannot be copied)
#   exists          target already present (a copy would land as <rel>.template)
#   new             target absent (a copy would create <rel>)
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

# Resolve the --files list (APPLY_FILES, comma/space separated) into
# APPLY_SELECTED. Dies on an unknown path; warns and skips a known path whose
# source is absent in the assembled template set.
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
      warn "skip ${want}: not part of this template set (${TEMPLATE_SET_LABEL})"
      continue
    fi
    APPLY_SELECTED+=("${want}")
  done
}

# Let the user choose which managed files to copy; populates APPLY_SELECTED.
choose_apply_files() {
  local project_dir="$1"
  local rel="" status="" label="" input="" token="" ok=""
  local -a available=()
  local -a tokens=()

  # Non-interactive subset wins over any prompting.
  if [[ -n "${APPLY_FILES}" ]]; then
    select_from_files_flag
    return
  fi

  # List every managed file with its status; only files with a present source
  # are selectable (numbered).
  printf '[vibe-init] template files (set: %s):\n' "${TEMPLATE_SET_LABEL}" >&2
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

# Copy the selected files, resolving each pre-existing destination first.
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

# When files were written as <name>.template, print a ready-to-paste prompt that
# asks the user's own AI agent to merge each template into the real file.
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

# Turn the CC-Workflow feature on or off for an existing project: the
# CC-Cowork-Workflow.md document plus the <FEATURE id="cc-workflow"> block in
# CLAUDE.md that points at it. Disabling archives the document rather than
# deleting it — the user may have edited it.
#
# A CLAUDE.md written before the block markers existed carries the reference as
# plain prose. That cannot be removed safely by machine, so it is reported for
# the user to delete rather than silently left behind as a dangling pointer.
toggle_cc_workflow() {
  local project_dir="$1"
  local claude_md="${project_dir}/CLAUDE.md"
  local workflow="${project_dir}/CC-Cowork-Workflow.md"
  local ref_block="${TEMPLATE_ROOT}/blocks/features/cc-workflow/claude-ref.md"
  local variant="" source=""

  if [[ -f "${workflow}" ]]; then
    ui_warn "CC-Workflow is currently ENABLED."
    ask_yes_no "Disable CC-Workflow and archive the workflow file?" "yes" || return

    if [[ "${DRY_RUN}" -eq 1 ]]; then
      ui_info "dry-run: mv ${workflow} -> ${workflow}.disabled"
      ui_info "dry-run: remove the CC-Workflow block from ${claude_md}"
      return
    fi

    mv "${workflow}" "${workflow}.disabled"
    ui_ok "Archived the workflow file as CC-Cowork-Workflow.md.disabled"

    if [[ ! -f "${claude_md}" ]]; then
      return
    fi
    if remove_block "${claude_md}" "FEATURE" "cc-workflow"; then
      ui_ok "Removed the CC-Workflow block from CLAUDE.md."
    elif grep -q 'CC-Cowork-Workflow' "${claude_md}"; then
      ui_warn "CLAUDE.md still mentions CC-Cowork-Workflow.md, but carries no"
      ui_warn "<FEATURE id=\"cc-workflow\"> block to remove (pre-block format)."
      ui_warn "Delete that section by hand, or the file will point at an archived document:"
      grep -n 'CC-Cowork-Workflow' "${claude_md}" >&2
    fi
    return
  fi

  ui_info "CC-Workflow is currently DISABLED."
  ask_yes_no "Enable CC-Workflow and reference it from CLAUDE.md?" "yes" || return

  # The Trellis variant spells the loop in Trellis commands; pick by what the
  # project actually is, not by whatever the last run happened to assemble.
  variant="base"
  if trellis_has_project "${project_dir}"; then
    variant="trellis"
  fi
  source="${TEMPLATE_ROOT}/blocks/features/cc-workflow/${variant}.md"

  if [[ ! -f "${source}" ]]; then
    ui_error "CC-Workflow template not found: ${source}"
    return
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    ui_info "dry-run: copy ${source} -> ${workflow}"
    ui_info "dry-run: reference the CC-Workflow block from ${claude_md}"
    return
  fi

  cp "${source}" "${workflow}"
  if [[ -f "${claude_md}" ]]; then
    append_block_if_missing "${claude_md}" "FEATURE" "cc-workflow" "${ref_block}"
  else
    assemble_claude_md "${claude_md}" 1
  fi
  ui_ok "CC-Workflow enabled (${variant} variant) and referenced from CLAUDE.md."
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
    printf '  [0] Return to dashboard\n' >&2

    choice="$(ask_value "Select Trellis action" "0")"
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
# Trellis integration block
# -----------------------------------------------------------------------------

# Add or drop <INTEGRATION id="trellis"> in the project's AGENTS.md — the block
# that tells every agent how this file and Trellis divide authority. Rebuilds the
# template set afterwards so a later sync in the same session stays consistent.
toggle_trellis_integration() {
  local project_dir="$1"
  local agents="${project_dir}/AGENTS.md"
  local block="${TEMPLATE_ROOT}/blocks/integrations/trellis.md"

  if [[ ! -f "${agents}" ]]; then
    ui_warn "No AGENTS.md in this project yet — sync the template files first."
    return
  fi
  if [[ ! -f "${block}" ]]; then
    ui_error "Trellis integration block not found: ${block}"
    return
  fi

  if has_block "${agents}" "INTEGRATION" "trellis"; then
    ui_warn "AGENTS.md currently carries the Trellis integration block."
    ask_yes_no "Remove it from AGENTS.md?" "no" || return
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      ui_info "dry-run: remove <INTEGRATION id=\"trellis\"> from ${agents}"
    elif remove_block "${agents}" "INTEGRATION" "trellis"; then
      TEMPLATE_INTEGRATIONS=""
      prepare_template_set "ask" "${TEMPLATE_INTEGRATIONS}" "${CC_WORKFLOW_ENABLED}"
      ui_ok "Removed the Trellis integration block from AGENTS.md."
    else
      ui_error "Could not remove the block; AGENTS.md was left untouched."
    fi
    return
  fi

  ui_info "AGENTS.md has no Trellis integration block."
  ask_yes_no "Add it to AGENTS.md?" "yes" || return
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    ui_info "dry-run: append <INTEGRATION id=\"trellis\"> to ${agents}"
  elif append_block_if_missing "${agents}" "INTEGRATION" "trellis" "${block}"; then
    TEMPLATE_INTEGRATIONS="trellis"
    prepare_template_set "ask" "${TEMPLATE_INTEGRATIONS}" "${CC_WORKFLOW_ENABLED}"
    ui_ok "Added the Trellis integration block to AGENTS.md."
  else
    ui_error "Could not append the block; AGENTS.md was left untouched."
  fi
}

# -----------------------------------------------------------------------------
# Interactive Dashboard Main Hub
# -----------------------------------------------------------------------------

orchestrator_dashboard() {
  local project_dir="$1"
  local choice=""

  # Non-interactive (-y, no TTY) or driven by an explicit --files / --on-exists
  # policy: no menu, just the diagnostics once and the safe standard sync, so
  # existing automation keeps working.
  if [[ "${ASSUME_DEFAULTS}" -eq 1 || ! -t 0 || -n "${APPLY_FILES}" || -n "${ON_EXISTS}" ]]; then
    show_project_diagnostics "${project_dir}"
    info "applying template set: ${TEMPLATE_SET_LABEL}"
    apply_templates "${project_dir}"
    suggest_template_merges
    hint_if_not_git_repo "${project_dir}"
    return
  fi

  # Interactive loop. The diagnostics are rendered here and nowhere else: an
  # extra call outside the loop is what used to print the whole card twice.
  while true; do
    ui_banner "Project Orchestrator Dashboard"
    show_project_diagnostics "${project_dir}"

    printf '\n%sActions:%s\n' "${UI_BOLD}" "${UI_RESET}" >&2
    printf '  [1] 📋 Sync / apply template files (%s%s%s)\n' "${UI_CYAN}" "${TEMPLATE_SET_LABEL}" "${UI_RESET}" >&2
    printf '  [2] 🌿 Trellis management (platforms, update, CLI upgrade)\n' >&2
    printf '  [3] ⚙️  Toggle the CC-Workflow feature\n' >&2
    printf '  [4] 🔗 Toggle the Trellis integration block in AGENTS.md\n' >&2
    printf '  [5] 🚀 Safe sync all (templates + checks)\n' >&2
    printf '  [0] Exit\n\n' >&2

    choice="$(ask_value "Select action" "1")"
    case "${choice}" in
      1)
        info "applying template set: ${TEMPLATE_SET_LABEL}"
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
        toggle_trellis_integration "${project_dir}"
        ;;
      5)
        info "applying template set: ${TEMPLATE_SET_LABEL}"
        apply_templates "${project_dir}"
        suggest_template_merges
        if trellis_has_project "${project_dir}"; then
          trellis_update_project "${project_dir}"
        fi
        ui_ok "All sync tasks finished."
        break
        ;;
      0|q|exit)
        ui_info "Exiting dashboard."
        break
        ;;
      *)
        ui_warn "Invalid choice."
        ;;
    esac
  done

  hint_if_not_git_repo "${project_dir}"
}
