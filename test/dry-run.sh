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

# The suites assert on the English text; a user who starts vibe-init in
# Chinese must not turn every assertion red.
unset VIBE_INIT_LANG

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

# A writable copy of templates/, so a scenario can simulate a template upgrade
# and watch what a sync does about it.
template_copy() {
  local d
  d="$(sandbox)"
  cp -R "${REPO_ROOT}/templates" "${d}/templates"
  printf '%s\n' "${d}/templates"
}

# Insert a line just above a closing tag, in place. awk rather than sed -i,
# whose flags differ between BSD and GNU.
inject_above() {
  local file="$1" closing="$2" line="$3"
  awk -v closing="${closing}" -v line="${line}" '
    $0 == closing { print line }
    { print }
  ' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
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
# Like has, but the pattern is an extended regex — used where the point of the
# assertion is that two things landed on the *same* line.
hasre() { if printf '%s' "${OUT}" | grep -qE -- "$2"; then ok "$1"; else ko "$1" "expected to match: $2"; fi; }
rc_is() { if [[ "${RC}" == "$2" ]]; then ok "$1"; else ko "$1" "exit ${RC}, expected $2"; fi; }
is()    { if [[ "$2" == "$3" ]]; then ok "$1"; else ko "$1" "got [$2], want [$3]"; fi; }

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
hasnt "scaffold skips the test checklist by default" "-> ${d}/Test/templates-test-checklist.html"
has   "--git no skips git init"                "skip git init (per --git no)"

# --- scaffold with --test-checklist yes ---
d="$(sandbox)"
vi "${d}" --trellis no --git no --test-checklist yes --dry-run
has "--test-checklist yes copies the page"  "-> ${d}/Test/templates-test-checklist.html"
has "and says so in the set label"          "test-checklist=on"

# --- scaffold with invalid --test-checklist dies ---
vi "$(sandbox)" --trellis no --git no --test-checklist bogus --dry-run
rc_is "--test-checklist bogus dies" 1
has   "--test-checklist bogus error message" "--test-checklist must be yes or no"

# --- scaffold with --cc-workflow yes ---
d="$(sandbox)"
vi "${d}" --trellis no --git no --cc-workflow yes --dry-run
has "scaffold with --cc-workflow yes copies file" "-> ${d}/CC-Cowork-Workflow.md"
has "and the subagent the file delegates through" "-> ${d}/.claude/agents/codex-run.md"

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
has "--profile service assembles that profile" "AGENTS.md assembled with the 'service' profile"
has "--profile service labels the set"         "template set: profile=service"

d="$(sandbox)"
vi "${d}" --trellis no --git no -y --dry-run
has "default profile keeps all blocks" "keeps every profile block"

# The set label reports the whole variant: profile x integrations x features.
d="$(sandbox)"
vi "${d}" --trellis yes -y --dry-run --developer-name Dev
has "trellis run labels the integration" "integrations=trellis"

d="$(sandbox)"
vi "${d}" --trellis no --git no --cc-workflow yes --dry-run
has "cc-workflow on shows in the set label" "cc-workflow=on"

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
# --- apply: legacy target gets the format-conversion prompt -----------------
# A pre-block AGENTS.md (plain Markdown, no <TAG> markers) still becomes a
# .template pair, but the end-of-run prompt must ask for a format conversion,
# not the ordinary content merge — and name the tags of the new layout.
d="$(sandbox)"
printf '# AI Agent Instructions\n\n## Product\n\nmy product text\n\n### Project Profile\n\n<!-- PROFILE:service START -->\nservice rules\n<!-- PROFILE:service END -->\n' > "${d}/AGENTS.md"
vi "${d}" --apply -y --dry-run --files AGENTS.md
has   "legacy target writes .template"          "-> ${d}/AGENTS.md.template"
has   "diagnostics flag the legacy format"      "Legacy (pre-<TAG> format)"
has   "diagnostics suggest the upgrade path"    "Format upgrade"
has   "conversion prompt announces itself"      "old pre-<TAG> format"
has   "conversion prompt asks to restructure"   "Restructure my files into the new <TAG> block format"
has   "conversion prompt names the tag vocabulary" "new-format tags in that .template: <CORE_RULES>"
has   "conversion prompt names the target tags" "<METADATA>"
has   "conversion prompt covers the anchors"    "PROFILE:service START"
has   "conversion prompt keeps my content"      "do not rewrite, shorten"
hasnt "legacy pair absent from merge prompt"    "Bring my files up to date"
has   "conversion names the merge round after it" "once the conversion is explicitly acknowledged"
has   "diagnostics name both rounds"            "then sync again to merge"
has   "nothing to record still writes the manifest" "dry-run: write .vibe-init/manifest"

# --- apply: modern target keeps the ordinary merge prompt -------------------
d="$(sandbox)"
printf '# mine\n\n<CORE_RULES>\nold rules\n</CORE_RULES>\n' > "${d}/AGENTS.md"
vi "${d}" --apply -y --dry-run --files AGENTS.md
has   "modern target writes .template"        "-> ${d}/AGENTS.md.template"
has   "diagnostics see the modern format"     "Modern (<TAG> format)"
hasnt "modern target gets no upgrade hint"    "Format upgrade"
has   "modern target gets the merge prompt"   "Bring my files up to date"
hasnt "modern target gets no conversion prompt" "Restructure my files into the new"
has   "merge prompt names its completion signal" "--resolve ID --expect HASH"
hasnt "a modern run names no second round"     "once the conversion is done"

# --- apply: mixed pair splits the two prompts -------------------------------
d="$(sandbox)"
printf '# legacy agents\n' > "${d}/AGENTS.md"
printf '<CLAUDE_BASE>\nmy claude file\n</CLAUDE_BASE>\n' > "${d}/CLAUDE.md"
vi "${d}" --apply -y --dry-run
prompts="$(printf '%s' "${OUT}" | grep -cF 'suggested prompt for your AI agent' || true)"
is    "mixed run prints both prompt blocks"     "${prompts}" "2"
has   "mixed run still merges the modern file"  "CLAUDE.md.template  ->  CLAUDE.md"
has   "mixed run converts the legacy file"      "AGENTS.md.template  ->  AGENTS.md"


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

# A dry run only prints the copy; this is the one place that proves the agent
# file reaches disk, under the name the workflow document tells Claude to call.
if [[ -f "${d}/.claude/agents/codex-run.md" ]]; then
  ok "scaffold --cc-workflow yes creates the delegation subagent"
else
  ko "scaffold --cc-workflow yes creates the delegation subagent" ".claude/agents/codex-run.md was not created"
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



# --- apply: the CC-Workflow document follows the project ------------------
# A project that does not use the workflow must not be handed the file, and one
# that does must keep getting it updated.
d="$(sandbox)"
vi "${d}" --apply -y --dry-run
hasnt "apply does not push CC-Workflow onto a project without it" "-> ${d}/CC-Cowork-Workflow.md"
has   "apply says the file is not in this set"                    "not in this set"

d="$(sandbox)"
printf 'workflow\n' > "${d}/CC-Cowork-Workflow.md"
vi "${d}" --apply -y --dry-run
has "apply keeps syncing CC-Workflow where it is used" "-> ${d}/CC-Cowork-Workflow.md.template"

d="$(sandbox)"
vi "${d}" --apply -y --dry-run --cc-workflow yes
has "apply --cc-workflow yes offers the file" "-> ${d}/CC-Cowork-Workflow.md"

d="$(sandbox)"
printf 'workflow\n' > "${d}/CC-Cowork-Workflow.md"
vi "${d}" --apply -y --dry-run --cc-workflow no
hasnt "apply --cc-workflow no leaves it out of the sync" "-> ${d}/CC-Cowork-Workflow.md.template"

# --- apply diagnostics ----------------------------------------------------
# A repository with no commits is the normal state right after vibe-init runs
# git init, and it used to render as two lines with a dangling border.
d="$(sandbox)"
(cd "${d}" && git init -q . 2>/dev/null)
vi "${d}" --apply -y --dry-run
hasre "an unborn branch renders on one line" "Git repo +.*Initialized \\(main\\)"
hasnt "an unborn branch does not leak the HEAD fallback" "Initialized (HEAD"

# --- no color, no crash ---------------------------------------------------
# Every message level has to render with color off; a glyph defined on only one
# branch used to abort the run under set -u the first time anything warned.
d="$(sandbox)"
OUT="$(cd "${d}" && NO_COLOR=1 "${VI}" --apply -y --dry-run --files "CC-Cowork-Workflow.md" </dev/null 2>&1)"
RC=$?
rc_is "a warning path survives NO_COLOR"  0
has   "the warning is still reported"     "not part of this template set"

d="$(sandbox)"
OUT="$(cd "${d}" && NO_COLOR=1 "${VI}" --trellis no --git no -y --dry-run </dev/null 2>&1)"
RC=$?
rc_is "a scaffold survives NO_COLOR"      0
has   "NO_COLOR keeps the plain prefix"   "[vibe-init]"

# --- the .vibe-init state directory ----------------------------------------
# A scaffold records what it wrote, which is what every later sync compares
# against. Without it apply mode can only ask "does this file exist?".
d="$(sandbox)"
vi "${d}" --trellis no --git no -y
if [[ -f "${d}/.vibe-init/manifest" ]]; then
  ok "a scaffold records its state"
else
  ko "a scaffold records its state" ".vibe-init/manifest was not written"
fi
if grep -qxF "$(printf 'version\t1.3.0')" "${d}/.vibe-init/manifest"; then
  ok "the manifest stamps the tool version"
else
  ko "the manifest stamps the tool version" "$(cat "${d}/.vibe-init/manifest" 2>/dev/null | head -5)"
fi
if grep -q "$(printf 'block\tAGENTS.md\tCORE_RULES')" "${d}/.vibe-init/manifest"; then
  ok "the manifest records blocks, not just files"
else
  ko "the manifest records blocks, not just files" "no block record for CORE_RULES"
fi

# Private upgrade artifacts are ignored; the manifest remains trackable.
d="$(sandbox)"
vi "${d}" --trellis no -y
if [[ -f "${d}/.gitignore" ]] && grep -qxF '/.vibe-init/pending/' "${d}/.gitignore"; then
  ok "git init is followed by a .gitignore entry"
else
  ko "git init is followed by a .gitignore entry" "$(cat "${d}/.gitignore" 2>/dev/null)"
fi

d="$(sandbox)"
vi "${d}" --trellis no --git no -y
if [[ -e "${d}/.gitignore" ]]; then
  ko "--git no writes no .gitignore" "created one in a non-repository"
else
  ok "--git no writes no .gitignore"
fi

# --- sync: a project that already matches is left completely alone ----------
# This is the regression that made .template pairs meaningless: a project
# scaffolded seconds earlier used to get one beside every managed file, each
# byte-identical to the file it sat next to, plus a prompt asking an agent to
# merge a file with itself.
d="$(sandbox)"
vi "${d}" --trellis no --git no -y
vi "${d}" --apply -y
has   "an unchanged project has nothing to sync"   "Everything is up to date"
hasnt "an unchanged project writes no .template"   ".template"
hasnt "an unchanged project needs no agent prompt" "suggested prompt for your AI agent"
has   "the file list says up to date"              "up to date"
if [[ -z "$(find "${d}" -name '*.template' -print -quit)" ]]; then
  ok "an unchanged project leaves no .template on disk"
else
  ko "an unchanged project leaves no .template on disk" "$(find "${d}" -name '*.template')"
fi
has "diagnostics report the tool and the project version" "v1.3.0 (last tool v1.3.0; 0 pending review(s))"
hasre "diagnostics report CLAUDE.md's format"             "CLAUDE.md +.*Modern"

d="$(sandbox)"
vi "${d}" --apply -y --dry-run
has "an unmanaged project says so" "project not tracked yet"

# --- sync: the user's own edits, with the template standing still -----------
d="$(sandbox)"
vi "${d}" --trellis no --git no -y
inject_above "${d}/AGENTS.md" "</PRODUCT>" "This project is a widget factory."
vi "${d}" --apply -y
has   "an edit of my own is not a conflict"  "up to date"
hasnt "an edit of my own needs no prompt"    "suggested prompt for your AI agent"
if grep -qF "This project is a widget factory." "${d}/AGENTS.md"; then
  ok "an edit of my own survives the sync"
else
  ko "an edit of my own survives the sync" "the sync overwrote it"
fi

# --- sync: the template moved and the project did not -----------------------
# The block engine can do this in place, so there is nothing to hand to an
# agent: the block the tool owns is refreshed, everything else stays put.
d="$(sandbox)"
t="$(template_copy)"
vi "${d}" --trellis no --git no -y --template-dir "${t}"
inject_above "${d}/AGENTS.md" "</PRODUCT>" "This project is a widget factory."
inject_above "${t}/blocks/core_rules.md" "</CORE_RULES>" "- **UPGRADE MARKER**: added by a later template."
vi "${d}" --apply -y --template-dir "${t}"
has   "a template-only change refreshes the block in place" "refreshed <CORE_RULES> in AGENTS.md"
hasnt "a fast-forward writes no .template"                  ".template"
hasnt "a fast-forward needs no agent prompt"                "suggested prompt for your AI agent"
if grep -qF "UPGRADE MARKER" "${d}/AGENTS.md"; then
  ok "the new template content actually lands in the file"
else
  ko "the new template content actually lands in the file" "marker missing from AGENTS.md"
fi
if grep -qF "This project is a widget factory." "${d}/AGENTS.md"; then
  ok "a fast-forward does not disturb my own blocks"
else
  ko "a fast-forward does not disturb my own blocks" "PRODUCT edit was lost"
fi

# --- sync: both sides moved the same block ----------------------------------
# Now, and only now, is there something a human has to decide — so this is the
# one case that still produces a .template pair and a prompt.
inject_above "${d}/AGENTS.md" "</CORE_RULES>" "- **MY OWN RULE**: never delete archive branches."
inject_above "${t}/blocks/core_rules.md" "</CORE_RULES>" "- **SECOND MARKER**: from a still later template."
vi "${d}" --apply -y --template-dir "${t}"
has "a real conflict writes the .template pair"  "AGENTS.md.template"
has "a real conflict prints the merge prompt"    "suggested prompt for your AI agent"
has "the prompt narrows the agent to the block"  "only these blocks are still open: <CORE_RULES>"
has "the report names the block, not the file"   "needs review (<CORE_RULES>)"
if grep -qF "MY OWN RULE" "${d}/AGENTS.md"; then
  ok "a conflicted block is left for me, not overwritten"
else
  ko "a conflicted block is left for me, not overwritten" "my rule was overwritten"
fi

# --- a leftover .template must not swallow the pair -------------------------
# <name>.template is this tool's own scratch copy, so finding one means the last
# merge never finished. Skipping it used to drop the pair from the end-of-run
# hint entirely: the run said "needs format conversion" and then printed no
# prompt at all, every time, with no way for the user to make progress.
d="$(sandbox)"
printf '# my legacy agents file\n' > "${d}/AGENTS.md"
printf 'stale leftover\n'         > "${d}/AGENTS.md.template"
vi "${d}" --apply -y --files AGENTS.md
has "a leftover .template is refreshed, not skipped" "left over from an unfinished merge"
has "a leftover .template still prints the prompt"   "suggested prompt for your AI agent"
has "a leftover .template still lists the pair"      "AGENTS.md.template  ->  AGENTS.md"
if grep -qF '<CORE_RULES>' "${d}/AGENTS.md.template"; then
  ok "the stale .template is replaced by the current one"
else
  ko "the stale .template is replaced by the current one" "$(cat "${d}/AGENTS.md.template")"
fi

# --- --on-exists still asks for the old file-level disposition --------------
d="$(sandbox)"
printf 'existing\n' > "${d}/AGENTS.md"
vi "${d}" --apply -y --dry-run --on-exists template
has "--on-exists keeps the file-level labels" "already exists -> template"

# --- a project vibe-init never touched, through to a settled sync ------------
# The whole first-contact loop, for real rather than --dry-run: the first apply
# creates what is missing and hands out .template pairs for what the user
# already wrote, the user's agent converts and merges, and from then on every
# apply has nothing to do.
d="$(sandbox)"
vi "${d}" --apply -y
rc_is "an empty untracked project applies cleanly" 0
vi "${d}" --apply -y
has   "and a second apply has nothing to sync" "Everything is up to date"

d="$(sandbox)"
printf '# My rules\n\nUse tabs.\n' > "${d}/CLAUDE.md"
mkdir -p "${d}/.claude"
printf '{"permissions":{"allow":["Bash(ls)"]}}\n' > "${d}/.claude/settings.json"
cp "${d}/CLAUDE.md" "${d}/claude.orig"
cp "${d}/.claude/settings.json" "${d}/settings.orig"
vi "${d}" --apply -y
rc_is "a project with files of its own applies cleanly" 0
has   "its legacy CLAUDE.md is handed out for conversion" "CLAUDE.md.template  ->  CLAUDE.md"
has   "its own settings.json is handed out for merging"  ".claude/settings.json.template  ->  .claude/settings.json"
if diff -q "${d}/CLAUDE.md" "${d}/claude.orig" >/dev/null \
  && diff -q "${d}/.claude/settings.json" "${d}/settings.orig" >/dev/null; then
  ok "the user's own files are not touched"
else
  ko "the user's own files are not touched" "CLAUDE.md or settings.json changed"
fi

# Stand in for the agent: wrap the template's block around the user's text,
# take the template's settings, then acknowledge each review with the exact
# command --pending prints — deleting a .template is not a completion signal.
{ sed -n '/^<CLAUDE_BASE>$/,/^<\/CLAUDE_BASE>$/p' "${d}/CLAUDE.md.template"
  printf '\n'; cat "${d}/claude.orig"; } > "${d}/CLAUDE.md"
mv "${d}/.claude/settings.json.template" "${d}/.claude/settings.json"
rm "${d}/CLAUDE.md.template"
vi "${d}" --apply --pending
RESOLVES="$(printf '%s\n' "${OUT}" | sed -n 's/.*resolve after review: vibe-init //p')"
is "--pending prints one resolve command per review" \
  "$(printf '%s\n' "${RESOLVES}" | grep -c -- '--resolve')" 2
while IFS= read -r cmd; do
  [[ -n "${cmd}" ]] || continue
  IFS=' ' read -r -a argv <<< "${cmd}"
  vi "${d}" "${argv[@]}"
done <<< "${RESOLVES}"
vi "${d}" --apply -y
has   "after the agent's round the project is settled" "Everything is up to date"
hasnt "and nothing is handed out again"                ".template"
vi "${d}" --apply -y
has   "and it stays settled"                           "Everything is up to date"

# --- --layout hub scaffolds a documents-only hub ------------------------------
d="$(sandbox)"
vi "${d}" --layout hub -y
rc_is "--layout hub scaffolds cleanly" 0
if grep -qF '<LAYOUT id="hub">' "${d}/AGENTS.md" && ! grep -qF '<PROFILE' "${d}/AGENTS.md"; then
  ok "a hub AGENTS.md carries the hub rules and no profile"
else
  ko "a hub AGENTS.md carries the hub rules and no profile" "$(grep -oE '^<[A-Z_]+[^>]*>' "${d}/AGENTS.md" | tr '\n' ' ')"
fi
if [[ -f "${d}/docs/README.md" && -f "${d}/docs/tasks/README.md" && -f "${d}/docs/next.md" \
      && -f "${d}/docs/handoff.md" && -f "${d}/docs/wiki/overview.md" ]]; then
  ok "a hub gets the docs skeleton"
else
  ko "a hub gets the docs skeleton" "$(cd "${d}" && find docs -type f 2>/dev/null | tr '\n' ' ')"
fi
[[ -d "${d}/.git" ]] && ok "a hub is a git repository" || ko "a hub is a git repository" "no .git"
if grep -qF "$(printf 'layout\thub')" "${d}/.vibe-init/manifest"; then
  ok "the manifest records the hub layout"
else
  ko "the manifest records the hub layout" "$(grep '^layout' "${d}/.vibe-init/manifest")"
fi
hasnt "a hub is not offered the test checklist" "Test/templates-test-checklist.html"

d="$(sandbox)"
vi "${d}" -y
if grep -qF "$(printf 'layout\tsingle')" "${d}/.vibe-init/manifest" && [[ ! -e "${d}/docs" ]]; then
  ok "the default layout is single, with no docs skeleton"
else
  ko "the default layout is single, with no docs skeleton" "$(grep '^layout' "${d}/.vibe-init/manifest")"
fi

d="$(sandbox)"
vi "${d}" --layout hub --profile tool -y
rc_is "--layout hub refuses a profile" 1
vi "${d}" --layout hub --trellis yes -y
rc_is "--layout hub refuses Trellis" 1
vi "${d}" --layout nested -y
rc_is "an unknown layout is refused" 1
has   "and named" "--layout must be single or hub"

# --- --apply --cc-workflow yes wires CLAUDE.md, not just the documents -------
# A missing optional block is normally an opt-out the sync must respect, so it
# never inserts one on its own. An explicit --cc-workflow yes is the opposite of
# an opt-out: without the block, the workflow document and its agent land with
# nothing in CLAUDE.md pointing at them.
d="$(sandbox)"
vi "${d}" --apply -y
vi "${d}" --apply -y --cc-workflow yes
rc_is "--apply --cc-workflow yes on a tracked project succeeds" 0
if grep -qF '<FEATURE id="cc-workflow">' "${d}/CLAUDE.md"; then
  ok "--apply --cc-workflow yes adds the CC-Workflow block to CLAUDE.md"
else
  ko "--apply --cc-workflow yes adds the CC-Workflow block to CLAUDE.md" "no FEATURE block in CLAUDE.md"
fi
vi "${d}" --apply -y
has   "and the block it added counts as the tool's own" "Everything is up to date"
hasnt "and is not handed out for review"                ".template"

# --- VIBE_INIT_LANG=zh starts the interface in Chinese ----------------------
# The interface is translated; the agent prompts are not — they are written for
# a model, and already ask it to talk to the user in Chinese.
d="$(sandbox)"
printf '# My rules\n' > "${d}/CLAUDE.md"
OUT="$(cd "${d}" && VIBE_INIT_LANG=zh "${VI}" --apply -y </dev/null 2>&1)"
has   "VIBE_INIT_LANG=zh renders the card in Chinese"  "项目环境"
has   "and the sync result"                            "同步结果"
has   "the agent prompt stays English"                 "Restructure my files into the new <TAG> block format."
hasnt "and no English status leaks into the card"      "Project environment"
vi "${d}" --apply -y
has   "without it the run is English"                  "Project environment"

echo
if [[ "${FAIL}" -eq 0 ]]; then
  printf 'PASS — %d assertions, 0 failures\n' "${PASS}"
  exit 0
fi
printf 'FAIL — %d failed, %d passed\n' "${FAIL}" "${PASS}"
exit 1
