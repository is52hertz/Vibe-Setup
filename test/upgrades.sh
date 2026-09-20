#!/usr/bin/env bash
# Real state transitions in isolated directories; compatible with Bash 3.2.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
is() { if [[ "$2" == "$3" ]]; then ok "$1"; else ko "$1: got [$2], expected [$3]"; fi; }
yes() { local label="$1"; shift; if "$@"; then ok "${label}"; else ko "${label}"; fi; }
no() { local label="$1"; shift; if "$@"; then ko "${label}"; else ok "${label}"; fi; }
info() { :; }; warn() { :; }; ensure_dir() { [[ "${DRY_RUN}" -eq 1 ]] || mkdir -p "$1"; }
DRY_RUN=0 VIBE_INIT_VERSION=test ASSUME_DEFAULTS=1 APPLY_FILES='' ON_EXISTS=''
. "${ROOT}/lib/ui.sh"
. "${ROOT}/lib/prompt.sh"
. "${ROOT}/lib/block_engine.sh"
. "${ROOT}/lib/state.sh"
. "${ROOT}/lib/sync.sh"
. "${ROOT}/lib/upgrade.sh"
. "${ROOT}/lib/trellis.sh"
. "${ROOT}/lib/apply.sh"
TEMPLATE_FILES=(AGENTS.md CLAUDE.md)
TEMPLATE_DIR="${WORK}/templates"
TEMPLATE_SET_LABEL=test
mkdir -p "${TEMPLATE_DIR}"
base_template() {
  cat > "${TEMPLATE_DIR}/AGENTS.md" <<'EOF'
<CORE_RULES>
upstream one
</CORE_RULES>

<PRODUCT>
product placeholder
</PRODUCT>

<EXTRA>
retirable
</EXTRA>
EOF
  printf '<CLAUDE_BASE>\nbase\n</CLAUDE_BASE>\n' > "${TEMPLATE_DIR}/CLAUDE.md"
}
base_template
P="${WORK}/project"
mkdir -p "${P}"
sync_run "${P}" apply "${TEMPLATE_FILES[@]}"
base_hash="$(state_block_hash "${P}" AGENTS.md CORE_RULES '')"
yes 'complete upstream block stored' test -f "${P}/.vibe-init/base/${base_hash}"
no 'upstream base excludes local content' grep -q local "${P}/.vibe-init/base/${base_hash}"
state_flush "${P}"
is 'empty flush preserves block baseline' "$(state_block_hash "${P}" AGENTS.md CORE_RULES '')" "${base_hash}"
is 'state upgraded to schema two' "$(state_get "${P}" schema)" 2

# Only project text changes: keep without creating a review.
sed 's/upstream one/local customization/' "${P}/AGENTS.md" > "${WORK}/edited"
mv "${WORK}/edited" "${P}/AGENTS.md"
sync_run "${P}" apply AGENTS.md
is 'local edit is quiet' "${SYNC_N_REVIEW}" 0
is 'local edit retains upstream base' "$(state_block_hash "${P}" AGENTS.md CORE_RULES '')" "${base_hash}"
# Both change: freeze the proposal, even across a second upstream release.
sed 's/upstream one/upstream two/' "${TEMPLATE_DIR}/AGENTS.md" > "${WORK}/edited"
mv "${WORK}/edited" "${TEMPLATE_DIR}/AGENTS.md"
sync_run "${P}" apply AGENTS.md
is 'both sides changed opens a review' "${SYNC_N_REVIEW}" 1
ticket="$(upgrade_ticket "${P}" AGENTS.md)"
expected="$(hash_file "${P}/AGENTS.md")"
frozen="$(hash_file "${P}/.vibe-init/pending/AGENTS.md")"
rm "${P}/AGENTS.md.template"
sync_run "${P}" plan AGENTS.md
is 'deleting hand-out does not acknowledge' "${SYNC_N_REVIEW}" 1
sed 's/upstream two/upstream three/' "${TEMPLATE_DIR}/AGENTS.md" > "${WORK}/edited"
mv "${WORK}/edited" "${TEMPLATE_DIR}/AGENTS.md"
sync_run "${P}" apply AGENTS.md
is 'new release cannot replace an open review' "$(hash_file "${P}/AGENTS.md.template")" "${frozen}"
is 'open review identity stays fixed' "$(upgrade_ticket "${P}" AGENTS.md)" "${ticket}"
no 'stale file fingerprint rejected' upgrade_resolve "${P}" "${ticket}" stale keep
is 'rejected acknowledgement leaves pending' "$(upgrade_pending_count "${P}")" 1
DRY_RUN=1
upgrade_resolve "${P}" "${ticket}" "${expected}" keep
is 'preview acknowledgement does not resolve' "$(upgrade_pending_count "${P}")" 1
DRY_RUN=0
upgrade_resolve "${P}" "${ticket}" "${expected}" keep
is 'explicit keep resolves frozen proposal' "$(upgrade_pending_count "${P}")" 0
is 'keep never changes project text' "$(hash_file "${P}/AGENTS.md")" "${expected}"
new_base="$(state_block_hash "${P}" AGENTS.md CORE_RULES '')"
yes 'acknowledged upstream text stored' grep -q 'upstream two' "${P}/.vibe-init/base/${new_base}"
sync_run "${P}" plan AGENTS.md
is 'later upstream release still needs review' "${SYNC_N_REVIEW}" 1
sync_run "${P}" apply AGENTS.md
upgrade_resolve "${P}" "$(upgrade_ticket "${P}" AGENTS.md)" "${expected}" keep
sync_run "${P}" apply AGENTS.md
is 'repeated sync after keep is quiet' "${SYNC_N_REVIEW}" 0

# Explicit local ownership and pause must prevent writes and baseline movement.
upgrade_set_policy "${P}" AGENTS.md:CORE_RULES local
sed 's/upstream three/upstream four/' "${TEMPLATE_DIR}/AGENTS.md" > "${WORK}/edited"
mv "${WORK}/edited" "${TEMPLATE_DIR}/AGENTS.md"
sync_run "${P}" apply AGENTS.md
is 'self-managed block not offered' "${SYNC_N_REVIEW}" 0
is 'self-managed block not overwritten' "$(hash_file "${P}/AGENTS.md")" "${expected}"
upgrade_set_policy "${P}" AGENTS.md:CORE_RULES follow
sync_run "${P}" plan AGENTS.md
is 'following again compares original base' "${SYNC_N_REVIEW}" 1
upgrade_set_policy "${P}" updates paused
before_manifest="$(hash_file "${P}/.vibe-init/manifest")"
apply_templates "${P}"
is 'paused apply leaves manifest alone' "$(hash_file "${P}/.vibe-init/manifest")" "${before_manifest}"
is 'paused apply leaves project alone' "$(hash_file "${P}/AGENTS.md")" "${expected}"
upgrade_set_policy "${P}" updates active
sync_run "${P}" plan AGENTS.md
is 'resume restores pending comparison' "${SYNC_N_REVIEW}" 1

# Self-managed blocks cannot be replaced by whole-file fast-forward.
Q="${WORK}/clean"; mkdir -p "${Q}"
base_template
sync_run "${Q}" apply "${TEMPLATE_FILES[@]}"
upgrade_set_policy "${Q}" AGENTS.md:CORE_RULES local
sed 's/upstream one/upstream next/;s/product placeholder/new placeholder/' "${TEMPLATE_DIR}/AGENTS.md" > "${WORK}/edited"
mv "${WORK}/edited" "${TEMPLATE_DIR}/AGENTS.md"
sync_run "${Q}" apply AGENTS.md
yes 'ownership wins over whole-file forward' grep -q 'upstream one' "${Q}/AGENTS.md"
yes 'product remains seed-only' grep -q 'product placeholder' "${Q}/AGENTS.md"

# Upstream removal is safe only when project has not changed that block.
remove_block "${TEMPLATE_DIR}/AGENTS.md" EXTRA ''
sync_run "${Q}" apply AGENTS.md
no 'unchanged retired upstream block removed' has_block "${Q}/AGENTS.md" EXTRA
is 'upstream removal records tombstone' "$(state_block_hash "${Q}" AGENTS.md EXTRA '')" absent
base_template
R="${WORK}/retired"; mkdir -p "${R}"
sync_run "${R}" apply "${TEMPLATE_FILES[@]}"
sed 's/retirable/custom retirement/' "${R}/AGENTS.md" > "${WORK}/edited"
mv "${WORK}/edited" "${R}/AGENTS.md"
remove_block "${TEMPLATE_DIR}/AGENTS.md" EXTRA ''
sync_run "${R}" apply AGENTS.md
is 'edited retired block needs review' "${SYNC_N_REVIEW}" 1
upgrade_resolve "${R}" "$(upgrade_ticket "${R}" AGENTS.md)" "$(hash_file "${R}/AGENTS.md")" keep
sync_run "${R}" plan AGENTS.md
is 'keeping retired block does not repeat review' "${SYNC_N_REVIEW}" 0
yes 'kept retired text survives' grep -q 'custom retirement' "${R}/AGENTS.md"

# User deletion is not an invitation to recreate a file.
rm "${R}/CLAUDE.md"
sync_run "${R}" apply CLAUDE.md
no 'local file deletion stays deleted' test -e "${R}/CLAUDE.md"
printf '<CLAUDE_BASE>\nchanged\n</CLAUDE_BASE>\n' > "${TEMPLATE_DIR}/CLAUDE.md"
sync_run "${R}" apply CLAUDE.md
no 'upstream change does not restore deleted file silently' test -e "${R}/CLAUDE.md"
yes 'deleted file gets a review' test -f "${R}/CLAUDE.md.template"
upgrade_resolve "${R}" "$(upgrade_ticket "${R}" CLAUDE.md)" absent keep
sync_run "${R}" plan CLAUDE.md
is 'acknowledged deletion stays quiet' "${SYNC_N_REVIEW}" 0

# Legacy conversion never silently accepts changed upstream content.
L="${WORK}/legacy"; mkdir -p "${L}"
printf 'legacy project rules\n' > "${L}/AGENTS.md"
sync_run "${L}" apply AGENTS.md
is 'legacy file is a conversion review' "$(upgrade_meta "${L}/.vibe-init/pending/AGENTS.md" kind)" convert
cp "${TEMPLATE_DIR}/AGENTS.md" "${L}/AGENTS.md"
sed 's/upstream one/legacy project rules/' "${L}/AGENTS.md" > "${WORK}/edited"
mv "${WORK}/edited" "${L}/AGENTS.md"
no 'conversion cannot be mistaken for content merge' upgrade_resolve "${L}" "$(upgrade_ticket "${L}" AGENTS.md)" "$(hash_file "${L}/AGENTS.md")" merged
upgrade_resolve "${L}" "$(upgrade_ticket "${L}" AGENTS.md)" "$(hash_file "${L}/AGENTS.md")" converted
sync_run "${L}" plan AGENTS.md
is 'content remains for review after conversion' "${SYNC_N_REVIEW}" 1

# Reject malformed structures and stale/corrupted reviews.
sync_run "${L}" apply AGENTS.md
ticket="$(upgrade_ticket "${L}" AGENTS.md)"
printf '\n<CORE_RULES>\nduplicate\n</CORE_RULES>\n' >> "${L}/AGENTS.md"
no 'duplicate block is not a completed merge' upgrade_resolve "${L}" "${ticket}" "$(hash_file "${L}/AGENTS.md")" merged
printf '\n<<<<<<< ours\n' >> "${L}/AGENTS.md"
no 'keep rejects leftover merge markers' upgrade_resolve "${L}" "${ticket}" "$(hash_file "${L}/AGENTS.md")" keep
printf '\ntampered\n' >> "${L}/.vibe-init/pending/AGENTS.md"
no 'tampered frozen upstream cannot be acknowledged' upgrade_resolve "${L}" "${ticket}" "$(hash_file "${L}/AGENTS.md")" keep

# Schema migration and tracking survive clone; private artifacts stay ignored.
G="${WORK}/git"; mkdir -p "${G}"
git -C "${G}" init -q
printf 'node_modules/\n.vibe-init/\n' > "${G}/.gitignore"
base_template
sync_run "${G}" apply "${TEMPLATE_FILES[@]}"
no 'manifest is trackable' git -C "${G}" check-ignore -q .vibe-init/manifest
no 'base objects are trackable' git -C "${G}" check-ignore -q ".vibe-init/base/$(state_file_hash "${G}" AGENTS.md)"
yes 'local pending remains ignored' git -C "${G}" check-ignore -q .vibe-init/pending/a
# Clone only the durable state, as git would do after the user commits it.
C="${WORK}/clone"; mkdir -p "${C}/.vibe-init"
cp "${G}/AGENTS.md" "${G}/CLAUDE.md" "${C}/"
cp "${G}/.vibe-init/manifest" "${C}/.vibe-init/"
cp -R "${G}/.vibe-init/base" "${C}/.vibe-init/"
sync_run "${C}" plan "${TEMPLATE_FILES[@]}"
is 'durable state works after clone' "${SYNC_N_REVIEW}" 0
printf 'schema\t99\n' > "${C}/.vibe-init/manifest"
no 'future schema rejected' state_check_schema "${C}"
ln -s "${WORK}/outside" "${C}/AGENTS.md.template"
no 'linked managed hand-out rejected' upgrade_safe_paths "${C}"
no 'traversal is not an ownership scope' upgrade_validate_scope "${P}" '../secret'

# Recovery protects edits made after an upgrade.
base_template
B="${WORK}/backup"; mkdir -p "${B}"
sync_run "${B}" apply "${TEMPLATE_FILES[@]}"
original="$(hash_file "${B}/AGENTS.md")"
sed 's/upstream one/recoverable upgrade/' "${TEMPLATE_DIR}/AGENTS.md" > "${WORK}/edited"
mv "${WORK}/edited" "${TEMPLATE_DIR}/AGENTS.md"
upgrade_begin "${B}"; backup_id="${UPGRADE_BACKUP##*/}"
sync_run "${B}" apply AGENTS.md
upgrade_finish "${B}"
yes 'upgrade changed target before rollback' grep -q 'recoverable upgrade' "${B}/AGENTS.md"
upgrade_rollback "${B}" "${backup_id}"
is 'rollback restores exact target bytes' "$(hash_file "${B}/AGENTS.md")" "${original}"
upgrade_begin "${B}"; backup_id="${UPGRADE_BACKUP##*/}"
sync_run "${B}" apply AGENTS.md
upgrade_finish "${B}"
printf '\nnew user edit\n' >> "${B}/AGENTS.md"
no 'rollback refuses to erase subsequent edits' upgrade_rollback "${B}" "${backup_id}"
yes 'subsequent edit survives refused rollback' grep -q 'new user edit' "${B}/AGENTS.md"

# CLI validates flags before touching project files.
CLI="${WORK}/cli"; mkdir -p "${CLI}"
(cd "${CLI}" && "${ROOT}/vibe-init.sh" --apply --pause-updates > "${WORK}/cli.log" 2>&1)
is 'CLI persists pause' "$(upgrade_policy "${CLI}" updates)" paused
(cd "${CLI}" && "${ROOT}/vibe-init.sh" --apply -y >> "${WORK}/cli.log" 2>&1)
no 'CLI paused sync does not scaffold files' test -e "${CLI}/AGENTS.md"
(cd "${CLI}" && "${ROOT}/vibe-init.sh" --apply --resume-updates >> "${WORK}/cli.log" 2>&1)
is 'CLI persists resume' "$(upgrade_policy "${CLI}" updates)" active
if (cd "${CLI}" && "${ROOT}/vibe-init.sh" --apply --resolve nope >/dev/null 2>&1); then ko 'CLI requires reviewed fingerprint'; else ok 'CLI requires reviewed fingerprint'; fi
if (cd "${CLI}" && "${ROOT}/vibe-init.sh" --pause-updates >/dev/null 2>&1); then ko 'CLI requires apply for policy actions'; else ok 'CLI requires apply for policy actions'; fi
no 'CLI releases its lock' test -d "${CLI}/.vibe-init/lock"
# Schema-1 hashes migrate without inventing missing upstream text.
M="${WORK}/schema-one"; mkdir -p "${M}/.vibe-init"
printf 'schema\t1\nversion\t0.9.0\nfile\tAGENTS.md\told-hash\nblock\tAGENTS.md\tCORE_RULES\t\told-block\n' > "${M}/.vibe-init/manifest"
STATE_RECORDS=()
state_flush "${M}"
is 'schema-one migration keeps old hash' "$(state_file_hash "${M}" AGENTS.md)" old-hash
is 'schema-one migration keeps block hash' "$(state_block_hash "${M}" AGENTS.md CORE_RULES '')" old-block
no 'migration never invents upstream contents' test -f "${M}/.vibe-init/base/old-hash"
# Legacy pending hand-outs no longer use deletion as an acknowledgement.
mkdir -p "${M}/.vibe-init/pending"
cp "${TEMPLATE_DIR}/AGENTS.md" "${M}/.vibe-init/pending/AGENTS.md"
cp "${TEMPLATE_DIR}/AGENTS.md" "${M}/AGENTS.md"
sync_run "${M}" plan AGENTS.md
is 'schema-one unresolved hand-out remains pending without .template' "${SYNC_N_REVIEW}" 1
sync_run "${M}" apply AGENTS.md
yes 'old hand-out receives explicit metadata' test -f "${M}/.vibe-init/pending/AGENTS.md.meta"

# Exiting the CLI leaves no writes for a read-only pending inspection or preview.
before="$(upgrade_fingerprint "${CLI}")"
(cd "${CLI}" && "${ROOT}/vibe-init.sh" --apply --pending >> "${WORK}/cli.log" 2>&1)
is 'pending inspection is read-only' "$(upgrade_fingerprint "${CLI}")" "${before}"
(cd "${CLI}" && "${ROOT}/vibe-init.sh" --apply --self-manage AGENTS.md:CORE_RULES --dry-run >> "${WORK}/cli.log" 2>&1)
is 'ownership preview is read-only' "$(upgrade_fingerprint "${CLI}")" "${before}"
(cd "${CLI}" && "${ROOT}/vibe-init.sh" --apply --self-manage AGENTS.md:CORE_RULES >> "${WORK}/cli.log" 2>&1)
is 'CLI writes block ownership' "$(upgrade_policy "${CLI}" AGENTS.md:CORE_RULES)" local
(cd "${CLI}" && "${ROOT}/vibe-init.sh" --apply --follow AGENTS.md:CORE_RULES >> "${WORK}/cli.log" 2>&1)
is 'CLI restores following' "$(upgrade_policy "${CLI}" AGENTS.md:CORE_RULES)" follow
upgrade_lock "${CLI}"
if (cd "${CLI}" && "${ROOT}/vibe-init.sh" --apply -y >/dev/null 2>&1); then ko 'CLI rejects a concurrent upgrade'; else ok 'CLI rejects a concurrent upgrade'; fi
yes 'rejected process does not remove another process lock' test -d "${CLI}/.vibe-init/lock"
upgrade_unlock

# A missing optional integration can mean a different template variant.
base_template
O="${WORK}/optional"; mkdir -p "${O}"
printf '\n<INTEGRATION id="example">\nkeep me\n</INTEGRATION>\n' >> "${TEMPLATE_DIR}/AGENTS.md"
sync_run "${O}" apply AGENTS.md
remove_block "${TEMPLATE_DIR}/AGENTS.md" INTEGRATION example
sync_run "${O}" apply AGENTS.md
yes 'variant change does not uninstall an integration' has_block "${O}/AGENTS.md" INTEGRATION example

# No-op sync has stable durable state, even when timestamps would differ.
base_template
N="${WORK}/noop"; mkdir -p "${N}"
sync_run "${N}" apply "${TEMPLATE_FILES[@]}"
awk -F'\t' '$1 == "updated" { print "updated\t2000-01-01T00:00:00Z"; next } { print }' "${N}/.vibe-init/manifest" > "${WORK}/edited"
mv "${WORK}/edited" "${N}/.vibe-init/manifest"
before="$(hash_file "${N}/.vibe-init/manifest")"
sync_run "${N}" apply "${TEMPLATE_FILES[@]}"
is 'no-op sync does not churn committed manifest' "$(hash_file "${N}/.vibe-init/manifest")" "${before}"

# Modern malformed blocks must never be partially rewritten.
printf '\n<CORE_RULES>\nunterminated\n' >> "${N}/AGENTS.md"
before="$(hash_file "${N}/AGENTS.md")"
sed 's/upstream one/upstream next/' "${TEMPLATE_DIR}/AGENTS.md" > "${WORK}/edited"
mv "${WORK}/edited" "${TEMPLATE_DIR}/AGENTS.md"
sync_run "${N}" apply AGENTS.md
is 'malformed target requires review' "${SYNC_N_REVIEW}" 1
is 'malformed target is not rewritten' "$(hash_file "${N}/AGENTS.md")" "${before}"

# Exercise the complete CLI review/acknowledgement protocol, not just helpers.
E="${WORK}/cli-review"; mkdir -p "${E}"
printf '<CORE_RULES>\nproject rule\n</CORE_RULES>\n' > "${E}/AGENTS.md"
# A fake diagnostic CLI verifies the project lock is still held after template
# materialization. No installer or real Trellis command is run.
mkdir -p "${WORK}/probe-bin"
cat > "${WORK}/probe-bin/trellis" <<'EOF'
#!/usr/bin/env bash
[[ -d "${PWD}/.vibe-init/lock" ]] || : > "${VIBE_LOCK_PROBE}"
printf 'trellis 0.0.0-test\n'
EOF
chmod +x "${WORK}/probe-bin/trellis"
(cd "${E}" && VIBE_LOCK_PROBE="${WORK}/lost-lock" PATH="${WORK}/probe-bin:${PATH}" "${ROOT}/vibe-init.sh" --apply --files AGENTS.md -y > "${WORK}/cli-review.log" 2>&1)
no 'CLI keeps lock after materializing templates' test -f "${WORK}/lost-lock"
yes 'CLI creates a frozen review' test -f "${E}/.vibe-init/pending/AGENTS.md.meta"
ticket="$(upgrade_ticket "${E}" AGENTS.md)"
expected="$(hash_file "${E}/AGENTS.md")"
if (cd "${E}" && "${ROOT}/vibe-init.sh" --apply --resolve "${ticket}" --expect stale --resolution keep >> "${WORK}/cli-review.log" 2>&1); then ko 'CLI rejects stale acknowledgement'; else ok 'CLI rejects stale acknowledgement'; fi
(cd "${E}" && "${ROOT}/vibe-init.sh" --apply --resolve "${ticket}" --expect "${expected}" --resolution keep >> "${WORK}/cli-review.log" 2>&1)
no 'CLI explicit keep closes review' test -f "${E}/.vibe-init/pending/AGENTS.md"
is 'CLI keep preserves project bytes' "$(hash_file "${E}/AGENTS.md")" "${expected}"
(cd "${E}" && "${ROOT}/vibe-init.sh" --apply --files AGENTS.md -y >> "${WORK}/cli-review.log" 2>&1)
no 'CLI repeated sync does not reopen accepted review' test -f "${E}/.vibe-init/pending/AGENTS.md"
before="$(upgrade_fingerprint "${E}")"
(cd "${E}" && "${ROOT}/vibe-init.sh" --apply --files AGENTS.md --dry-run -y >> "${WORK}/cli-review.log" 2>&1)
is 'CLI sync preview preserves files and state' "$(upgrade_fingerprint "${E}")" "${before}"

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
