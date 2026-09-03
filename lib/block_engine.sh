#!/usr/bin/env bash
# lib/block_engine.sh — assembles the template set out of atomic <TAG> blocks and
# edits those blocks in place inside an existing project file.
#
# Sourced by vibe-init.sh (not run standalone). Relies on globals defined there:
# TEMPLATE_ROOT, DRY_RUN, and the info/warn helpers.
#
# The template set is not a directory of pre-baked variants any more. Everything
# under templates/blocks/ is an atomic fragment; a run picks the fragments it
# needs (profile, integrations, features) and materializes one concrete set into
# a staging directory, which is what the rest of the script copies from.
#
# Compatible with macOS Bash 3.2 and POSIX awk (no associative arrays, no
# mapfile, no GNU-only awk extensions).

# TEMPLATE_ROOT can be overridden by --template-dir *after* this file is sourced,
# so both roots are resolved per call rather than captured at source time.
blocks_root() { printf '%s\n' "${TEMPLATE_ROOT}/blocks"; }
common_root() { printf '%s\n' "${TEMPLATE_ROOT}/common"; }

# Names of the fragments available under blocks/<kind>/, one per line. These are
# what makes the set extensible: dropping a new file into blocks/profiles/ or
# blocks/integrations/ makes it available with no code change.
list_block_names() {
  local kind="$1"
  local f="" name=""
  local -a res=()

  for f in "$(blocks_root)/${kind}/"*.md; do
    [[ -f "${f}" ]] || continue
    name="$(basename -- "${f}" .md)"
    res+=("${name}")
  done
  printf '%s\n' "${res[@]+"${res[@]}"}"
}

list_available_profiles()     { list_block_names "profiles"; }
list_available_integrations() { list_block_names "integrations"; }

# True when <file> contains the opening tag of a block. With an id, only an
# opening tag carrying that id matches (e.g. <PROFILE id="tool">).
# Usage: has_block <file> <tag_name> [id]
has_block() {
  local file="$1"
  local tag="$2"
  local id="${3:-}"

  [[ -f "${file}" ]] || return 1
  if [[ -n "${id}" ]]; then
    grep -q "<${tag}[[:space:]]\{1,\}id=[\"']${id}[\"']" "${file}"
  else
    grep -q "<${tag}>" "${file}"
  fi
}

# Append one file to another with exactly one blank line between them.
_append_fragment() {
  local src="$1"
  local dest="$2"

  [[ -f "${src}" ]] || return 0
  cat "${src}" >> "${dest}"
  printf '\n\n' >> "${dest}"
}

# Normalize the whitespace of a generated file: no leading or trailing blank
# lines, and runs of blank lines between fragments collapsed to one. Only ever
# used on files this engine just assembled — never on a file the user may have
# edited. A trailing blank line here is what later makes a removed block leave a
# double blank behind, so it matters more than it looks.
_squeeze_blank_lines() {
  local src="$1"
  local dest="$2"

  awk '
    NF {
      if (started && blank) {
        print ""
      }
      started = 1
      blank = 0
      print
      next
    }
    started { blank = 1 }
  ' "${src}" > "${dest}"
}

# Assemble AGENTS.md out of blocks.
#   profile_choice   service|tool  -> only that <PROFILE> block
#                    ask|all       -> every profile plus the one-time
#                                     <PROFILE_SETUP> note telling the project's
#                                     AI to resolve the choice and delete the rest
#   integrations_csv comma/space separated ids from blocks/integrations/
# Usage: assemble_agents_md <target_file> <profile_choice> <integrations_csv>
assemble_agents_md() {
  local target_file="$1"
  local profile_choice="${2:-ask}"
  local integrations_csv="${3:-}"
  local blocks="" tmp="" f="" integ=""
  local -a integs=()

  blocks="$(blocks_root)"
  tmp="${target_file}.assemble.$$"

  mkdir -p "$(dirname -- "${target_file}")"
  : > "${tmp}"

  for f in metadata.md product.md project_phase.md core_rules.md; do
    _append_fragment "${blocks}/${f}" "${tmp}"
  done

  case "${profile_choice}" in
    service|tool)
      _append_fragment "${blocks}/profiles/${profile_choice}.md" "${tmp}"
      ;;
    *)
      _append_fragment "${blocks}/profile_setup.md" "${tmp}"
      for f in "${blocks}/profiles/"*.md; do
        _append_fragment "${f}" "${tmp}"
      done
      ;;
  esac

  if [[ -n "${integrations_csv//[, ]/}" ]]; then
    IFS=' ' read -r -a integs <<< "${integrations_csv//,/ }"
    for integ in "${integs[@]+"${integs[@]}"}"; do
      _append_fragment "${blocks}/integrations/${integ}.md" "${tmp}"
    done
  fi

  _squeeze_blank_lines "${tmp}" "${target_file}"
  rm -f "${tmp}"
}

# Assemble CLAUDE.md: the common skeleton, plus the CC-Workflow reference block
# when the feature is on. Composition only — nothing is ever parsed back out.
# Usage: assemble_claude_md <target_file> <enable_cc_workflow: 0|1>
assemble_claude_md() {
  local target_file="$1"
  local enable_cc="${2:-0}"
  local skeleton="" tmp=""

  skeleton="$(common_root)/CLAUDE.md"
  tmp="${target_file}.assemble.$$"

  mkdir -p "$(dirname -- "${target_file}")"
  [[ -f "${skeleton}" ]] || return 1

  : > "${tmp}"
  _append_fragment "${skeleton}" "${tmp}"
  if [[ "${enable_cc}" -eq 1 ]]; then
    _append_fragment "$(blocks_root)/features/cc-workflow/claude-ref.md" "${tmp}"
  fi

  _squeeze_blank_lines "${tmp}" "${target_file}"
  rm -f "${tmp}"
}

# Which CC-Cowork-Workflow.md variant fits a set of integrations. The Trellis
# variant spells the co-work loop in Trellis commands (task.py, trellis-check);
# the base one describes the same loop in plain project terms.
cc_workflow_variant() {
  local integrations_csv="${1:-}"

  case ",${integrations_csv//[[:space:]]/}," in
    *,trellis,*) printf 'trellis\n' ;;
    *)           printf 'base\n' ;;
  esac
}

# Build one concrete template set into <out_dir>: the static files from
# templates/common/, plus the two assembled files, plus the CC-Workflow document
# when that feature is on. Everything downstream (scaffold copies and apply mode)
# reads from the result, so there is exactly one place where a variant is decided.
# Usage: materialize_template_set <out_dir> <profile> <integrations_csv> <enable_cc>
materialize_template_set() {
  local out_dir="$1"
  local profile="${2:-ask}"
  local integrations_csv="${3:-}"
  local enable_cc="${4:-0}"
  local common="" cc_src=""

  common="$(common_root)"
  mkdir -p "${out_dir}"

  if [[ -d "${common}" ]]; then
    # src/. copies hidden entries (.claude/) too, on both BSD and GNU cp.
    cp -R "${common}/." "${out_dir}/"
  else
    warn "template common dir not found: ${common}; falling back to built-in placeholders"
  fi

  if [[ -d "$(blocks_root)" ]]; then
    assemble_agents_md "${out_dir}/AGENTS.md" "${profile}" "${integrations_csv}"
    assemble_claude_md "${out_dir}/CLAUDE.md" "${enable_cc}"
  else
    warn "template blocks dir not found: $(blocks_root); falling back to built-in placeholders"
  fi

  if [[ "${enable_cc}" -eq 1 ]]; then
    cc_src="$(blocks_root)/features/cc-workflow/$(cc_workflow_variant "${integrations_csv}").md"
    if [[ -f "${cc_src}" ]]; then
      cp "${cc_src}" "${out_dir}/CC-Cowork-Workflow.md"
    else
      warn "CC-Workflow template not found: ${cc_src}"
    fi
  fi
}

# Replace the contents of one block in <file> with <replacement_file>, which is
# expected to carry its own opening and closing tags. Everything outside the
# block is preserved byte for byte. Returns 1 when the block is not there.
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

# Drop one block from <file>, tags included, along with the single blank line
# directly above it — the exact inverse of append_block_if_missing, so enabling
# and then disabling a feature leaves the file byte for byte as it started.
# Everything else keeps the spacing the user gave it. Returns 1 when the block is
# not there, so callers can tell "removed it" from "there was nothing to remove".
# Usage: remove_block <file> <tag_name> <id_or_empty>
remove_block() {
  local file="$1"
  local tag="$2"
  local id="$3"
  local tmp="${file}.rm.$$"

  [[ -f "${file}" ]] || return 1
  has_block "${file}" "${tag}" "${id}" || return 1

  # One line of lookahead: a blank line is held back rather than printed, so the
  # blank that introduced the block can be dropped once the block turns up. A run
  # of blank lines only ever loses its last line, and only to a block.
  awk -v tag="${tag}" -v id="${id}" '
    BEGIN {
      in_block = 0
      pending_blank = 0
      start_pat = (id != "") ? ("<" tag "[[:space:]]+id=[\x22\x27]" id "[\x22\x27]") : ("<" tag ">")
      end_pat = "</" tag ">"
    }
    in_block {
      if ($0 ~ end_pat) {
        in_block = 0
      }
      next
    }
    $0 ~ start_pat {
      pending_blank = 0
      in_block = 1
      next
    }
    /^[[:space:]]*$/ {
      if (pending_blank) {
        print ""
      }
      pending_blank = 1
      next
    }
    {
      if (pending_blank) {
        print ""
        pending_blank = 0
      }
      print
    }
    END {
      if (pending_blank) {
        print ""
      }
    }
  ' "${file}" > "${tmp}" || {
    rm -f "${tmp}"
    return 1
  }

  mv "${tmp}" "${file}"
  return 0
}

# Append a block to <file> unless it is already there. Returns 1 on a missing
# input file, 0 both when it appends and when the block already exists.
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

  printf '\n' >> "${file}"
  cat "${content_file}" >> "${file}"
}
