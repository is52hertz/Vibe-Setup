#!/usr/bin/env bash
# lib/block_engine.sh — Block assembly and manipulation engine.
# Compatible with macOS Bash 3.2 and POSIX awk.

# Root for modular blocks
BLOCKS_ROOT="${TEMPLATE_ROOT}/blocks"

list_available_profiles() {
  local f name
  local -a res=()
  for f in "${BLOCKS_ROOT}/profiles/"*.md; do
    [[ -f "${f}" ]] || continue
    name="$(basename -- "${f}" .md)"
    res+=("${name}")
  done
  printf '%s\n' "${res[@]+"${res[@]}"}"
}

list_available_integrations() {
  local f name
  local -a res=()
  for f in "${BLOCKS_ROOT}/integrations/"*.md; do
    [[ -f "${f}" ]] || continue
    name="$(basename -- "${f}" .md)"
    res+=("${name}")
  done
  printf '%s\n' "${res[@]+"${res[@]}"}"
}

# Check if a file contains a specific XML-like block.
# Usage: has_block <file> <tag_name> [id]
has_block() {
  local file="$1"
  local tag="$2"
  local id="${3:-}"

  [[ -f "${file}" ]] || return 1
  if [[ -n "${id}" ]]; then
    grep -q "<${tag}[[:space:]]\+id=[\"']${id}[\"']" "${file}"
  else
    grep -q "<${tag}>" "${file}"
  fi
}

# Assemble AGENTS.md from atomic blocks.
# Usage: assemble_agents_md <target_file> <profile_choice: service|tool|ask|all> <integrations_csv: trellis,...>
assemble_agents_md() {
  local target_file="$1"
  local profile_choice="${2:-ask}"
  local integrations_csv="${3:-}"
  local tmp="${target_file}.tmp.$$"
  local p f integ

  mkdir -p "$(dirname -- "${target_file}")"
  : > "${tmp}"

  # 1. Base blocks
  for f in metadata.md product.md project_phase.md core_rules.md; do
    if [[ -f "${BLOCKS_ROOT}/${f}" ]]; then
      cat "${BLOCKS_ROOT}/${f}" >> "${tmp}"
      printf '\n\n' >> "${tmp}"
    fi
  done

  # 2. Profiles
  case "${profile_choice}" in
    service|tool)
      if [[ -f "${BLOCKS_ROOT}/profiles/${profile_choice}.md" ]]; then
        cat "${BLOCKS_ROOT}/profiles/${profile_choice}.md" >> "${tmp}"
        printf '\n\n' >> "${tmp}"
      fi
      ;;
    *)
      # ask / all: include all available profiles
      for f in "${BLOCKS_ROOT}/profiles/"*.md; do
        [[ -f "${f}" ]] || continue
        cat "${f}" >> "${tmp}"
        printf '\n\n' >> "${tmp}"
      done
      ;;
  esac

  # 3. Integrations
  if [[ -n "${integrations_csv}" ]]; then
    local raw="${integrations_csv//,/ }"
    local -a integs=()
    IFS=' ' read -r -a integs <<< "${raw}"
    for integ in "${integs[@]+"${integs[@]}"}"; do
      if [[ -f "${BLOCKS_ROOT}/integrations/${integ}.md" ]]; then
        cat "${BLOCKS_ROOT}/integrations/${integ}.md" >> "${tmp}"
        printf '\n\n' >> "${tmp}"
      fi
    done
  fi

  # Trim consecutive blank lines
  awk '
    NF { print; blank=0; next }
    !blank { print ""; blank=1 }
  ' "${tmp}" > "${target_file}"
  rm -f "${tmp}"
}

# Assemble CLAUDE.md with optional CC-Workflow block.
# Usage: assemble_claude_md <target_file> <enable_cc_workflow: 0|1>
assemble_claude_md() {
  local target_file="$1"
  local enable_cc="${2:-0}"
  local template_src="${TEMPLATE_ROOT}/CLAUDE.md"
  local tmp="${target_file}.tmp.$$"

  mkdir -p "$(dirname -- "${target_file}")"

  if [[ ! -f "${template_src}" ]]; then
    # Built-in fallback
    cat <<'EOF' > "${target_file}"
@AGENTS.md

## Claude Code

- This file imports AGENTS.md so Claude Code and other coding agents share one source of project instructions.
- Add Claude-specific instructions here only when they are truly needed.
- When you need to ask the user something, prefer Claude Code's built-in question tool (AskUserQuestion).
EOF
    return 0
  fi

  if [[ "${enable_cc}" -eq 1 ]]; then
    cp "${template_src}" "${target_file}"
  else
    # Prune out the CC-WORKFLOW feature block
    awk '
      /<FEATURE[[:space:]]+id="cc-workflow">/ || /<!-- FEATURE:CC-WORKFLOW START -->/ { in_drop = 1; next }
      /<\/FEATURE>/ || /<!-- FEATURE:CC-WORKFLOW END -->/ { in_drop = 0; next }
      in_drop { next }
      { print }
    ' "${template_src}" | awk '
      NF { print; blank=0; next }
      !blank { print ""; blank=1 }
    ' > "${target_file}"
  fi
}

# Replace an existing block in a file with new content.
# Usage: replace_block <file> <tag_name> <id_or_empty> <replacement_file>
replace_block() {
  local file="$1"
  local tag="$2"
  local id="$3"
  local repl_file="$4"
  local tmp="${file}.repl.$$"

  [[ -f "${file}" && -f "${repl_file}" ]] || return 1

  awk -v tag="${tag}" -v id="${id}" -v repl="${repl_file}" '
    BEGIN {
      in_block = 0
      found = 0
      start_pat = (id != "") ? ("<" tag "[[:space:]]+id=[\x22\x27]" id "[\x22\x27]") : ("<" tag ">")
      end_pat = "</" tag ">"
    }
    $0 ~ start_pat {
      in_block = 1
      found = 1
      while ((getline line < repl) > 0) {
        print line
      }
      close(repl)
      next
    }
    in_block {
      if ($0 ~ end_pat) {
        in_block = 0
      }
      next
    }
    { print }
    END {
      if (!found) exit 2
    }
  ' "${file}" > "${tmp}" || {
    rm -f "${tmp}"
    return 1
  }

  mv "${tmp}" "${file}"
  return 0
}

# Remove an existing block from a file.
# Usage: remove_block <file> <tag_name> <id_or_empty>
remove_block() {
  local file="$1"
  local tag="$2"
  local id="$3"
  local tmp="${file}.rm.$$"

  [[ -f "${file}" ]] || return 1

  awk -v tag="${tag}" -v id="${id}" '
    BEGIN {
      in_block = 0
      start_pat = (id != "") ? ("<" tag "[[:space:]]+id=[\x22\x27]" id "[\x22\x27]") : ("<" tag ">")
      end_pat = "</" tag ">"
    }
    $0 ~ start_pat {
      in_block = 1
      next
    }
    in_block {
      if ($0 ~ end_pat) {
        in_block = 0
      }
      next
    }
    { print }
  ' "${file}" | awk '
    NF { print; blank=0; next }
    !blank { print ""; blank=1 }
  ' > "${tmp}"

  mv "${tmp}" "${file}"
  return 0
}

# Append a block to the end of a file if not already present.
# Usage: append_block_if_missing <file> <tag_name> <id> <content_file>
append_block_if_missing() {
  local file="$1"
  local tag="$2"
  local id="$3"
  local content_file="$4"

  [[ -f "${file}" && -f "${content_file}" ]] || return 1
  if has_block "${file}" "${tag}" "${id}"; then
    return 0
  fi

  printf '\n\n' >> "${file}"
  cat "${content_file}" >> "${file}"
  printf '\n' >> "${file}"
}
