#!/usr/bin/env bash
# Sourced by vibe-init.sh (not run standalone). Relies on helpers and globals
# defined there: info, warn, die, ensure_dir, ask_yes_no, ask_value, DRY_RUN,
# ASSUME_DEFAULTS, TEMPLATE_DIR, TEMPLATE_FILES, APPLY_FILES.
#
# apply mode copies the template files into an EXISTING project. It never
# overwrites or merges what the user already has: when a target file exists, the
# template is written alongside it as <name>.template instead.
#
# Before copying, apply mode lists the managed files with their status (already
# present in the target vs new) and lets the user choose all or a subset. The
# selection can be pre-supplied non-interactively via the --files flag
# (APPLY_FILES); under -y / non-TTY with no --files, all available files are
# selected, preserving the original copy-everything behavior.

# Files chosen for this apply run (relative paths). Declared so expansions are
# safe under set -u before choose_apply_files populates it.
APPLY_SELECTED=()

# Copy one template file into the target project.
#   - source missing in the template dir -> skip (info)
#   - target does not exist               -> copy to target
#   - target exists                       -> copy to <target>.template
#   - <target>.template also exists       -> skip + warn (never overwrite anything)
copy_template_or_suffix() {
  local relative_path="$1"
  local destination="$2"
  local source="${TEMPLATE_DIR}/${relative_path}"
  local target="${destination}"

  if [[ ! -f "${source}" ]]; then
    info "skip ${relative_path}: not present in template dir"
    return
  fi

  if [[ -e "${destination}" ]]; then
    target="${destination}.template"
    if [[ -e "${target}" ]]; then
      warn "skip ${relative_path}: both ${destination} and ${target} exist (won't overwrite)"
      return
    fi
  fi

  ensure_dir "$(dirname -- "${target}")"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run: copy ${source} -> ${target}"
  else
    cp "${source}" "${target}"
    info "copied ${target}"
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
# source is absent in the chosen template set.
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
  printf '[vibe-init] template files (set: %s):\n' "${TEMPLATE_DIR}" >&2
  for rel in "${TEMPLATE_FILES[@]}"; do
    status="$(apply_file_status "${rel}" "${project_dir}")"
    case "${status}" in
      exists)
        label="exists -> writes ${rel}.template"
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

  # Preserve the original behavior under -y / non-TTY: copy everything.
  if [[ "${ASSUME_DEFAULTS}" -eq 1 || ! -t 0 ]]; then
    APPLY_SELECTED=("${available[@]}")
    return
  fi

  if ask_yes_no "Copy all of these files?" "yes"; then
    APPLY_SELECTED=("${available[@]}")
    return
  fi

  # Subset selection by number.
  while true; do
    input="$(ask_value "Enter numbers to copy (e.g. 1 3), or 'all'" "all")"
    if [[ "${input}" == "all" ]]; then
      APPLY_SELECTED=("${available[@]}")
      return
    fi

    # IFS is $'\n\t' globally, so split user input on spaces explicitly.
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
  local rel=""

  choose_apply_files "${project_dir}"

  if [[ "${#APPLY_SELECTED[@]}" -eq 0 ]]; then
    info "no files selected; nothing to apply"
    return
  fi

  for rel in "${APPLY_SELECTED[@]}"; do
    copy_template_or_suffix "${rel}" "${project_dir}/${rel}"
  done
}
