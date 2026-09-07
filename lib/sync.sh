#!/usr/bin/env bash
# lib/sync.sh — state-aware template sync: a three-way merge, not a file copy.
#
# Sourced by vibe-init.sh (not run standalone). Relies on helpers and globals
# defined there: info, warn, DRY_RUN, TEMPLATE_DIR, TEMPLATE_FILES — plus
# lib/ui.sh, lib/block_engine.sh, lib/state.sh, and copy_template_file /
# APPLIED_TEMPLATES from lib/apply.sh.
#
# The old sync asked one question — "does this file already exist?" — and
# offered overwrite / .template / skip. That question has no good answer: a
# project scaffolded thirty seconds ago answers "yes" exactly like a project
# whose AGENTS.md was rewritten by hand a year ago, so a fresh project got four
# byte-identical .template copies and a prompt asking an agent to merge a file
# with itself.
#
# The manifest in .vibe-init/ (lib/state.sh) supplies the missing third side:
# what the tool itself last wrote. With a merge base, every file — and inside
# AGENTS.md / CLAUDE.md, every <TAG> block — is an ordinary three-way merge:
#
#   template == target            nothing to do
#   template == base              the template has not moved; the differences
#                                 are the user's own, leave them alone
#   target   == base              the template moved and the user did not:
#                                 fast-forward it in place, no questions
#   all three differ (or no base) both sides moved: hand it to the agent
#
# Only that last case produces a .template pair and a prompt, which is what
# makes those mean something again.
#
# Compatible with macOS Bash 3.2 (no associative arrays, no mapfile).

if ! command -v hash_file >/dev/null 2>&1; then
  [[ -f "${SCRIPT_DIR}/lib/state.sh" ]] && . "${SCRIPT_DIR}/lib/state.sh"
fi

# One entry per file considered by the last sync_run, in TEMPLATE_FILES order.
SYNC_REL=()
SYNC_STATE=()
SYNC_NOTE=()

SYNC_N_NEW=0
SYNC_N_UPDATE=0
SYNC_N_REVIEW=0
SYNC_N_LEGACY=0
SYNC_N_SAME=0

# Per-file scratch, set by sync_one for its caller.
SYNC_LAST_STATE=""
SYNC_LAST_NOTE=""

# "<rel><TAB><block names>" for each file whose blocks need a human, so the
# end-of-run prompt can name them instead of pointing at the whole file.
SYNC_REVIEW_BLOCKS=()

# The <TAG> whose presence marks a managed file as modern format; empty for
# files the block engine does not edit (a copied file has no format to
# convert). One line per entry so the mapping stays next to TEMPLATE_FILES.
# Usage: modern_marker_tag <relative_path>
modern_marker_tag() {
  case "$1" in
    AGENTS.md) printf 'CORE_RULES\n' ;;
    CLAUDE.md) printf 'CLAUDE_BASE\n' ;;
    *)         printf '\n' ;;
  esac
}

# True for a block whose absence from a project file is a decision, not a gap:
# a profile the project resolved and pruned, an integration or feature it does
# not use. Apply mode assembles with every profile present, so without this a
# project that settled on one would be told it is missing the others on every
# single run. Absence of any other block is worth reporting.
# Usage: block_is_optional <tag>
block_is_optional() {
  case "$1" in
    PROFILE|PROFILE_SETUP|INTEGRATION|FEATURE) return 0 ;;
    *) return 1 ;;
  esac
}

# Human name for a block: "<TAG>" or "<TAG id>".
block_label() {
  if [[ -n "${2:-}" ]]; then
    printf '<%s id="%s">\n' "$1" "$2"
  else
    printf '<%s>\n' "$1"
  fi
}

# Classify one three-way comparison. Echoes:
#   same     the target already holds the template content
#   local    the template has not moved since we wrote it, so whatever differs
#            is the user's own work — leave it alone
#   forward  the template moved and the target did not: safe to update
#   review   both moved, or there is no record of what we wrote
# Usage: merge_verdict <template_hash> <target_hash> <base_hash>
merge_verdict() {
  local tmpl="$1" proj="$2" base="${3:-}"

  if [[ -n "${tmpl}" && "${tmpl}" == "${proj}" ]]; then
    printf 'same\n'
    return
  fi
  if [[ -n "${base}" && "${tmpl}" == "${base}" ]]; then
    printf 'local\n'
    return
  fi
  if [[ -n "${base}" && "${proj}" == "${base}" ]]; then
    printf 'forward\n'
    return
  fi
  printf 'review\n'
}

# Replace one block of <dst> with the same block from <src>. Honors --dry-run.
_sync_replace_block() {
  local src="$1" dst="$2" rel="$3" tag="$4" id="${5:-}"
  local frag=""

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run: refresh $(block_label "${tag}" "${id}") in ${rel}"
    return 0
  fi

  frag="$(mktemp "${TMPDIR:-/tmp}/vibe-init-blk.XXXXXX")" || return 1
  if ! extract_block "${src}" "${tag}" "${id}" > "${frag}"; then
    rm -f "${frag}"
    return 1
  fi
  if replace_block "${dst}" "${tag}" "${id}" "${frag}"; then
    rm -f "${frag}"
    info "refreshed $(block_label "${tag}" "${id}") in ${rel}"
    return 0
  fi
  rm -f "${frag}"
  return 1
}

# Copy the template over the target. Honors --dry-run and keeps the wording the
# rest of the tool uses for a copy.
_sync_copy() {
  local rel="$1" src="$2" dst="$3"

  ensure_dir "$(dirname -- "${dst}")"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run: copy ${rel} -> ${dst}"
    return 0
  fi
  cp "${src}" "${dst}" || return 1
  info "copied ${dst}"
}

# Walk the blocks of a modern file. mode=plan tallies only; mode=apply also
# fast-forwards the blocks that can be. Sets SYNC_LAST_STATE / SYNC_LAST_NOTE.
#
# A block missing from the target is never inserted: the tool cannot know where
# in the user's file it belongs, and apply mode assembles with every profile
# present, so guessing would push pruned profiles back into a resolved project.
# A required one that is missing is reported and handed to the agent instead.
_sync_blocks() {
  local project_dir="$1" rel="$2" mode="$3"
  local src="${TEMPLATE_DIR}/${rel}" dst="${project_dir}/${rel}"
  local tag="" id="" th="" ph="" bh="" verdict=""
  local forwarded=0 reviewed=0 kept=0 names=""

  while IFS=$'\t' read -r tag id; do
    [[ -n "${tag}" ]] || continue

    if ! has_block "${dst}" "${tag}" "${id}"; then
      block_is_optional "${tag}" && continue
      reviewed=$(( reviewed + 1 ))
      names="${names}$(block_label "${tag}" "${id}") (missing) "
      continue
    fi

    th=""; ph=""; bh=""
    th="$(hash_block "${src}" "${tag}" "${id}")" || true
    ph="$(hash_block "${dst}" "${tag}" "${id}")" || true
    bh="$(state_block_hash "${project_dir}" "${rel}" "${tag}" "${id}")" || true
    verdict="$(merge_verdict "${th}" "${ph}" "${bh}")"

    case "${verdict}" in
      same)
        # The block already is the template; safe to claim as our own baseline.
        if [[ "${mode}" == "apply" ]]; then
          state_record_block "${rel}" "${tag}" "${id}" "${th}"
        fi
        ;;
      local)
        # The template has not moved, so whatever differs here is the user's
        # own writing — the block is theirs and stays untouched.
        kept=$(( kept + 1 ))
        ;;
      forward)
        forwarded=$(( forwarded + 1 ))
        if [[ "${mode}" == "apply" ]]; then
          if _sync_replace_block "${src}" "${dst}" "${rel}" "${tag}" "${id}"; then
            state_record_block "${rel}" "${tag}" "${id}" "${th}"
          else
            warn "could not refresh $(block_label "${tag}" "${id}") in ${rel}"
          fi
        fi
        ;;
      review)
        reviewed=$(( reviewed + 1 ))
        names="${names}$(block_label "${tag}" "${id}") "
        ;;
    esac
  done < <(list_blocks "${src}")

  if [[ "${reviewed}" -gt 0 ]]; then
    SYNC_LAST_STATE="review"
    SYNC_LAST_NOTE="${reviewed} block(s)"
    SYNC_REVIEW_BLOCKS+=("$(printf '%s\t%s' "${rel}" "${names% }")")
    return 0
  fi
  if [[ "${forwarded}" -gt 0 ]]; then
    SYNC_LAST_STATE="update"
    SYNC_LAST_NOTE="${forwarded} block(s)"
    return 0
  fi
  SYNC_LAST_STATE="same"
  SYNC_LAST_NOTE=""
  if [[ "${kept}" -gt 0 ]]; then
    SYNC_LAST_NOTE="your edits, template unchanged"
  fi
  return 0
}

# Sync one managed file. mode=plan classifies without writing anything;
# mode=apply does the same walk and acts on it. One code path for both, so the
# menu's summary can never disagree with what the sync then does.
# Usage: sync_one <project_dir> <relative_path> plan|apply
sync_one() {
  local project_dir="$1" rel="$2" mode="$3"
  local src="${TEMPLATE_DIR}/${rel}" dst="${project_dir}/${rel}"
  local th="" ph="" bh="" verdict="" marker=""

  SYNC_LAST_STATE=""
  SYNC_LAST_NOTE=""

  if [[ ! -f "${src}" ]]; then
    SYNC_LAST_STATE="missing-source"
    if [[ "${mode}" == "apply" ]]; then
      info "skip ${rel}: not present in template dir"
    fi
    return 0
  fi

  if [[ ! -e "${dst}" ]]; then
    SYNC_LAST_STATE="new"
    SYNC_LAST_NOTE="creates ${rel}"
    if [[ "${mode}" == "apply" ]] && _sync_copy "${rel}" "${src}" "${dst}"; then
      th="$(hash_file "${src}")" || true
      state_record_file "${rel}" "${th}"
      state_record_all_blocks "${src}" "${rel}"
    fi
    return 0
  fi

  th="$(hash_file "${src}")" || true
  ph="$(hash_file "${dst}")" || true
  bh="$(state_file_hash "${project_dir}" "${rel}")" || true
  verdict="$(merge_verdict "${th}" "${ph}" "${bh}")"

  case "${verdict}" in
    same)
      SYNC_LAST_STATE="same"
      # Byte-identical to the template, so recording it as our baseline is a
      # statement of fact — this is how an untracked project gets adopted.
      if [[ "${mode}" == "apply" ]]; then
        state_record_file "${rel}" "${th}"
        state_record_all_blocks "${dst}" "${rel}"
      fi
      return 0
      ;;
    forward)
      SYNC_LAST_STATE="update"
      SYNC_LAST_NOTE="whole file"
      if [[ "${mode}" == "apply" ]] && _sync_copy "${rel}" "${src}" "${dst}"; then
        state_record_file "${rel}" "${th}"
        state_record_all_blocks "${src}" "${rel}"
      fi
      return 0
      ;;
  esac

  # local or review. For AGENTS.md / CLAUDE.md the file-level answer is too
  # coarse: the user owns some blocks and the tool owns others, so ask per
  # block. Everything else is settled at file level.
  marker="$(modern_marker_tag "${rel}")"
  if [[ -n "${marker}" ]]; then
    if [[ "$(file_format "${dst}" "${marker}")" == "legacy" ]]; then
      SYNC_LAST_STATE="legacy"
      SYNC_LAST_NOTE="pre-<TAG> format"
      if [[ "${mode}" == "apply" ]]; then
        copy_template_file "${rel}" "${dst}" "template"
      fi
      return 0
    fi

    _sync_blocks "${project_dir}" "${rel}" "${mode}"
    if [[ "${SYNC_LAST_STATE}" == "review" && "${mode}" == "apply" ]]; then
      copy_template_file "${rel}" "${dst}" "template"
    fi
    # A file whose blocks all fast-forwarded is now the template in every part
    # we manage; the rest is the user's, so only the blocks are recorded.
    return 0
  fi

  if [[ "${verdict}" == "local" ]]; then
    SYNC_LAST_STATE="same"
    SYNC_LAST_NOTE="your edits, template unchanged"
    return 0
  fi

  SYNC_LAST_STATE="review"
  SYNC_LAST_NOTE="differs from the template"
  if [[ "${mode}" == "apply" ]]; then
    copy_template_file "${rel}" "${dst}" "template"
  fi
  return 0
}

# Reset everything a run accumulates. The dashboard can sync more than once in
# one session, and without this the second run reports the first one's work.
sync_reset() {
  SYNC_REL=()
  SYNC_STATE=()
  SYNC_NOTE=()
  SYNC_REVIEW_BLOCKS=()
  SYNC_N_NEW=0
  SYNC_N_UPDATE=0
  SYNC_N_REVIEW=0
  SYNC_N_LEGACY=0
  SYNC_N_SAME=0
  APPLIED_TEMPLATES=()
  APPLIED_LEGACY=()
}

# Run the whole set through sync_one and tally it.
# Usage: sync_run <project_dir> plan|apply <rel>...
sync_run() {
  local project_dir="$1" mode="$2"
  shift 2
  local rel=""

  sync_reset
  for rel in "$@"; do
    sync_one "${project_dir}" "${rel}" "${mode}"
    [[ -n "${SYNC_LAST_STATE}" ]] || continue
    SYNC_REL+=("${rel}")
    SYNC_STATE+=("${SYNC_LAST_STATE}")
    SYNC_NOTE+=("${SYNC_LAST_NOTE}")
    case "${SYNC_LAST_STATE}" in
      new)    SYNC_N_NEW=$((    SYNC_N_NEW + 1 )) ;;
      update) SYNC_N_UPDATE=$(( SYNC_N_UPDATE + 1 )) ;;
      review) SYNC_N_REVIEW=$(( SYNC_N_REVIEW + 1 )) ;;
      legacy) SYNC_N_LEGACY=$(( SYNC_N_LEGACY + 1 )) ;;
      same)   SYNC_N_SAME=$((   SYNC_N_SAME + 1 )) ;;
    esac
  done

  if [[ "${mode}" == "apply" ]]; then
    state_flush "${project_dir}"
  fi
  return 0
}

# True when the plan has nothing for the user to act on or wait for.
sync_has_work() {
  (( SYNC_N_NEW + SYNC_N_UPDATE + SYNC_N_REVIEW + SYNC_N_LEGACY > 0 ))
}

# A one-line summary of the last plan, for the dashboard menu hint.
sync_summary() {
  local parts=""

  if ! sync_has_work; then
    printf 'everything up to date\n'
    return
  fi
  if [[ "${SYNC_N_NEW}"    -gt 0 ]]; then parts="${parts}${SYNC_N_NEW} new, "; fi
  if [[ "${SYNC_N_UPDATE}" -gt 0 ]]; then parts="${parts}${SYNC_N_UPDATE} to refresh, "; fi
  if [[ "${SYNC_N_REVIEW}" -gt 0 ]]; then parts="${parts}${SYNC_N_REVIEW} to review, "; fi
  if [[ "${SYNC_N_LEGACY}" -gt 0 ]]; then parts="${parts}${SYNC_N_LEGACY} to convert, "; fi
  printf '%s\n' "${parts%, }"
}

# The blocks recorded as needing review for one file, or empty.
sync_review_blocks_for() {
  local rel="$1" item=""

  for item in "${SYNC_REVIEW_BLOCKS[@]+"${SYNC_REVIEW_BLOCKS[@]}"}"; do
    if [[ "${item%%$'\t'*}" == "${rel}" ]]; then
      printf '%s\n' "${item#*$'\t'}"
      return
    fi
  done
}

# What the sync did, one line per file that was not already up to date.
sync_report() {
  local index=0 rel="" state="" note="" label="" blocks=""

  if ! sync_has_work; then
    ui_ok "Everything is up to date — nothing to sync."
    return 0
  fi

  ui_section "Sync result"
  while [[ "${index}" -lt "${#SYNC_REL[@]}" ]]; do
    rel="${SYNC_REL[${index}]}"
    state="${SYNC_STATE[${index}]}"
    note="${SYNC_NOTE[${index}]}"
    index=$(( index + 1 ))

    case "${state}" in
      same|missing-source) continue ;;
      new)    label="created" ;;
      update) label="refreshed" ;;
      review)
        label="needs review"
        # Name the blocks rather than the file: after the clean ones were
        # refreshed in place, these are all that is actually left to decide.
        blocks="$(sync_review_blocks_for "${rel}")"
        if [[ -n "${blocks}" ]]; then note="${blocks}"; fi
        ;;
      legacy) label="needs format conversion" ;;
    esac
    if [[ -n "${note}" ]]; then label="${label} — ${note}"; fi
    ui_kv "${rel}" "${label}" "${UI_PATH_WIDTH}"
  done
  return 0
}
