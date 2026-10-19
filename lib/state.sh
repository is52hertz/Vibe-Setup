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
#   schema  2
#   version 1.2.0  (last tool used, not proof that reviews are resolved)
#   file    AGENTS.md                       <hash>
#   block   AGENTS.md   CORE_RULES          <hash>
#   block   AGENTS.md   PROFILE     tool    <hash>
#
# The file is written by the tool and read by the tool; it is not documentation
# and is not meant to be edited by hand.
#
# base/<hash> stores immutable upstream text for portable three-way reviews.
# pending/<rel> freezes a proposal until explicit acknowledgement. Deleting the
# .template never changes the baseline. Policy and bases should be committed;
# pending reviews, recovery snapshots and locks remain local.
#
# Compatible with macOS Bash 3.2.

VIBE_STATE_DIR_NAME=".vibe-init"
VIBE_STATE_SCHEMA=2

# Records staged by this run, each already tab-joined. Flushed by state_flush,
# which merges them into whatever the manifest already holds.
STATE_RECORDS=()

# Header values for the next flush. Empty means "keep what the manifest says"
# — apply mode assembles with profile=ask and must not clobber the real choice
# a scaffold recorded.
STATE_SET_PROFILE=""
STATE_SET_INTEGRATIONS=""
STATE_SET_CC=""
STATE_SET_CHECKLIST=""
# "paused" after this tool ran `trellis ablate`, "active" after a restore,
# "none" after an uninstall. Only read while .trellis/ is absent, to tell a
# paused project from one that never had Trellis.
STATE_SET_TRELLIS=""

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
  local project_dir="$1" rel="$2" src="$3" pending="" kind="merge" marker="" version="unknown"
  [[ "${DRY_RUN}" -eq 1 ]] && return 0
  pending="$(state_pending_path "${project_dir}" "${rel}")"
  # Freeze a review until it is explicitly resolved. Later releases wait.
  if [[ ! -f "${pending}" ]]; then
    mkdir -p "$(dirname -- "${pending}")"
    cp "${src}" "${pending}.tmp.$$" || return 1
    mv "${pending}.tmp.$$" "${pending}" || return 1
    version="${VIBE_INIT_VERSION}"
  fi
  if [[ ! -f "${pending}.meta" ]]; then
    marker="$(modern_marker_tag "${rel}")"
    if [[ -n "${marker}" && -f "${project_dir}/${rel}" ]] && ! has_block "${project_dir}/${rel}" "${marker}"; then kind="convert"; fi
    {
      printf 'target\t%s\n' "$(hash_file "${pending}")"
      printf 'version\t%s\n' "${version}"
      printf 'kind\t%s\n' "${kind}"
    } > "${pending}.meta.tmp.$$" || return 1
    mv "${pending}.meta.tmp.$$" "${pending}.meta" || return 1
  fi
}

# Forget the kept template for <rel>, once it has become the merge base.
# Usage: state_drop_pending <project_dir> <relative_path>
state_drop_pending() {
  [[ "${DRY_RUN}" -eq 1 ]] && return 0
  rm -f "$(state_pending_path "$1" "$2")" "$(state_pending_path "$1" "$2").meta"
}

# Write the staged records into the project's manifest, keeping every record
# this run did not touch. Honors --dry-run. Only private upgrade artifacts are
# ignored; the manifest, policy and upstream base objects should be committed.
#
# A run with nothing to record still writes the manifest. It used to return
# early instead, and an old project whose every file needed review or a format
# conversion — exactly the project that most needs a merge base — never got a
# .vibe-init/ at all.
# Usage: state_flush <project_dir>
state_flush() {
  local project_dir="$1"
  local dir="" manifest="" tmp_new="" tmp_out="" rec=""
  local profile="" integrations="" cc="" checklist="" trellis="" created=""

  state_check_schema "${project_dir}" || return 1
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
  checklist="${STATE_SET_CHECKLIST:-$(state_get "${project_dir}" test_checklist)}"
  trellis="${STATE_SET_TRELLIS:-$(state_get "${project_dir}" trellis)}"
  created="$(state_get "${project_dir}" created)"
  [[ -n "${created}" ]] || created="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  mkdir -p "${dir}" || { warn "could not create ${dir}; skipping state record"; return 1; }

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
    printf 'test_checklist\t%s\n' "${checklist}"
    printf 'trellis\t%s\n'      "${trellis}"
    # Old records first, minus the exact keys this run re-recorded, then the new
    # ones. Sorted so a manifest diff stays readable.
    {
      if [[ -f "${manifest}" ]]; then
        # FILENAME == ARGV[1], not NR == FNR: a run can stage nothing at all
        # (record_trellis_state only sets a header field), and with an empty
        # first file NR == FNR stays true for every line of the second one —
        # which silently dropped every hash in the manifest and took the merge
        # base with it, turning the next sync's every file into a conflict.
        awk -F'\t' '
          FILENAME == ARGV[1] {
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

  state_capture_bases "${project_dir}" "${tmp_new}" || {
    rm -f "${tmp_new}" "${tmp_out}"
    return 1
  }
  if [[ -f "${manifest}" ]] && cmp -s <(awk -F'\t' '$1 != "updated"' "${manifest}") <(awk -F'\t' '$1 != "updated"' "${tmp_out}"); then
    rm -f "${tmp_out}"
  else
    mv "${tmp_out}" "${manifest}"
  fi
  rm -f "${tmp_new}"
  STATE_RECORDS=()

  ensure_state_gitignored "${project_dir}"
}

# Ignore private artifacts while allowing portable state to be committed.
# For a non-repo there is nothing to ignore, and vibe-init does not create a
# .gitignore for a project that is not under version control.
# Usage: ensure_state_gitignored <project_dir>
ensure_state_gitignored() {
  local project_dir="$1" gitignore="${1}/.gitignore" tmp="" rule=""
  command -v git >/dev/null 2>&1 || return 0
  git -C "${project_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run: keep manifest, policy and base trackable; ignore local upgrade artifacts"
    return 0
  fi
  tmp="${gitignore}.vibe.$$"
  # Migrate only the exact ignore rule emitted by schema 1.
  if [[ -f "${gitignore}" ]]; then
    awk '$0 != ".vibe-init/" && $0 != "# vibe-init bookkeeping (local; safe to delete)" { print }' "${gitignore}" > "${tmp}"
  else
    : > "${tmp}"
  fi
  for rule in '/.vibe-init/pending/' '/.vibe-init/backups/' '/.vibe-init/lock/'; do
    grep -qxF -- "${rule}" "${tmp}" || printf '\n%s\n' "${rule}" >> "${tmp}"
  done
  if [[ -f "${gitignore}" ]] && cmp -s "${tmp}" "${gitignore}"; then rm -f "${tmp}"; else mv "${tmp}" "${gitignore}"; fi
}

# Refuse future schemas instead of rewriting them with an older tool.
state_check_schema() {
  local schema=""
  schema="$(state_get "$1" schema)"
  case "${schema}" in
    ''|1|2) return 0 ;;
    *) warn "unsupported state schema: ${schema}; use a newer vibe-init"; return 1 ;;
  esac
}

# Immutable objects contain upstream text only, never the project's customized
# result. Hash-only schema-1 records remain useful even without their object.
state_store_base() {
  local dir="${1}/.vibe-init/base" hash="$2" src="$3"
  [[ "${DRY_RUN}" -eq 1 ]] && return 0
  [[ "$(hash_file "${src}")" == "${hash}" ]] || return 1
  mkdir -p "${dir}" || return 1
  if [[ -f "${dir}/${hash}" ]]; then
    [[ "$(hash_file "${dir}/${hash}")" == "${hash}" ]] || { warn "corrupt upstream base object: ${hash}"; return 1; }
  else
    cp "${src}" "${dir}/${hash}.tmp.$$" || return 1
    mv "${dir}/${hash}.tmp.$$" "${dir}/${hash}" || return 1
  fi
}

state_capture_bases() {
  local record=""
  local project_dir="$1" records="$2" kind="" rel="" tag="" id="" hash="" src="" frag=""
  [[ -n "${TEMPLATE_DIR:-}" ]] || return 0
  while IFS= read -r record; do
    kind="$(printf '%s\n' "${record}" | cut -f1)"
    rel="$(printf '%s\n' "${record}" | cut -f2)"
    src="${TEMPLATE_DIR}/${rel}"
    [[ -f "${src}" ]] || continue
    if [[ "${kind}" == "file" ]]; then
      hash="$(printf '%s\n' "${record}" | cut -f3)"
      if [[ "$(hash_file "${src}")" == "${hash}" ]]; then
        state_store_base "${project_dir}" "${hash}" "${src}" || return 1
      fi
    else
      tag="$(printf '%s\n' "${record}" | cut -f3)"
      id="$(printf '%s\n' "${record}" | cut -f4)"
      hash="$(printf '%s\n' "${record}" | cut -f5)"
      if [[ "$(hash_block "${src}" "${tag}" "${id}" || true)" == "${hash}" ]]; then
        frag="$(mktemp "${TMPDIR:-/tmp}/vibe-base.XXXXXX")"
        extract_block "${src}" "${tag}" "${id}" > "${frag}"
        state_store_base "${project_dir}" "${hash}" "${frag}" || { rm -f "${frag}"; return 1; }
        rm -f "${frag}"
      fi
    fi
  done < "${records}"
  return 0
}
