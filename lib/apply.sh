#!/usr/bin/env bash
# Sourced by vibe-init.sh (not run standalone). Relies on helpers and globals
# defined there: info, warn, ensure_dir, DRY_RUN, TEMPLATE_DIR, TEMPLATE_FILES.
#
# apply mode copies the template files into an EXISTING project. It never
# overwrites or merges what the user already has: when a target file exists, the
# template is written alongside it as <name>.template instead.

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

apply_templates() {
  local project_dir="$1"
  local rel=""

  for rel in "${TEMPLATE_FILES[@]}"; do
    copy_template_or_suffix "${rel}" "${project_dir}/${rel}"
  done
}
