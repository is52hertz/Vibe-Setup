#!/usr/bin/env bash
# Sourced by vibe-init.sh (not run standalone). Relies on helpers and globals
# defined there: info, warn, die, ensure_dir, ask_yes_no, ask_value, DRY_RUN,
# ASSUME_DEFAULTS, TEMPLATE_DIR, TEMPLATE_FILES, APPLY_FILES, ON_EXISTS.
#
# apply mode copies the template files into an EXISTING project. For a file that
# already exists in the target, the user chooses per file how to resolve it:
# overwrite it, write the template alongside as <name>.template, or skip it. The
# default (and the -y / non-TTY behavior) is the non-destructive <name>.template;
# --on-exists overwrite|template|skip sets it for the whole run non-interactively.
#
# Before copying, apply mode lists the managed files with their status (already
# present in the target vs new) and lets the user choose all or a subset. The
# selection can be pre-supplied non-interactively via the --files flag
# (APPLY_FILES); under -y / non-TTY with no --files, all available files are
# selected, preserving the original copy-everything behavior.

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

  if [[ -n "${ON_EXISTS}" ]]; then
    RESOLVED_DISPOSITION="${ON_EXISTS}"
    return
  fi
  if [[ "${ASSUME_DEFAULTS}" -eq 1 || ! -t 0 ]]; then
    RESOLVED_DISPOSITION="template"
    return
  fi

  while true; do
    input="$(ask_value "${relative_path} exists — [o]verwrite / [t]emplate / [s]kip?" "t")"
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
#   - source missing in the template dir -> skip (info)
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

# After apply, if any files landed as <name>.template beside an existing file,
# print a clean, copy-pasteable prompt (no log prefix, between separators) the
# user can hand to an AI agent: reconcile each template into the user's file,
# preserving their customizations, and surface conflicts for the user to decide.
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
