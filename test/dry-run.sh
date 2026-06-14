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
has "scaffold copies AGENTS.md"          "-> ${d}/AGENTS.md"
has "scaffold copies CC-Cowork-Workflow" "-> ${d}/CC-Cowork-Workflow.md"
has "scaffold copies settings.json"      "-> ${d}/.claude/settings.json"
has "--git no skips git init"            "skip git init (per --git no)"

d="$(sandbox)"
vi "${d}" --trellis no -y --dry-run
has "git init runs by default (-y)" "initializing git repository"

# --- apply: existing file defaults to .template, new files created ---
d="$(sandbox)"
printf 'existing\n' > "${d}/AGENTS.md"
vi "${d}" --apply -y --dry-run
has "apply menu marks existing file" "already exists"
has "apply default writes .template" "-> ${d}/AGENTS.md.template"
has "apply creates a new file"       "-> ${d}/CLAUDE.md"
has "apply hints non-git target"     "is not a git repository"

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

echo
if [[ "${FAIL}" -eq 0 ]]; then
  printf 'PASS — %d assertions, 0 failures\n' "${PASS}"
  exit 0
fi
printf 'FAIL — %d failed, %d passed\n' "${FAIL}" "${PASS}"
exit 1
