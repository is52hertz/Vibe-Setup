#!/usr/bin/env bash
# lib/layout.sh — repository layouts: a hub and the repositories nested in it.
#
# Sourced by vibe-init.sh (not run standalone). Relies on helpers and globals
# defined there: info, warn, DRY_RUN, LAYOUT, HUB_DIR — plus state_get from
# lib/state.sh and ui_kv_state from lib/ui.sh.
#
# A hub is a documents-only git repository that plans and coordinates the
# independent git repositories nested inside it. Each of those is a member: its
# own history, its own AGENTS.md, listed in the hub's .gitignore. The hub's
# manifest says `layout hub`, which is how a project created inside it knows.
#
# Two things here reach outside the project being worked on, both into its hub
# and both only by appending: the hub's .gitignore gets the member's line, and
# the hub's docs/tasks/ gets the member's directory. Nothing existing is edited.
#
# A Claude Code session loads CLAUDE.md from its working directory and every
# directory above it, so a session opened inside a member would also load the
# hub's rules ("documents only", "do not commit inside a sub-repository"). The
# member is shielded with a machine-local claudeMdExcludes entry instead. Codex
# stops at the nearest .git, so it never sees the hub from inside a member.
#
# A category folder — unrelated repositories grouped under one directory, where
# no agent is ever started — is not a layout at all: nothing is written there.
#
# Compatible with macOS Bash 3.2.

# Echo the hub directly above <dir> (its parent, when that is a hub), or
# nothing. One level only: a member sits directly inside its hub.
# Usage: layout_hub_of <dir>
layout_hub_of() {
  local parent=""
  parent="$(cd "$(dirname -- "$1")" 2>/dev/null && pwd -P)" || return 0
  [[ -f "${parent}/.vibe-init/manifest" ]] || return 0
  [[ "$(state_get "${parent}" layout)" == hub ]] || return 0
  printf '%s\n' "${parent}"
}

# Append <line> to <file> unless that exact line is already there. Creates the
# file when missing. Honors --dry-run. Returns 0 either way.
# Usage: layout_append_line <file> <line>
layout_append_line() {
  local file="$1" line="$2"
  if [[ -f "${file}" ]] && grep -qxF -- "${line}" "${file}"; then
    return 0
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run: add ${line} to ${file}"
    return 0
  fi
  # Keep the previous last line intact when the file does not end in a newline.
  if [[ -s "${file}" && -n "$(tail -c 1 "${file}")" ]]; then
    printf '\n' >> "${file}"
  fi
  printf '%s\n' "${line}" >> "${file}"
  info "added ${line} to ${file}"
}

# The task directory name of a member: its folder name, lowercased, as the
# existing hubs spell them (docs/tasks/pippin/ for Pippin/).
# Usage: layout_task_dir_name <member_dir>
layout_task_dir_name() {
  basename -- "$1" | tr '[:upper:]' '[:lower:]'
}

# Record <member> in <hub>: its line in the hub's .gitignore, and its task
# directory under the hub's docs/tasks/ when the hub keeps one.
# Usage: layout_register_member <hub_dir> <member_dir>
layout_register_member() {
  local hub="$1" member="$2" name="" tasks=""
  name="$(basename -- "${member}")"
  layout_append_line "${hub}/.gitignore" "/${name}/"

  tasks="${hub}/docs/tasks/$(layout_task_dir_name "${member}")"
  [[ -d "${hub}/docs/tasks" ]] || return 0
  [[ -d "${tasks}" ]] && return 0
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run: create ${tasks}/done"
    return 0
  fi
  mkdir -p "${tasks}/done" && info "created ${tasks}/done"
}

# Keep the hub's CLAUDE.md out of Claude Code sessions opened inside <member>,
# through a machine-local .claude/settings.local.json. The pattern names the
# hub folder rather than an absolute path, so it survives a moved or synced
# checkout. An existing settings.local.json is the user's file: it is never
# rewritten, only reported when it lacks the entry.
# Usage: layout_shield_member <hub_dir> <member_dir>
layout_shield_member() {
  local hub="$1" member="$2" local_settings="" pattern=""
  local_settings="${member}/.claude/settings.local.json"
  pattern="**/$(basename -- "${hub}")/CLAUDE.md"

  if [[ -f "${local_settings}" ]]; then
    if ! grep -qF -- "${pattern}" "${local_settings}"; then
      warn "${local_settings} exists without the hub exclusion; add this entry by hand:"
      warn "\"claudeMdExcludes\": [\"${pattern}\"]"
    fi
  elif [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run: write ${local_settings} (claudeMdExcludes ${pattern})"
  else
    mkdir -p "${member}/.claude"
    printf '{\n  "claudeMdExcludes": ["%s"]\n}\n' "${pattern}" > "${local_settings}"
    info "created ${local_settings}"
  fi

  # Machine-local: never committed. Many setups ignore it globally already.
  if command -v git >/dev/null 2>&1 \
      && git -C "${member}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      && git -C "${member}" check-ignore -q .claude/settings.local.json 2>/dev/null; then
    return 0
  fi
  layout_append_line "${member}/.gitignore" "/.claude/settings.local.json"
}

# True for a folder that only groups independent repositories: at least two git
# repositories directly inside, and no history of its own. Such a folder is
# never a project to sync. A manifest alone does not rule it out — the category
# folders this guards were themselves initialized by an older vibe-init — but
# one that says hub does.
# Usage: layout_looks_like_category <dir>
layout_looks_like_category() {
  local dir="$1" n=0 child=""
  [[ "$(state_get "${dir}" layout)" == hub ]] && return 1
  for child in "${dir}"/*/; do
    [[ -e "${child}.git" ]] && n=$((n + 1))
  done
  [[ "${n}" -ge 2 ]] || return 1
  if [[ -e "${dir}/.git" ]] && git -C "${dir}" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Echo, one per line, the git repositories directly inside <hub> that the hub's
# own git does not ignore — each would show up as untracked content there.
# Usage: layout_unignored_members <hub_dir>
layout_unignored_members() {
  local hub="$1" child="" name=""
  command -v git >/dev/null 2>&1 || return 0
  git -C "${hub}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  for child in "${hub}"/*/; do
    [[ -e "${child}.git" ]] || continue
    name="$(basename -- "${child}")"
    git -C "${hub}" check-ignore -q "${name}/" 2>/dev/null || printf '%s\n' "${name}"
  done
}

# Adopting the hub layout leaves the hub's .gitignore alone; it only names the
# nested repositories that still need their line there.
# Usage: layout_report_unignored <hub_dir>
layout_report_unignored() {
  local name=""
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    warn "not ignored by the hub's git: ${name}/ (add /${name}/ to .gitignore)"
  done < <(layout_unignored_members "$1")
}

# The "Layout" row of the apply diagnostics card. A value to be read, not
# judged, so neutral — except a hub whose git would pick up a nested
# repository, and a project that sits in a hub without having joined it.
# Usage: layout_diagnostics_row <project_dir>
layout_diagnostics_row() {
  local dir="$1" layout="${LAYOUT:-single}" n=0 hub=""
  case "${layout}" in
    hub)
      n="$(layout_unignored_members "${dir}" | grep -c . || true)"
      if [[ "${n}" -gt 0 ]]; then
        ui_kv_state "Layout" "todo" "hub" "${n} nested repositories not ignored"
      else
        ui_kv_state "Layout" "neutral" "hub"
      fi
      ;;
    member)
      ui_kv_state "Layout" "neutral" "member" "of ${HUB_DIR:-the hub above}"
      ;;
    *)
      hub="$(layout_hub_of "${dir}")"
      if [[ -n "${hub}" ]]; then
        ui_kv_state "Layout" "info" "single" "inside a hub; --apply --layout member joins it"
      else
        ui_kv_state "Layout" "neutral" "single"
      fi
      ;;
  esac
}

# Adopt <layout> in an existing project: append its <LAYOUT> block to
# AGENTS.md and record it as written. Explicit, like a feature toggle, so it
# writes directly instead of going through the sync — which would rightly skip
# a file whose earlier review is still frozen, leaving a manifest that says
# member over an AGENTS.md that does not.
# Usage: layout_adopt <project_dir> <hub|member>
layout_adopt() {
  local dir="$1" layout="$2" agents="${1}/AGENTS.md" frag=""

  if [[ ! -f "${agents}" ]]; then
    warn "no AGENTS.md here; the layout is recorded, but its block is not added"
    return 0
  fi
  has_block "${agents}" LAYOUT "${layout}" && return 0
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run: add <LAYOUT id=\"${layout}\"> to AGENTS.md"
    return 0
  fi

  frag="$(mktemp "${TMPDIR:-/tmp}/vibe-init-blk.XXXXXX")" || return 1
  if extract_block "${TEMPLATE_DIR}/AGENTS.md" LAYOUT "${layout}" > "${frag}" \
      && append_block_if_missing "${agents}" LAYOUT "${layout}" "${frag}"; then
    rm -f "${frag}"
    info "added <LAYOUT id=\"${layout}\"> to AGENTS.md"
    record_block_as_written "${dir}" AGENTS.md LAYOUT "${layout}"
    return 0
  fi
  rm -f "${frag}"
  warn "could not add <LAYOUT id=\"${layout}\"> to AGENTS.md"
  return 1
}
