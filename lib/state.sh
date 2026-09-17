#!/usr/bin/env bash
# lib/state.sh — the .vibe-init/ state manifest: what this tool last wrote.
#
# Sourced by vibe-init.sh (not run standalone). Relies on helpers and globals
# defined there: info, warn, run_cmd, ensure_dir, DRY_RUN, VIBE_INIT_VERSION —
# plus lib/block_engine.sh for list_blocks / extract_block.
#
# Why it exists: without a record of what vibe-init itself wrote, sync can only
# ask "does this file exist?", which is not the question. The question is "did
# the user change it?" — and answering that needs a merge base. The manifest is
# that base: the content hash of every file and every <TAG> block as this tool
# last left it. With it, sync becomes an ordinary three-way merge (see
# merge_verdict in lib/sync.sh) instead of a guess.
#
# Format: tab-separated, one record per line, so awk can read it and no JSON
# parser is needed (the tool depends on nothing beyond bash, coreutils and awk).
#
#   schema  1
#   version 1.1.0
#   file    AGENTS.md                       <hash>
#   block   AGENTS.md   CORE_RULES          <hash>
#   block   AGENTS.md   PROFILE     tool    <hash>
#
# The file is written by the tool and read by the tool; it is not documentation
# and is not meant to be edited by hand.
#
# Beside it, .vibe-init/pending/<rel> keeps the exact template handed to the
# user's AI agent as <rel>.template. The merge happens outside this tool, and
# the only thing that comes back is the agent deleting that .template, as the
# prompt asks. Once it is gone, the kept copy is the version the user merged
# against — the right merge base from then on (see lib/sync.sh).
#
# Compatible with macOS Bash 3.2.

VIBE_STATE_DIR_NAME=".vibe-init"
VIBE_STATE_SCHEMA=1

# Records staged by this run, each already tab-joined. Flushed by state_flush,
# which merges them into whatever the manifest already holds.
STATE_RECORDS=()

# Header values for the next flush. Empty means "keep what the manifest says"
# — apply mode assembles with profile=ask and must not clobber the real choice
# a scaffold recorded.
STATE_SET_PROFILE=""
STATE_SET_INTEGRATIONS=""
STATE_SET_CC=""

state_dir()  { printf '%s\n' "${1}/${VIBE_STATE_DIR_NAME}"; }
state_path() { printf '%s\n' "${1}/${VIBE_STATE_DIR_NAME}/manifest"; }

# Where the template handed out as <rel>.template is kept until it is resolved.
# Usage: state_pending_path <project_dir> <relative_path>
state_pending_path() { printf '%s\n' "${1}/${VIBE_STATE_DIR_NAME}/pending/${2}"; }

# True when the project carries a manifest, i.e. vibe-init knows what it wrote.
state_is_tracked() { [[ -f "$(state_path "$1")" ]]; }

# -----------------------------------------------------------------------------
# Hashing
# -----------------------------------------------------------------------------

# Hash stdin. sha256 wherever a tool for it exists (sha256sum on Linux, shasum
# on macOS); cksum is the POSIX floor. This is change detection between two
# copies of our own templates, not tamper detection, so the weak fallback is
# still correct — it only has to notice an edit.
_hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  else
    cksum | awk '{ print $1 "-" $2 }'
  fi
}

# Content hash of a whole file; empty (status 1) when there is no such file.
hash_file() {
  [[ -f "$1" ]] || return 1
  _hash_stdin < "$1"
}

# Content hash of one <TAG> block, tag lines included, so the hash of a block
# inside a project file is directly comparable with the hash of the template
# fragment that produced it. Empty (status 1) when the block is not there.
# Usage: hash_block <file> <tag> [id]
hash_block() {
  local file="$1" tag="$2" id="${3:-}" content=""

  content="$(extract_block "${file}" "${tag}" "${id}")" || return 1
  [[ -n "${content}" ]] || return 1
  printf '%s\n' "${content}" | _hash_stdin
}

# -----------------------------------------------------------------------------
# Reading
# -----------------------------------------------------------------------------

# Value of a scalar header key ("version", "profile", …); empty when unset or
# when the project has no manifest at all.
# Usage: state_get <project_dir> <key>
state_get() {
  local manifest=""
  manifest="$(state_path "$1")"
  [[ -f "${manifest}" ]] || return 0
  awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "${manifest}"
}

# The hash this tool last wrote for a whole file; empty when it never did.
# Usage: state_file_hash <project_dir> <relative_path>
state_file_hash() {
  local manifest=""
  manifest="$(state_path "$1")"
  [[ -f "${manifest}" ]] || return 0
  awk -F'\t' -v r="$2" '$1 == "file" && $2 == r { print $3; exit }' "${manifest}"
}

# The hash this tool last wrote for one block; empty when it never did.
# Usage: state_block_hash <project_dir> <relative_path> <tag> <id>
state_block_hash() {
  local manifest=""
  manifest="$(state_path "$1")"
  [[ -f "${manifest}" ]] || return 0
  awk -F'\t' -v r="$2" -v t="$3" -v i="${4:-}" \
    '$1 == "block" && $2 == r && $3 == t && $4 == i { print $5; exit }' "${manifest}"
}

# True when a template was handed out as <rel>.template and the agent is done
# with it: the kept copy exists and the .template beside the file is gone.
# Usage: state_pending_resolved <project_dir> <relative_path>
state_pending_resolved() {
  [[ -f "$(state_pending_path "$1" "$2")" && ! -e "${1}/${2}.template" ]]
}

# -----------------------------------------------------------------------------
# Writing
# -----------------------------------------------------------------------------

# Stage the hash of a file / a block for the next flush. Callers record only
# what they know the tool wrote (or verified byte-identical to the template);
# a conflicted file is deliberately left unrecorded so its old merge base
# survives to the next run.
state_record_file() {
  STATE_RECORDS+=("$(printf 'file\t%s\t%s' "$1" "$2")")
}

state_record_block() {
  STATE_RECORDS+=("$(printf 'block\t%s\t%s\t%s\t%s' "$1" "$2" "${3:-}" "$4")")
}

# Stage every block of a file at its current content — used right after the
# tool wrote that file from the template, when all of it is known-ours.
# Usage: state_record_all_blocks <file> <relative_path>
state_record_all_blocks() {
  local file="$1" rel="$2" tag="" id="" h=""

  [[ -f "${file}" ]] || return 0
  while IFS=$'\t' read -r tag id; do
    [[ -n "${tag}" ]] || continue
    h="$(hash_block "${file}" "${tag}" "${id}")" || continue
    state_record_block "${rel}" "${tag}" "${id}" "${h}"
  done < <(list_blocks "${file}")
}

# Keep the template just handed out as <rel>.template. Honors --dry-run.
# Usage: state_save_pending <project_dir> <relative_path> <template_file>
state_save_pending() {
  local pending=""

  [[ "${DRY_RUN}" -eq 1 ]] && return 0
  pending="$(state_pending_path "$1" "$2")"
  mkdir -p "$(dirname -- "${pending}")" && cp "$3" "${pending}" \
    || warn "could not keep the handed-out template for $2"
}

# Forget the kept template for <rel>, once it has become the merge base.
# Usage: state_drop_pending <project_dir> <relative_path>
state_drop_pending() {
  [[ "${DRY_RUN}" -eq 1 ]] && return 0
  rm -f "$(state_pending_path "$1" "$2")"
}

# Write the staged records into the project's manifest, keeping every record
# this run did not touch. Honors --dry-run. Also makes sure a git-tracked
# project ignores the directory, so the tool's private bookkeeping never turns
# up in the user's diffs.
#
# A run with nothing to record still writes the manifest. It used to return
# early instead, and an old project whose every file needed review or a format
# conversion — exactly the project that most needs a merge base — never got a
# .vibe-init/ at all.
# Usage: state_flush <project_dir>
state_flush() {
  local project_dir="$1"
  local dir="" manifest="" tmp_new="" tmp_out="" rec=""
  local profile="" integrations="" cc="" created=""

  dir="$(state_dir "${project_dir}")"
  manifest="$(state_path "${project_dir}")"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    if [[ "${#STATE_RECORDS[@]}" -gt 0 ]]; then
      info "dry-run: record ${#STATE_RECORDS[@]} content hashes in ${VIBE_STATE_DIR_NAME}/manifest"
    else
      info "dry-run: write ${VIBE_STATE_DIR_NAME}/manifest"
    fi
    STATE_RECORDS=()
    ensure_state_gitignored "${project_dir}"
    return
  fi

  # Header values: an explicit choice from this run wins, otherwise whatever the
  # manifest already says (apply mode assembles with profile=ask and must not
  # overwrite the real answer a scaffold recorded).
  profile="${STATE_SET_PROFILE:-$(state_get "${project_dir}" profile)}"
  integrations="${STATE_SET_INTEGRATIONS:-$(state_get "${project_dir}" integrations)}"
  cc="${STATE_SET_CC:-$(state_get "${project_dir}" cc_workflow)}"
  created="$(state_get "${project_dir}" created)"
  [[ -n "${created}" ]] || created="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  mkdir -p "${dir}" || { warn "could not create ${dir}; skipping state record"; return; }

  tmp_new="${manifest}.new.$$"
  tmp_out="${manifest}.out.$$"
  # One record per key, the last one staged winning: a run can stage the same
  # block twice — the base a resolved merge promotes, then what this sync found
  # — and two lines for one key would leave the lookup to sort order.
  for rec in "${STATE_RECORDS[@]+"${STATE_RECORDS[@]}"}"; do
    printf '%s\n' "${rec}"
  done | awk -F'\t' '
    { key = ($1 == "file") ? $1 FS $2 : $1 FS $2 FS $3 FS $4
      if (!(key in last)) order[++n] = key
      last[key] = $0 }
    END { for (i = 1; i <= n; i++) print last[order[i]] }
  ' > "${tmp_new}"

  {
    printf '# vibe-init state — written by the tool, do not edit by hand\n'
    printf 'schema\t%s\n'       "${VIBE_STATE_SCHEMA}"
    printf 'version\t%s\n'      "${VIBE_INIT_VERSION}"
    printf 'created\t%s\n'      "${created}"
    printf 'updated\t%s\n'      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'profile\t%s\n'      "${profile}"
    printf 'integrations\t%s\n' "${integrations}"
    printf 'cc_workflow\t%s\n'  "${cc}"
    # Old records first, minus the exact keys this run re-recorded, then the new
    # ones. Sorted so a manifest diff stays readable.
    {
      if [[ -f "${manifest}" ]]; then
        awk -F'\t' '
          NR == FNR {
            if ($1 == "file")       seen[$1 FS $2] = 1
            else if ($1 == "block") seen[$1 FS $2 FS $3 FS $4] = 1
            next
          }
          $1 == "file"  { if (($1 FS $2) in seen) next; print; next }
          $1 == "block" { if (($1 FS $2 FS $3 FS $4) in seen) next; print; next }
        ' "${tmp_new}" "${manifest}"
      fi
      cat "${tmp_new}"
    } | sort
  } > "${tmp_out}"

  mv "${tmp_out}" "${manifest}"
  rm -f "${tmp_new}"
  STATE_RECORDS=()

  ensure_state_gitignored "${project_dir}"
}

# Make sure a git repository ignores the state directory. Detection only for a
# non-repo: there is nothing to ignore, and vibe-init does not create a
# .gitignore for a project that is not under version control.
# Usage: ensure_state_gitignored <project_dir>
ensure_state_gitignored() {
  local project_dir="$1"
  local gitignore="${project_dir}/.gitignore"
  local entry="${VIBE_STATE_DIR_NAME}/"

  command -v git >/dev/null 2>&1 || return 0
  git -C "${project_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  # Already ignored — by our own line or by anything else the user wrote.
  if [[ -f "${gitignore}" ]] && grep -qxF -- "${entry}" "${gitignore}"; then
    return 0
  fi
  if git -C "${project_dir}" check-ignore -q "${VIBE_STATE_DIR_NAME}" 2>/dev/null; then
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run: add ${entry} to ${gitignore}"
    return 0
  fi

  # A file that does not end in a newline would otherwise swallow our entry
  # into its last line.
  if [[ -s "${gitignore}" ]] && [[ -n "$(tail -c 1 "${gitignore}")" ]]; then
    printf '\n' >> "${gitignore}"
  fi
  {
    printf '\n# vibe-init bookkeeping (local; safe to delete)\n'
    printf '%s\n' "${entry}"
  } >> "${gitignore}"
  info "added ${entry} to .gitignore"
}
