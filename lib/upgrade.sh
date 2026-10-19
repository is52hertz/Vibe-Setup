#!/usr/bin/env bash
# Explicit upgrade decisions and recoverable local writes. Sourced by the CLI.
# Policy and upstream base objects are portable; reviews/backups/locks are local.
UPGRADE_LOCK=""
UPGRADE_BACKUP=""

upgrade_policy() {
  local file="${1}/.vibe-init/policy"
  [[ -f "${file}" ]] || return 0
  awk -F'\t' -v key="$2" '$1 == key { print $2; exit }' "${file}"
}

upgrade_set_policy() {
  local project="$1" key="$2" value="$3" file="${1}/.vibe-init/policy"
  if [[ "${DRY_RUN}" -eq 1 ]]; then info "dry-run: set ${key} to ${value}"; return 0; fi
  mkdir -p "${project}/.vibe-init" || return 1
  if [[ -f "${file}" ]]; then
    awk -F'\t' -v key="${key}" '$1 != key' "${file}" > "${file}.tmp.$$"
  else
    : > "${file}.tmp.$$"
  fi
  printf '%s\t%s\n' "${key}" "${value}" >> "${file}.tmp.$$"
  mv "${file}.tmp.$$" "${file}" || return 1
  ensure_state_gitignored "${project}"
}

upgrade_paused() { [[ "$(upgrade_policy "$1" updates)" == "paused" ]]; }

upgrade_local() {
  local project="$1" rel="$2" tag="${3:-}" id="${4:-}" choice=""
  [[ "$(upgrade_policy "${project}" "${rel}")" == "local" ]] && return 0
  [[ -n "${tag}" ]] || return 1
  choice="$(upgrade_policy "${project}" "${rel}:${tag}${id:+:${id}}")"
  case "${choice}" in local) return 0 ;; follow) return 1 ;; esac
  # Project descriptions and progress are seed-only, not upstream rules.
  [[ "${rel}" == "AGENTS.md" && ( "${tag}" == "PRODUCT" || "${tag}" == "PROJECT_PHASE" ) ]]
}

upgrade_known_file() {
  local rel=""; for rel in "${TEMPLATE_FILES[@]}"; do [[ "$1" == "${rel}" ]] && return 0; done
  return 1
}

upgrade_validate_scope() {
  local project="$1" scope="$2" rel="${2%%:*}" rest="" tag="" id=""
  upgrade_known_file "${rel}" || { warn "unknown managed file: ${rel}"; return 1; }
  [[ "${scope}" == "${rel}" ]] && return 0
  rest="${scope#*:}"; tag="${rest%%:*}"
  [[ "${rest}" == "${tag}" ]] || id="${rest#*:}"
  [[ "${tag}" =~ ^[A-Z_]+$ && "${id}" =~ ^[a-zA-Z0-9_-]*$ ]] || { warn "invalid block scope"; return 1; }
  [[ -n "$(modern_marker_tag "${rel}")" ]] || { warn "this file has no managed blocks"; return 1; }
  if ! has_block "${project}/${rel}" "${tag}" "${id}" && ! has_block "${TEMPLATE_DIR}/${rel}" "${tag}" "${id}"; then
    warn "unknown block: ${scope}"; return 1
  fi
}

# Reject links along every managed path before reading or modifying them. This
# also keeps a project's state from redirecting a write outside the project.
upgrade_safe_paths() {
  local project="$1" rel="" part="" path="" rest="" link=""
  [[ ! -e "${project}/.vibe-init" || -d "${project}/.vibe-init" ]] || { warn "upgrade state is not a directory"; return 1; }
  for rel in .vibe-init .gitignore .vibe-init/manifest .vibe-init/policy "${TEMPLATE_FILES[@]}"; do
    rest="${rel}"; path="${project}"
    while [[ -n "${rest}" ]]; do
      part="${rest%%/*}"; path="${path}/${part}"
      [[ ! -L "${path}" && ! -L "${path}.template" ]] || { warn "refusing symlink: ${path}"; return 1; }
      if [[ "${rest}" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    done
    if [[ "${rel}" != .vibe-init ]]; then
      [[ ! -e "${path}" || -f "${path}" ]] || { warn "managed path is not a regular file: ${rel}"; return 1; }
      [[ ! -e "${path}.template" || -f "${path}.template" ]] || { warn "hand-out is not a regular file: ${rel}"; return 1; }
    fi
  done
  if [[ -d "${project}/.vibe-init" ]]; then
    link="$(find "${project}/.vibe-init" -type l -print -quit)"
    [[ -z "${link}" ]] || { warn "refusing symlinks in upgrade state"; return 1; }
  fi
}

upgrade_lock() {
  [[ "${DRY_RUN}" -eq 1 || -n "${UPGRADE_LOCK}" ]] && return 0
  mkdir -p "${1}/.vibe-init"
  mkdir "${1}/.vibe-init/lock" 2>/dev/null || {
    warn "another upgrade holds .vibe-init/lock; after an interrupted run, verify it stopped before removing the lock"; return 1;
  }
  UPGRADE_LOCK="${1}/.vibe-init/lock"
}

upgrade_unlock() {
  if [[ -n "${UPGRADE_LOCK}" ]]; then rmdir "${UPGRADE_LOCK}" 2>/dev/null || true; UPGRADE_LOCK=""; fi
}

upgrade_meta() {
  [[ -f "$1.meta" ]] || return 0
  awk -F'\t' -v key="$2" '$1 == key { print $2; exit }' "$1.meta"
}

upgrade_ticket() {
  local pending="" target=""
  pending="$(state_pending_path "$1" "$2")"
  [[ -f "${pending}" ]] || return 1
  target="$(upgrade_meta "${pending}" target)"
  [[ -n "${target}" ]] || target="$(hash_file "${pending}")"
  printf '%s\n%s\n%s\n' "$2" "${target}" "$(upgrade_meta "${pending}" kind)" | _hash_stdin
}

upgrade_file_hash() {
  if [[ -f "$1" ]]; then hash_file "$1"; else printf 'absent\n'; fi
}

upgrade_pending_count() {
  local count=0 rel=""
  for rel in "${TEMPLATE_FILES[@]}"; do
    [[ -f "$(state_pending_path "$1" "${rel}")" ]] && count=$((count + 1))
  done
  printf '%s\n' "${count}"
}

upgrade_show_pending() {
  local project="$1" rel="" pending="" hash="" tag="" id="" base="" decision=""
  ui_section "Upgrade reviews"
  for rel in "${TEMPLATE_FILES[@]}"; do
    pending="$(state_pending_path "${project}" "${rel}")"
    [[ -f "${pending}" ]] || continue
    ui_kv "${rel}" "$(upgrade_ticket "${project}" "${rel}")"
    info "target: $(upgrade_meta "${pending}" version), $(upgrade_meta "${pending}" kind); upstream: ${pending}"
    hash="$(upgrade_file_hash "${project}/${rel}")"
    decision="merged"
    [[ "$(upgrade_meta "${pending}" kind)" != convert ]] || decision="converted"
    info "current fingerprint: ${hash}"
    info "resolve after review: vibe-init --apply --resolve $(upgrade_ticket "${project}" "${rel}") --expect ${hash} --resolution ${decision}"
    info "to keep the project version this time, use --resolution keep instead"
    base="$(state_file_hash "${project}" "${rel}")"
    if [[ -n "${base}" && -f "${project}/.vibe-init/base/${base}" ]]; then
      info "old upstream file (block bases may be newer): .vibe-init/base/${base}"
    fi
      while IFS=$'\t' read -r tag id; do
        base="$(state_block_hash "${project}" "${rel}" "${tag}" "${id}")"
        [[ -n "${base}" && -f "${project}/.vibe-init/base/${base}" ]] || continue
        info "old upstream $(block_label "${tag}" "${id}"): .vibe-init/base/${base}"
      done < <(_sync_block_keys "${project}" "${rel}" "${pending}")
  done
  info "$(upgrade_pending_count "${project}") pending review(s); deleting .template files does not resolve them."
}

# Validate only standalone block markers; inline examples in prose are ignored.
upgrade_valid_blocks() {
  awk '
    /^<[A-Z_]+([[:space:]]+id="[^"]*")?>[[:space:]]*$/ {
      line=$0; sub(/>[[:space:]]*$/, "", line)
      if (seen[line]++ || opened != "") bad=1
      opened=line; sub(/^</, "", opened); sub(/[[:space:]].*$/, "", opened)
    }
    /^<\/[A-Z_]+>[[:space:]]*$/ {
      line=$0; sub(/^<\//, "", line); sub(/>[[:space:]]*$/, "", line)
      if (opened != line) bad=1
      opened=""
    }
    END { exit (bad || opened != "") ? 1 : 0 }
  ' "$1"
}

upgrade_resolve() {
  local project="$1" ticket="$2" expected="$3" decision="$4"
  local rel="" found="" pending="" marker="" target="" kind="" tag="" id="" old_dir="${TEMPLATE_DIR}"
  case "${decision}" in merged|keep|converted) ;; *) warn "resolution must be merged, keep, or converted"; return 1 ;; esac
  for rel in "${TEMPLATE_FILES[@]}"; do
    if [[ "$(upgrade_ticket "${project}" "${rel}" || true)" == "${ticket}" ]]; then found="${rel}"; break; fi
  done
  [[ -n "${found}" ]] || { warn "unknown or already resolved review"; return 1; }
  rel="${found}"; pending="$(state_pending_path "${project}" "${rel}")"
  target="$(upgrade_meta "${pending}" target)"
  [[ -n "${target}" ]] || target="$(hash_file "${pending}")"
  [[ "$(hash_file "${pending}")" == "${target}" ]] || { warn "pending template changed; refusing acknowledgement"; return 1; }
  [[ "$(upgrade_file_hash "${project}/${rel}")" == "${expected}" ]] || { warn "project file changed since review; inspect it again"; return 1; }
  if [[ -f "${project}/${rel}" ]] && grep -Eq '^(<<<<<<< |=======|>>>>>>> )' "${project}/${rel}"; then
    warn "unresolved conflict markers"; return 1
  fi
  marker="$(modern_marker_tag "${rel}")"
  kind="$(upgrade_meta "${pending}" kind)"
  if [[ -n "${marker}" && -f "${project}/${rel}" ]] && ! upgrade_valid_blocks "${project}/${rel}"; then
    warn "repair malformed or duplicate block markers before acknowledgement"; return 1
  fi
  if [[ "${decision}" != "keep" && -n "${marker}" ]]; then
    has_block "${project}/${rel}" "${marker}" && upgrade_valid_blocks "${project}/${rel}" || { warn "invalid or missing managed blocks"; return 1; }
  fi
  if [[ "${kind}" == "convert" && "${decision}" == "merged" ]]; then
    warn "confirm converted first, then sync again to review content"; return 1
  fi
  if [[ "${kind}" != "convert" && "${decision}" == "converted" ]]; then
    warn "this review is not a format conversion"; return 1
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then info "dry-run: resolve ${rel} as ${decision}"; return 0; fi
  upgrade_begin "${project}" || return 1
  if [[ "${decision}" != "converted" ]]; then
    # The accepted upstream becomes the base, even when the local file differs.
    state_record_file "${rel}" "${target}"
    state_record_all_blocks "${pending}" "${rel}"
    while IFS=$'\t' read -r tag id; do
      if ! has_block "${pending}" "${tag}" "${id}"; then state_record_block "${rel}" "${tag}" "${id}" absent; fi
    done < <(_sync_block_keys "${project}" "${rel}" "${pending}")
    TEMPLATE_DIR="${project}/.vibe-init/pending"
    if ! state_flush "${project}"; then TEMPLATE_DIR="${old_dir}"; return 1; fi
    TEMPLATE_DIR="${old_dir}"
  fi
  state_drop_pending "${project}" "${rel}"
  rm -f "${project}/${rel}.template"
  upgrade_finish "${project}"
  info "resolved ${rel}: ${decision}; run --apply to check for later updates"
}

# Snapshot only managed paths and small mutable bookkeeping. Immutable upstream
# objects may remain after rollback; unreferenced objects are harmless.
upgrade_snapshot_paths() {
  local rel=""
  printf '%s\n' .gitignore .vibe-init/manifest .vibe-init/policy
  for rel in "${TEMPLATE_FILES[@]}"; do
    printf '%s\n' "${rel}" "${rel}.template" ".vibe-init/pending/${rel}" ".vibe-init/pending/${rel}.meta"
  done
}

upgrade_fingerprint() {
  local project="$1" rel="" hash=""
  while IFS= read -r rel; do
    hash="$(upgrade_file_hash "${project}/${rel}")" || return 1
    printf '%s\t%s\n' "${rel}" "${hash}"
  done < <(upgrade_snapshot_paths)
}

upgrade_begin() {
  local project="$1" rel="" id=""
  [[ "${DRY_RUN}" -eq 1 || -n "${UPGRADE_BACKUP}" ]] && return 0
  id="$(date -u '+%Y%m%dT%H%M%SZ').$$"
  UPGRADE_BACKUP="${project}/.vibe-init/backups/${id}"
  while [[ -e "${UPGRADE_BACKUP}" ]]; do UPGRADE_BACKUP="${UPGRADE_BACKUP}x"; done
  mkdir -p "${UPGRADE_BACKUP}/before" || return 1
  upgrade_snapshot_paths > "${UPGRADE_BACKUP}/paths"
  while IFS= read -r rel; do
    if [[ -f "${project}/${rel}" ]]; then
      mkdir -p "${UPGRADE_BACKUP}/before/$(dirname -- "${rel}")"
      cp -p "${project}/${rel}" "${UPGRADE_BACKUP}/before/${rel}" || return 1
    fi
  done < "${UPGRADE_BACKUP}/paths"
  : > "${UPGRADE_BACKUP}/ready"
  info "recovery snapshot: ${UPGRADE_BACKUP}"
}

upgrade_finish() {
  [[ "${DRY_RUN}" -eq 1 || -z "${UPGRADE_BACKUP}" ]] && return 0
  if [[ ! -f "${UPGRADE_BACKUP}/ready" ]]; then UPGRADE_BACKUP=""; return 0; fi
  upgrade_fingerprint "$1" > "${UPGRADE_BACKUP}/after" || return 1
  UPGRADE_BACKUP=""
}

upgrade_rollback() {
  local project="$1" id="$2" dir="${1}/.vibe-init/backups/${2}" rel="" fingerprint=""
  [[ "${id}" =~ ^[0-9TZ.x]+$ ]] || { warn "invalid backup ID"; return 1; }
  [[ -f "${dir}/after" ]] || { warn "no completed snapshot; inspect the before/ directory for manual recovery"; return 1; }
  fingerprint="$(upgrade_fingerprint "${project}")"
  [[ "${fingerprint}" == "$(cat "${dir}/after")" ]] || { warn "files changed after this upgrade; inspect before/ and recover manually"; return 1; }
  if [[ "${DRY_RUN}" -eq 1 ]]; then info "dry-run: restore ${id}"; return 0; fi
  upgrade_begin "${project}" || return 1
  while IFS= read -r rel; do
    if [[ -f "${dir}/before/${rel}" ]]; then
      mkdir -p "${project}/$(dirname -- "${rel}")"
      cp -p "${dir}/before/${rel}" "${project}/${rel}.restore.$$"
      mv "${project}/${rel}.restore.$$" "${project}/${rel}"
    else
      rm -f "${project}/${rel}"
    fi
  done < <(upgrade_snapshot_paths)
  upgrade_finish "${project}"
  info "restored ${id}"
}

upgrade_controls() {
  local project="$1" choice="" rel="" ticket="" expected="" decision="" scope="" tag="" id=""
  local -a choices=()
  choices+=("$(prompt_opt reviews 'Review pending updates' 'merge or keep project rules')")
  choices+=("$(prompt_opt pause 'Pause project upgrades' 'until resumed')")
  choices+=("$(prompt_opt resume 'Resume project upgrades' 'check on next sync')")
  choices+=("$(prompt_opt local 'Let project own a file or block' 'stop following templates')")
  choices+=("$(prompt_opt follow 'Follow templates again' 'file or block')")
  choices+=("$(prompt_opt back 'Back')")
  choice="$(ui_select 'Upgrade controls' back "${choices[@]}")"
  case "${choice}" in
    pause|resume)
      upgrade_begin "${project}" || return 1
      if [[ "${choice}" == pause ]]; then upgrade_set_policy "${project}" updates paused; else upgrade_set_policy "${project}" updates active; fi
      upgrade_finish "${project}" ;;
    local|follow)
      choices=()
      for rel in "${TEMPLATE_FILES[@]}"; do
        choices+=("$(prompt_opt "${rel}" "${rel}")")
        [[ -n "$(modern_marker_tag "${rel}")" ]] || continue
        while IFS=$'\t' read -r tag id; do
          scope="${rel}:${tag}${id:+:${id}}"
          choices+=("$(prompt_opt "${scope}" "${scope}")")
        done < <(list_blocks "${project}/${rel}")
      done
      choices+=("$(prompt_opt back 'Back')")
      scope="$(ui_select 'Choose ownership scope' back "${choices[@]}")"
      [[ "${scope}" == back ]] && return 0
      upgrade_validate_scope "${project}" "${scope}" || return 1
      upgrade_begin "${project}" || return 1
      upgrade_set_policy "${project}" "${scope}" "${choice}"
      upgrade_finish "${project}" ;;
    reviews)
      upgrade_show_pending "${project}"
      choices=()
      for rel in "${TEMPLATE_FILES[@]}"; do
        [[ -f "$(state_pending_path "${project}" "${rel}")" ]] || continue
        choices+=("$(prompt_opt "${rel}" "${rel}")")
      done
      choices+=("$(prompt_opt back 'Back')")
      rel="$(ui_select 'Choose reviewed file' back "${choices[@]}")"
      [[ "${rel}" == back ]] && return 0
      ticket="$(upgrade_ticket "${project}" "${rel}")"
      expected="$(upgrade_file_hash "${project}/${rel}")"
      info "Review this file and its frozen template before acknowledging: ${rel}"
      # The external editor/agent performs the merge. Displaying a fingerprint
      # here binds this human acknowledgement to the content just selected.
      info "reviewed fingerprint: ${expected}"
      choices=("$(prompt_opt merged 'Merge reviewed and complete')" "$(prompt_opt keep 'Keep project version this time')" "$(prompt_opt converted 'Format conversion complete')" "$(prompt_opt back 'Defer this update')")
      decision="$(ui_select 'Confirm your review decision' back "${choices[@]}")"
      [[ "${decision}" == back ]] && return 0
      upgrade_resolve "${project}" "${ticket}" "${expected}" "${decision}" ;;
  esac
  return 0
}
