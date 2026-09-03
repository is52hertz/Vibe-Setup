#!/usr/bin/env bash
# Minimal dry-run assertion tests for vibe-init.sh.
#
# Everything runs with --dry-run, so no files are written and no installers run;
# the tests only assert on the actions vibe-init *prints*. A fake `trellis` on
# PATH lets the Trellis path execute without the real CLI. Each scenario uses a
# fresh temp sandbox (resolved with pwd -P so paths match vibe-init's output).
#
# Run: ./test/dry-run.sh   (exit 0 = all pass, 1 = some failed)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VI="${REPO_ROOT}/vibe-init.sh"

[[ -f "${VI}" ]] || { echo "vibe-init.sh not found at ${VI}" >&2; exit 2; }

PASS=0
FAIL=0
SANDBOXES=()

# Fake trellis so the --trellis path runs without the real CLI (only --version
# is consulted by vibe-init's install gate).
FAKE_BIN="$(mktemp -d)"
printf '#!/usr/bin/env bash\n[[ "$1" == "--version" ]] && echo "trellis 0.0.0-fake"\nexit 0\n' > "${FAKE_BIN}/trellis"
chmod +x "${FAKE_BIN}/trellis"
PATH="${FAKE_BIN}:${PATH}"

cleanup() { rm -rf "${FAKE_BIN}" "${SANDBOXES[@]+"${SANDBOXES[@]}"}"; }
trap cleanup EXIT

# A fresh empty sandbox, path canonicalized to match vibe-init's `pwd -P` output.
sandbox() {
  local d
  d="$(cd "$(mktemp -d)" && pwd -P)"
  SANDBOXES+=("${d}")
  printf '%s\n' "${d}"
}

OUT=""
RC=0
# vi <dir> [args...] — run vibe-init in <dir>, capturing combined output + status.
vi() {
  local dir="$1"
  shift
  OUT="$(cd "${dir}" && "${VI}" "$@" </dev/null 2>&1)"
  RC=$?
}

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

has()   { if printf '%s' "${OUT}" | grep -qF -- "$2"; then ok "$1"; else ko "$1" "expected to contain: $2"; fi; }
hasnt() { if printf '%s' "${OUT}" | grep -qF -- "$2"; then ko "$1" "expected NOT to contain: $2"; else ok "$1"; fi; }
rc_is() { if [[ "${RC}" == "$2" ]]; then ok "$1"; else ko "$1" "exit ${RC}, expected $2"; fi; }

echo "vibe-init dry-run tests"

# --- help ---
vi "$(sandbox)" --help
rc_is "--help exits 0" 0
has   "--help prints usage" "Usage:"

# --- scaffold (base set, no Trellis) ---
d="$(sandbox)"
vi "${d}" --trellis no --git no --dry-run
has   "scaffold copies AGENTS.md"              "-> ${d}/AGENTS.md"
hasnt "scaffold skips CC-Cowork-Workflow by default" "-> ${d}/CC-Cowork-Workflow.md"
has   "scaffold copies settings.json"          "-> ${d}/.claude/settings.json"
has   "--git no skips git init"                "skip git init (per --git no)"

# --- scaffold with --cc-workflow yes ---
d="$(sandbox)"
vi "${d}" --trellis no --git no --cc-workflow yes --dry-run
has "scaffold with --cc-workflow yes copies file" "-> ${d}/CC-Cowork-Workflow.md"

# --- scaffold with invalid --cc-workflow dies ---
vi "$(sandbox)" --trellis no --git no --cc-workflow bogus --dry-run
rc_is "--cc-workflow bogus dies" 1
has   "--cc-workflow bogus error message" "--cc-workflow must be yes or no"


d="$(sandbox)"
vi "${d}" --trellis no -y --dry-run
has "git init runs by default (-y)" "initializing git repository"

# --- positional PROJECT name (scaffold) ---
d="$(sandbox)"
printf 'existing\n' > "${d}/existing.txt"
vi "${d}" myproj --trellis no --git no -y --dry-run
has   "positional PROJECT creates subfolder" "-> ${d}/myproj/AGENTS.md"
has   "positional PROJECT name adopted"       "-> ${d}/myproj/CLAUDE.md"
hasnt "positional PROJECT does not leak to cwd" "-> ${d}/AGENTS.md"

# Positional name is ignored when the directory is effectively empty (in-place).
d="$(sandbox)"
vi "${d}" foo --trellis no --git no -y --dry-run
has   "positional PROJECT ignored in empty dir" "-> ${d}/AGENTS.md"
hasnt "positional PROJECT no subfolder in empty" "-> ${d}/foo/AGENTS.md"

# Extra positional argument dies.
vi "$(sandbox)" --trellis no --git no --dry-run foo bar
rc_is "extra positional dies" 1
has   "extra positional message" "conflicting project name"

# Positional PROJECT conflicts with --name (either order).
vi "$(sandbox)" foo --name bar --dry-run
rc_is "positional then --name dies" 1
has   "positional then --name message" "conflicting project name"
vi "$(sandbox)" --name bar foo --dry-run
rc_is "--name then positional dies" 1
has   "--name then positional message" "conflicting project name"

# Positional PROJECT is not valid with --apply.
vi "$(sandbox)" foo --apply -y --dry-run
rc_is "positional with --apply dies" 1
has   "positional with --apply message" "not valid with --apply"

# --- profile selection (scaffold) ---
d="$(sandbox)"
vi "${d}" --trellis no --git no --dry-run --profile service
has "--profile service prunes AGENTS.md" "prune ${d}/AGENTS.md to 'service' profile"

d="$(sandbox)"
vi "${d}" --trellis no --git no -y --dry-run
has "default profile keeps all blocks" "leaving all profile blocks"

vi "$(sandbox)" --dry-run --profile bogus
rc_is "--profile bogus dies" 1
has   "--profile bogus message" "--profile must be"

vi "$(sandbox)" --apply -y --dry-run --profile service
rc_is "--profile with --apply dies" 1
has   "--profile with --apply message" "not valid with --apply"

# --- apply: existing file defaults to .template, new files created ---
d="$(sandbox)"
printf 'existing\n' > "${d}/AGENTS.md"
vi "${d}" --apply -y --dry-run
has "apply menu marks existing file" "already exists"
has "apply default writes .template" "-> ${d}/AGENTS.md.template"
has "apply creates a new file"       "-> ${d}/CLAUDE.md"
has "apply hints non-git target"     "is not a git repository"
has "apply prints agent prompt block"  "suggested prompt for your AI agent"
has "apply prompt explains direction"  "NEW template version"
has "apply prompt flags conflicts"     "ask me to"
has "apply prompt sets Chinese for user questions" "Simplified Chinese (中文)"
has "apply prompt lists the pair"      "AGENTS.md.template  ->  AGENTS.md"

# --- apply with no pre-existing files: no merge suggestion ---
d="$(sandbox)"
vi "${d}" --apply -y --dry-run
hasnt "no .template means no merge suggestion" "suggested prompt for your AI agent"

# --- apply --files subset ---
d="$(sandbox)"
vi "${d}" --apply -y --dry-run --files "CLAUDE.md"
has   "apply --files copies the chosen file" "-> ${d}/CLAUDE.md"
hasnt "apply --files skips others"           "-> ${d}/.claude/settings.json"

# --- apply --on-exists policies (existing AGENTS.md) ---
d="$(sandbox)"
printf 'existing\n' > "${d}/AGENTS.md"
vi "${d}" --apply -y --dry-run --files AGENTS.md --on-exists overwrite
has   "--on-exists overwrite targets the file" "-> ${d}/AGENTS.md"
hasnt "--on-exists overwrite writes no .template" ".template"

d="$(sandbox)"
printf 'existing\n' > "${d}/AGENTS.md"
vi "${d}" --apply -y --dry-run --files AGENTS.md --on-exists skip
has "--on-exists skip keeps the file" "exists (kept)"

# --- guards (die with exit 1) ---
vi "$(sandbox)" --apply -y --dry-run --files "nope.md"
rc_is "unknown --files dies" 1
has   "unknown --files message" "unknown template file"

vi "$(sandbox)" --files CLAUDE.md --dry-run
rc_is "--files without --apply dies" 1
has   "--files requires --apply message" "--files requires --apply"

vi "$(sandbox)" --apply -y --dry-run --on-exists bogus
rc_is "--on-exists bogus dies" 1

vi "$(sandbox)" --on-exists overwrite --dry-run
rc_is "--on-exists without --apply dies" 1

# --- Trellis init: developer name + platform flags ---
d="$(sandbox)"
vi "${d}" --trellis yes -y --dry-run --developer-name Dev
has "trellis init uses -u <name>"      "trellis init -y -u Dev"
has "default platform flags passed"    "--claude --codex"

d="$(sandbox)"
OUT="$(cd "${d}" && DEVELOPER_NAME="GlobalDev" "${VI}" --trellis yes -y --dry-run </dev/null 2>&1)"
RC=$?
has "global \$DEVELOPER_NAME hint shown" "using Trellis developer name from \$DEVELOPER_NAME"
has "global \$DEVELOPER_NAME is used"     "-u GlobalDev"

d="$(sandbox)"
vi "${d}" --trellis yes -y --dry-run --developer-name Dev --platforms none
has   "--platforms none note"          "no Trellis platform flags"
hasnt "--platforms none passes no flag" "--claude"

# --- real scaffold generation checks (non-dry-run in sandbox) ---
d="$(sandbox)"
(cd "${d}" && "${VI}" --trellis no --git no -y </dev/null >/dev/null 2>&1)
if [[ -f "${d}/AGENTS.md" ]] && grep -q "<CORE_RULES>" "${d}/AGENTS.md" && grep -q "<PRODUCT>" "${d}/AGENTS.md"; then
  ok "scaffold generates AGENTS.md with <TAG> structure"
else
  ko "scaffold generates AGENTS.md with <TAG> structure" "missing XML tags in AGENTS.md"
fi

if [[ ! -f "${d}/CC-Cowork-Workflow.md" ]]; then
  ok "scaffold default omits CC-Cowork-Workflow.md file"
else
  ko "scaffold default omits CC-Cowork-Workflow.md file" "CC-Cowork-Workflow.md unexpectedly created"
fi

if [[ -f "${d}/CLAUDE.md" ]] && ! grep -q "CC-Cowork-Workflow.md" "${d}/CLAUDE.md"; then
  ok "scaffold default CLAUDE.md excludes CC-workflow reference"
else
  ko "scaffold default CLAUDE.md excludes CC-workflow reference" "CLAUDE.md unexpectedly referenced CC-workflow"
fi

# --- real scaffold with --cc-workflow yes ---
d="$(sandbox)"
(cd "${d}" && "${VI}" --trellis no --git no --cc-workflow yes -y </dev/null >/dev/null 2>&1)
if [[ -f "${d}/CC-Cowork-Workflow.md" ]]; then
  ok "scaffold --cc-workflow yes creates workflow file"
else
  ko "scaffold --cc-workflow yes creates workflow file" "CC-Cowork-Workflow.md was not created"
fi

if [[ -f "${d}/CLAUDE.md" ]] && grep -q "CC-Cowork-Workflow.md" "${d}/CLAUDE.md"; then
  ok "scaffold --cc-workflow yes CLAUDE.md includes reference"
else
  ko "scaffold --cc-workflow yes CLAUDE.md includes reference" "CLAUDE.md missing CC-workflow reference"
fi

# --- real scaffold with --profile service ---
d="$(sandbox)"
(cd "${d}" && "${VI}" --trellis no --git no --profile service -y </dev/null >/dev/null 2>&1)
if [[ -f "${d}/AGENTS.md" ]] && grep -q "<PROFILE id=\"service\">" "${d}/AGENTS.md" && ! grep -q "<PROFILE id=\"tool\">" "${d}/AGENTS.md"; then
  ok "scaffold --profile service keeps only service profile"
else
  ko "scaffold --profile service keeps only service profile" "AGENTS.md profile pruning failed"
fi

# --- apply diagnostics: detect Trellis project and version ---
d="$(sandbox)"
mkdir -p "${d}/.trellis"
printf '0.6.16\n' > "${d}/.trellis/.version"
vi "${d}" --apply -y --dry-run
has "apply detects Trellis project version" "Project v0.6.16"



echo
if [[ "${FAIL}" -eq 0 ]]; then
  printf 'PASS — %d assertions, 0 failures\n' "${PASS}"
  exit 0
fi
printf 'FAIL — %d failed, %d passed\n' "${FAIL}" "${PASS}"
exit 1
