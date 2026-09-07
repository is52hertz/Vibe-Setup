#!/usr/bin/env bash
# lib/apply.sh — the orchestrator dashboard for an EXISTING project.
#
# Sourced by vibe-init.sh (not run standalone). Relies on helpers and globals
# defined there: info, warn, die, ensure_dir, ask_yes_no, ask_value, run_cmd,
# run_in_dir, DRY_RUN, ASSUME_DEFAULTS, TEMPLATE_DIR, TEMPLATE_SET_LABEL,
# TEMPLATE_FILES, TEMPLATE_INTEGRATIONS, CC_WORKFLOW_ENABLED, APPLY_FILES,
# ON_EXISTS — plus lib/ui.sh, lib/block_engine.sh, lib/state.sh, lib/sync.sh
# and lib/trellis.sh.
#
# Two shapes, one for each way the command is used:
#
#   Non-interactive (-y, no TTY, or a --files / --on-exists policy): print the
#   diagnostics once and do the safe standard sync, so scripts keep working.
#
#   Interactive: a dashboard loop — project diagnostics, then template sync,
#   Trellis lifecycle management, and feature toggles, until the user exits.
#
# Syncing is a three-way merge against .vibe-init/manifest, which records what
# this tool last wrote (see lib/sync.sh): a file or <TAG> block only the
# template moved is refreshed in place, one the user also changed is left alone
# and handed to their AI agent as a <name>.template pair, and one that already
# matches is not touched or even mentioned. Nothing the user wrote is ever
# overwritten.
#
# --on-exists asks for the older file-level disposition by name and still gets
# it: overwrite / <name>.template / skip, decided per file or set for the run.
#
# Compatible with macOS Bash 3.2.

# Source helper modules if not already loaded
if ! command -v ui_kv >/dev/null 2>&1; then
  [[ -f "${SCRIPT_DIR}/lib/ui.sh" ]] && . "${SCRIPT_DIR}/lib/ui.sh"
fi
if ! command -v has_block >/dev/null 2>&1; then
  [[ -f "${SCRIPT_DIR}/lib/block_engine.sh" ]] && . "${SCRIPT_DIR}/lib/block_engine.sh"
fi
if ! command -v trellis_is_installed >/dev/null 2>&1; then
  [[ -f "${SCRIPT_DIR}/lib/trellis.sh" ]] && . "${SCRIPT_DIR}/lib/trellis.sh"
fi
if ! command -v hash_file >/dev/null 2>&1; then
  [[ -f "${SCRIPT_DIR}/lib/state.sh" ]] && . "${SCRIPT_DIR}/lib/state.sh"
fi
if ! command -v merge_verdict >/dev/null 2>&1; then
  [[ -f "${SCRIPT_DIR}/lib/sync.sh" ]] && . "${SCRIPT_DIR}/lib/sync.sh"
fi

# Files chosen for this apply run (relative paths). Declared so expansions are
# safe under set -u before choose_apply_files populates it.
APPLY_SELECTED=()

# Relative paths that were written as <name>.template because the target already
# existed and the user chose / defaulted to the non-destructive template
# disposition. Drives the end-of-run "merge these into your real files" hint.
APPLIED_TEMPLATES=()

# The subset of APPLIED_TEMPLATES whose existing target is a pre-block file
# (plain Markdown, no <TAG> markers). The pair is still a content merge, but
# structurally it is a format conversion, so those pairs get their own
# end-of-run prompt. Only files the block engine edits can be legacy.
APPLIED_LEGACY=()


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

# The opening tags of an assembled template file, e.g. "<CORE_RULES> <METADATA>
# <PROFILE>", read out of the materialized set so the conversion prompt never
# hard-codes a second copy of the vocabulary. Echoes nothing for a missing file.
# Built on list_blocks, so tag-shaped prose inside a document (a
# `<YYYY>/<MM>/<DD>` path, say) cannot leak into the vocabulary.
# Usage: md_tag_vocabulary <file>
md_tag_vocabulary() {
  local file="$1"
  local tags=""

  [[ -f "${file}" ]] || return 0
  tags="$(list_blocks "${file}" | awk -F'\t' '{ print "<" $1 ">" }' | sort -u | tr '\n' ' ')" || true
  printf '%s\n' "${tags% }"
}

# True when <rel> was written beside a legacy target this run.
# Usage: rel_is_legacy <relative_path>
rel_is_legacy() {
  local rel="$1" item=""
  for item in "${APPLIED_LEGACY[@]+${APPLIED_LEGACY[@]}}"; do
    [[ "${item}" == "${rel}" ]] && return 0
  done
  return 1
}

# Copy one template file into the target project. When the destination already
# exists, `disposition` ("overwrite" | "template" | "skip") decides what happens:
#   - source missing in the template set -> skip (info)
#   - destination does not exist          -> copy to destination
#   - exists + overwrite                  -> copy over destination
#   - exists + template                   -> copy to <destination>.template
#   - exists + skip                       -> leave the existing file untouched
#
# <destination>.template is this tool's own scratch copy — nothing else ever
# writes it, and the end-of-run prompt asks the agent to delete it once the
# merge is done. So a leftover one means the previous merge never happened: it
# is refreshed to the current template rather than treated as precious. It used
# to be skipped instead, which silently dropped the pair from APPLIED_TEMPLATES
# and left the user staring at "needs review" with no prompt to act on.
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
          info "refreshing ${target} (left over from an unfinished merge)"
        fi
        is_template=1
        ;;
    esac
  fi

  ensure_dir "$(dirname -- "${target}")"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run: copy ${relative_path} -> ${target}"
  else
    cp "${source}" "${target}"
    info "copied ${target}"
  fi

  if [[ "${is_template}" -eq 1 ]]; then
    APPLIED_TEMPLATES+=("${relative_path}")
    # A target without the marker tag predates the block engine: the pair is a
    # format conversion, not just a content merge, and gets its own prompt.
    local marker=""
    marker="$(modern_marker_tag "${relative_path}")"
    if [[ -n "${marker}" ]] \
        && [[ "$(file_format "${destination}" "${marker}")" == "legacy" ]]; then
      APPLIED_LEGACY+=("${relative_path}")
    fi
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

# The menu label for one planned file, as "word<TAB>detail" — e.g.
# "already exists — needs review<TAB>2 blocks". Two consumers want it split
# differently: the printed list colors the word and dims the detail, while the
# interactive checklist wants one plain string for its hint column. Emitting one
# record keeps the wording in a single place so they cannot drift apart.
# Usage: sync_menu_label <relative_path> <state> <note>
sync_menu_label() {
  local rel="$1" state="$2" note="${3:-}"
  local label=""

  case "${state}" in
    new)    printf 'new -> creates %s\t\n' "${rel}"; return ;;
    same)   label="up to date" ;;
    update) label="already exists — will refresh" ;;
    review) label="already exists — needs review" ;;
    legacy) label="already exists — needs format conversion" ;;
    *)      label="${state}" ;;
  esac
  printf '%s\t%s\n' "${label}" "${note}"
}

# Flatten a sync_menu_label record back into one plain string, for the checklist
# hint column, which has no room for two colors.
sync_menu_label_flat() {
  local record=""
  local word="" detail=""

  record="$(sync_menu_label "$@")"
  word="${record%%$'\t'*}"
  detail="${record#*$'\t'}"
  if [[ -n "${detail}" ]]; then
    printf '%s (%s)\n' "${word}" "${detail}"
  else
    printf '%s\n' "${word}"
  fi
}

# Let the user choose which managed files to copy; populates APPLY_SELECTED.
#
# The list is the plan, not a directory listing: a file that already holds the
# template content is reported as up to date and is not offered, because there
# is nothing to do to it. Only --on-exists, which asks for the blunt
# overwrite/template/skip policy by name, still labels files by mere existence.
choose_apply_files() {
  local project_dir="$1"
  local rel="" status="" label="" input="" token="" ok="" record="" word="" detail=""
  local -a available=()
  local -a labels=()
  local -a tokens=()
  local -a choices=()
  local listing=0
  local index=0

  # Non-interactive subset wins over any prompting.
  if [[ -n "${APPLY_FILES}" ]]; then
    select_from_files_flag
    return
  fi

  # List every managed file with its status; only a file with something to do is
  # selectable. The checklist below repeats the names, so the list is printed
  # only for the plain path that has no checklist.
  if ! _prompt_can_draw || [[ "${ASSUME_DEFAULTS}" -eq 1 || ! -t 0 ]]; then
    listing=1
    ui_section "Template files (${TEMPLATE_SET_LABEL})"
  fi

  if [[ -n "${ON_EXISTS}" ]]; then
    # An explicit --on-exists policy is a request for the old file-level
    # disposition, so the labels stay file-level too.
    for rel in "${TEMPLATE_FILES[@]}"; do
      status="$(apply_file_status "${rel}" "${project_dir}")"
      case "${status}" in
        exists) label="already exists -> ${ON_EXISTS}" ;;
        new)    label="new -> creates ${rel}" ;;
        missing-source)
          if [[ "${listing}" -eq 1 ]]; then ui_kv "${rel}" "not in this set" "${UI_PATH_WIDTH}"; fi
          continue
          ;;
      esac
      available+=("${rel}")
      labels+=("${label}")
      if [[ "${listing}" -eq 1 ]]; then ui_kv "${rel}" "${label}" "${UI_PATH_WIDTH}"; fi
    done
  else
    sync_run "${project_dir}" plan "${TEMPLATE_FILES[@]}"
    index=0
    while [[ "${index}" -lt "${#SYNC_REL[@]}" ]]; do
      rel="${SYNC_REL[${index}]}"
      status="${SYNC_STATE[${index}]}"
      record="$(sync_menu_label "${rel}" "${status}" "${SYNC_NOTE[${index}]}")"
      word="${record%%$'\t'*}"
      detail="${record#*$'\t'}"
      label="$(sync_menu_label_flat "${rel}" "${status}" "${SYNC_NOTE[${index}]}")"
      index=$(( index + 1 ))

      case "${status}" in
        missing-source)
          if [[ "${listing}" -eq 1 ]]; then
            ui_kv_state "${rel}" "off" "not in this set" "" "${UI_PATH_WIDTH}"
          fi
          continue
          ;;
        same)
          if [[ "${listing}" -eq 1 ]]; then
            ui_kv_state "${rel}" "off" "${word}" "${detail}" "${UI_PATH_WIDTH}"
          fi
          continue
          ;;
      esac
      available+=("${rel}")
      labels+=("${label}")
      if [[ "${listing}" -eq 1 ]]; then
        ui_kv_state "${rel}" "$(sync_state_level "${status}")" "${word}" "${detail}" "${UI_PATH_WIDTH}"
      fi
    done
  fi

  if [[ "${#available[@]}" -eq 0 ]]; then
    APPLY_SELECTED=()
    return
  fi

  if [[ "${ASSUME_DEFAULTS}" -eq 1 || ! -t 0 ]]; then
    APPLY_SELECTED=("${available[@]}")
    return
  fi

  # With a terminal that can draw, pick them off a checklist. Everything starts
  # ticked, so Enter keeps the copy-everything default one keystroke away.
  if _prompt_can_draw; then
    choices=()
    index=0
    for rel in "${available[@]}"; do
      choices+=("$(prompt_opt "${rel}" "${rel}" "${labels[${index}]}")")
      index=$(( index + 1 ))
    done

    APPLY_SELECTED=()
    while IFS= read -r rel; do
      [[ -n "${rel}" ]] && APPLY_SELECTED+=("${rel}")
    done < <(ui_multiselect "Which files?" "all" "${choices[@]}")
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

# Sync the selected files.
#
# The default path is the three-way merge in lib/sync.sh: files and blocks that
# only the template moved are refreshed in place, files the user also changed
# are handed to their AI agent, and anything already matching is left alone.
# --on-exists asks for the older file-level disposition by name, so that flag
# keeps its blunt overwrite / .template / skip behavior.
apply_templates() {
  local project_dir="$1"
  local rel="" destination="" disposition=""

  choose_apply_files "${project_dir}"

  if [[ "${#APPLY_SELECTED[@]}" -eq 0 ]]; then
    if [[ -z "${ON_EXISTS}" ]]; then
      sync_reset
      ui_ok "Everything is up to date — nothing to sync."
    else
      info "no files selected; nothing to apply"
    fi
    return
  fi

  if [[ -z "${ON_EXISTS}" ]]; then
    sync_run "${project_dir}" apply "${APPLY_SELECTED[@]}"
    sync_report
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
# Pairs whose existing target is a pre-block legacy file instead get the format
# conversion prompt: the agent restructures the old file into the <TAG> layout
# of the new template, keeping every line of the user's content.
suggest_template_merges() {
  local rel="" count="" noun="files were" blocks=""
  local legacy_count=0 modern_count=0

  count="${#APPLIED_TEMPLATES[@]}"
  [[ "${count}" -gt 0 ]] || return 0
  [[ "${count}" -eq 1 ]] && noun="file was"

  legacy_count="${#APPLIED_LEGACY[@]}"
  modern_count=$(( count - legacy_count ))

  info "${count} ${noun} written as <name>.template beside an existing file."

  if [[ "${modern_count}" -gt 0 ]]; then
    info "copy the prompt between the lines below and give it to your AI agent:"
    {
      ui_copy_open "suggested prompt for your AI agent"
      printf '%s\n' "Bring my files up to date with vibe-init's latest templates. For each pair,"
      printf '%s\n' "the .template is the NEW template version and the plain file is MY current"
      printf '%s\n' "one (which may hold my customizations):"
      for rel in "${APPLIED_TEMPLATES[@]}"; do
        if ! rel_is_legacy "${rel}"; then
          printf '  - %s.template  ->  %s\n' "${rel}" "${rel}"
          blocks="$(sync_review_blocks_for "${rel}")"
          if [[ -n "${blocks}" ]]; then
            printf '    only these blocks are still open: %s\n' "${blocks}"
          fi
        fi
      done
      printf '%s\n' "Merge the template into my file: keep my customizations, fold in new/changed"
      printf '%s\n' "guidance, and respect each file's format (e.g. JSON for settings). Where a"
      printf '%s\n' "pair lists open blocks, those are the only ones that need you — every other"
      printf '%s\n' "block already matches the template and must be left exactly as it is; a block"
      printf '%s\n' "marked (missing) is in the template but not in my file, so decide with me"
      printf '%s\n' "whether it belongs and where. Where the two genuinely conflict, do not choose"
      printf '%s\n' "silently — list each conflict and ask me to decide. When you ask me anything,"
      printf '%s\n' "write it in Simplified Chinese (中文); keep code, identifiers, and your own"
      printf '%s\n' "reasoning in English. After I confirm, delete the .template files."
      ui_copy_close
    } >&2
  fi

  if [[ "${legacy_count}" -gt 0 ]]; then
    if [[ "${legacy_count}" -eq 1 ]]; then
      info "1 of them is in the old pre-<TAG> format; copy the prompt between the"
      info "lines below to convert it:"
    else
      info "${legacy_count} of them are in the old pre-<TAG> format; copy the prompt"
      info "between the lines below to convert them:"
    fi
    {
      ui_copy_open "suggested prompt for your AI agent"
      printf '%s\n' "Restructure my files into the new <TAG> block format. For each pair, the"
      printf '%s\n' ".template is the NEW template version and the plain file is MY current"
      printf '%s\n' "one, written before the <TAG> markers existed:"
      for rel in "${APPLIED_LEGACY[@]}"; do
        printf '  - %s.template  ->  %s\n' "${rel}" "${rel}"
        printf '    new-format tags in that .template: %s\n' \
          "$(md_tag_vocabulary "${TEMPLATE_DIR}/${rel}")"
      done
      printf '%s\n' "Wrap each of my sections in the matching <TAG>...</TAG> pair from its"
      printf '%s\n' ".template, keeping the block order of the .template. The old comment anchors"
      printf '%s\n' "(e.g. <!-- PROFILE:service START/END -->, <!-- TRELLIS:START/END -->) are"
      printf '%s\n' "format residue: once a tag wraps the same content, drop the anchor. Keep"
      printf '%s\n' "every line of my content — do not rewrite, shorten, or \"improve\" anything,"
      printf '%s\n' "and sections with no matching tag stay outside the blocks. Where you cannot"
      printf '%s\n' "tell where a section belongs, do not guess — list it and ask me to decide."
      printf '%s\n' "When you ask me anything, write it in Simplified Chinese (中文); keep code,"
      printf '%s\n' "identifiers, and your own reasoning in English. After I confirm, delete the"
      printf '%s\n' ".template files."
      ui_copy_close
    } >&2
  fi
}

# -----------------------------------------------------------------------------
# Diagnostics & Dashboard
# -----------------------------------------------------------------------------

show_project_diagnostics() {
  local project_dir="$1"
  # Each row is a (level, state word, detail) triple rather than one flat
  # string: lib/ui.sh colors the state and dims the detail, which is what gives
  # a card this dense a reading order.
  local git_level="off"     git_state="Not initialized"   git_detail=""
  local trellis_level="off" trellis_state="Not configured" trellis_detail=""
  local plat_level="off"    plat_state="None"             plat_detail=""
  local cc_level="off"      cc_state="Disabled"           cc_detail=""
  # "Missing" is dim, not red: on a directory being seeded for the first time
  # both of these are absent and the sync is about to create them, so red here
  # would fire on the most ordinary run there is. The action shows up green in
  # the file list below ("new -> creates AGENTS.md"), which is where it belongs.
  local agents_level="off"  agents_state="Missing"        agents_detail=""
  local claude_level="off"  claude_state="Missing"        claude_detail=""
  local tracked_level="info" tracked_state="v${VIBE_INIT_VERSION}" tracked_detail=""
  local branch="" p_ver="" c_ver="" platforms="" tracked_version=""

  # Git check. A repository with no commits yet is the normal state right after
  # vibe-init scaffolds one, and there `rev-parse --abbrev-ref HEAD` prints
  # "HEAD" *and* fails; symbolic-ref answers the unborn branch name cleanly.
  if command -v git >/dev/null 2>&1 && git -C "${project_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch="$(git -C "${project_dir}" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    if [[ -z "${branch}" ]]; then
      branch="$(git -C "${project_dir}" rev-parse --short HEAD 2>/dev/null || true)"
      if [[ -n "${branch}" ]]; then
        branch="detached at ${branch}"
      else
        branch="unknown"
      fi
    fi
    git_level="ok"
    git_state="Initialized"
    git_detail="${branch}"
  fi

  # Trellis check
  c_ver="$(trellis_cli_version || echo "none")"
  if trellis_has_project "${project_dir}"; then
    p_ver="$(trellis_project_version "${project_dir}" || echo "unknown")"
    trellis_level="ok"
    trellis_state="Active"
    trellis_detail="Project v${p_ver} / CLI v${c_ver}"

    platforms="$(trellis_configured_platforms "${project_dir}")"
    if [[ -n "${platforms}" && "${platforms}" != "None" ]]; then
      plat_level="info"
      # The list can carry a trailing "(…)" note about which other tools read
      # the same files. That is detail, not state, so it goes dim with the rest.
      case "${platforms}" in
        *\ \(*)
          plat_state="${platforms%% (*}"
          plat_detail="${platforms#* (}"
          plat_detail="${plat_detail%)}"
          ;;
        *)
          plat_state="${platforms}"
          ;;
      esac
    fi
  elif [[ "${c_ver}" != "none" ]]; then
    trellis_level="todo"
    trellis_state="Not initialized"
    trellis_detail="CLI v${c_ver} ready"
  else
    trellis_level="bad"
    trellis_state="CLI not installed"
  fi

  # CC-Workflow check
  if [[ -f "${project_dir}/CC-Cowork-Workflow.md" ]]; then
    cc_level="ok"
    cc_state="Active"
  fi

  # AGENTS.md / CLAUDE.md format. A legacy file has no <TAG> blocks for the
  # engine to edit; the conversion path is the ordinary sync (it writes the
  # .template) plus the end-of-run prompt for the project's AI agent.
  case "$(file_format "${project_dir}/AGENTS.md" "CORE_RULES")" in
    modern) agents_level="info"; agents_state="Modern"; agents_detail="<TAG> format" ;;
    legacy) agents_level="todo"; agents_state="Legacy"; agents_detail="pre-<TAG> format" ;;
  esac
  case "$(file_format "${project_dir}/CLAUDE.md" "CLAUDE_BASE")" in
    modern) claude_level="info"; claude_state="Modern"; claude_detail="<TAG> format" ;;
    legacy) claude_level="todo"; claude_state="Legacy"; claude_detail="pre-<TAG> format" ;;
  esac

  # Whether this project carries a .vibe-init manifest decides how much the sync
  # can know: without one there is no merge base, so every existing file has to
  # be treated as a possible conflict. The version turns todo-colored to say so
  # up front — it explains why a first run on an old project is noisy.
  if state_is_tracked "${project_dir}"; then
    tracked_version="$(state_get "${project_dir}" version)"
    [[ -n "${tracked_version}" ]] || tracked_version="unknown"
    tracked_detail="project tracked at v${tracked_version}"
  else
    tracked_level="todo"
    tracked_detail="project not tracked yet"
  fi

  ui_section "Project environment"
  ui_kv_state "vibe-init"   "${tracked_level}" "${tracked_state}" "${tracked_detail}"
  ui_kv_state "Git repo"    "${git_level}"     "${git_state}"     "${git_detail}"
  ui_kv_state "Trellis"     "${trellis_level}" "${trellis_state}" "${trellis_detail}"
  ui_kv_state "Platforms"   "${plat_level}"    "${plat_state}"    "${plat_detail}"
  ui_kv_state "CC-Workflow" "${cc_level}"      "${cc_state}"      "${cc_detail}"
  ui_kv_state "AGENTS.md"   "${agents_level}"  "${agents_state}"  "${agents_detail}"
  ui_kv_state "CLAUDE.md"   "${claude_level}"  "${claude_state}"  "${claude_detail}"
  if [[ "${agents_level}" == "todo" || "${claude_level}" == "todo" ]]; then
    ui_kv_state "Format upgrade" "todo" "sync once, then follow the printed agent prompt"
  fi
}

# -----------------------------------------------------------------------------
# Feature Toggles: CC-Workflow
# -----------------------------------------------------------------------------

# Record a block a toggle just wrote from its template, so the manifest keeps
# describing what this tool put on disk. Without it the tool's own edit would
# look like the user's the next time sync ran.
# Usage: record_block_as_written <project_dir> <relative_path> <tag> <id>
record_block_as_written() {
  local project_dir="$1" rel="$2" tag="$3" id="${4:-}"
  local block_hash=""

  [[ "${DRY_RUN}" -eq 1 ]] && return 0
  block_hash="$(hash_block "${project_dir}/${rel}" "${tag}" "${id}")" || return 0
  state_record_block "${rel}" "${tag}" "${id}" "${block_hash}"
  state_flush "${project_dir}"
}

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
  # The block we just wrote is the template's own, so record it — otherwise the
  # next sync would see an unrecorded block and call our own edit a conflict.
  record_block_as_written "${project_dir}" "CLAUDE.md" "FEATURE" "cc-workflow"
  ui_ok "CC-Workflow enabled (${variant} variant) and referenced from CLAUDE.md."
}

# -----------------------------------------------------------------------------
# Trellis Operations Menu
# -----------------------------------------------------------------------------

manage_trellis() {
  local project_dir="$1"
  local choice=""
  local plat=""
  local -a actions=()
  local -a platforms=()

  if ! trellis_has_project "${project_dir}"; then
    ui_warn "Trellis is not initialized in this project."
    if ask_yes_no "Initialize Trellis now?" "yes"; then
      resolve_trellis_setup
      if [[ "${TRELLIS_READY}" -eq 1 ]]; then
        run_trellis_init "${project_dir}"
      fi
    fi
    return
  fi

  while true; do
    actions=()
    actions+=("$(prompt_opt platform "Add an AI platform"      "trellis init --<platform>")")
    actions+=("$(prompt_opt update   "Update the project"      "trellis update")")
    actions+=("$(prompt_opt upgrade  "Upgrade the Trellis CLI" "npm install -g")")
    actions+=("$(prompt_opt back     "Back")")

    choice="$(ui_select "Trellis management" "back" "${actions[@]}")"
    case "${choice}" in
      platform)
        platforms=()
        platforms+=("$(prompt_opt --cursor   "Cursor")")
        platforms+=("$(prompt_opt --codex    "Codex")")
        platforms+=("$(prompt_opt --claude   "Claude Code")")
        platforms+=("$(prompt_opt --gemini   "Gemini CLI")")
        platforms+=("$(prompt_opt --opencode "OpenCode")")

        plat="$(ui_select "Which platform?" "--cursor" "${platforms[@]}")"
        if [[ -n "${plat}" ]]; then
          trellis_add_platform "${project_dir}" "${plat}"
        fi
        ;;
      update)
        trellis_update_project "${project_dir}"
        ;;
      upgrade)
        trellis_upgrade_cli
        ;;
      *)
        break
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
    record_block_as_written "${project_dir}" "AGENTS.md" "INTEGRATION" "trellis"
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
  local cc_state=""
  local sync_state=""
  local sync_level=""
  local -a actions=()

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
    if [[ -f "${project_dir}/CC-Cowork-Workflow.md" ]]; then
      cc_state="currently on"
    else
      cc_state="currently off"
    fi

    show_project_diagnostics "${project_dir}"

    # Plan the sync before drawing the menu, so the entry says what there is to
    # do instead of inviting the user into a run that has nothing to change.
    if [[ -n "${ON_EXISTS}" ]]; then
      sync_state="${TEMPLATE_SET_LABEL}"
      sync_level=""
    else
      sync_run "${project_dir}" plan "${TEMPLATE_FILES[@]}"
      sync_state="$(sync_summary)"
      sync_level="$(sync_summary_level)"
    fi

    # Built up in an array rather than nested inline: bash 3.2 mis-parses a
    # command substitution that closes immediately inside another one.
    actions=()
    actions+=("$(prompt_opt sync    "Sync template files"      "${sync_state}" "${sync_level}")")
    actions+=("$(prompt_opt trellis "Trellis management"       "platforms, update, upgrade")")
    actions+=("$(prompt_opt ccflow  "Toggle CC-Workflow"       "${cc_state}")")
    actions+=("$(prompt_opt integ   "Toggle Trellis block"     "in AGENTS.md")")
    actions+=("$(prompt_opt syncall "Sync everything and exit" "templates + Trellis update")")
    actions+=("$(prompt_opt quit    "Exit")")

    choice="$(ui_select "What would you like to do?" "sync" "${actions[@]}")"
    case "${choice}" in
      sync)
        info "applying template set: ${TEMPLATE_SET_LABEL}"
        apply_templates "${project_dir}"
        suggest_template_merges
        ;;
      trellis)
        manage_trellis "${project_dir}"
        ;;
      ccflow)
        toggle_cc_workflow "${project_dir}"
        ;;
      integ)
        toggle_trellis_integration "${project_dir}"
        ;;
      syncall)
        info "applying template set: ${TEMPLATE_SET_LABEL}"
        apply_templates "${project_dir}"
        suggest_template_merges
        if trellis_has_project "${project_dir}"; then
          trellis_update_project "${project_dir}"
        fi
        ui_ok "All sync tasks finished."
        break
        ;;
      *)
        break
        ;;
    esac
  done

  hint_if_not_git_repo "${project_dir}"
}
