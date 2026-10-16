#!/usr/bin/env bash
# Unit tests for the libraries under lib/.
#
# test/dry-run.sh drives the CLI and asserts on what it prints. This file goes
# one level down: it sources the libraries directly and exercises the functions
# the CLI is built out of — block assembly and editing, the renderer, and the
# non-interactive contracts of the prompts.
#
# Everything runs in a temp sandbox; nothing here touches the repo.
#
# Run: ./test/units.sh   (exit 0 = all pass, 1 = some failed)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

is()  { if [[ "$2" == "$3" ]]; then ok "$1"; else ko "$1" "got [$2], want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else ko "$1" "expected to contain: $3"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then ko "$1" "expected NOT to contain: $3"; else ok "$1"; fi; }
files_match() { if diff -q "$2" "$3" >/dev/null 2>&1; then ok "$1"; else ko "$1" "$(diff "$2" "$3" | head -5)"; fi; }

WORK="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

# The libraries expect these from the entrypoint.
TEMPLATE_ROOT="${REPO_ROOT}/templates"
DRY_RUN=0
ASSUME_DEFAULTS=0
info() { printf '[test] %s\n' "$*" >&2; }
warn() { printf '[test] warning: %s\n' "$*" >&2; }
die()  { printf '[test] error: %s\n' "$*" >&2; exit 1; }

# shellcheck source=../lib/ui.sh
. "${REPO_ROOT}/lib/ui.sh"
# shellcheck source=../lib/prompt.sh
. "${REPO_ROOT}/lib/prompt.sh"
# shellcheck source=../lib/block_engine.sh
. "${REPO_ROOT}/lib/block_engine.sh"
VIBE_INIT_VERSION="test"
# shellcheck source=../lib/state.sh
. "${REPO_ROOT}/lib/state.sh"
# shellcheck source=../lib/sync.sh
. "${REPO_ROOT}/lib/sync.sh"
APPLY_FILES=""
ON_EXISTS=""
TEMPLATE_DIR="${WORK}/tset"
# lib/apply.sh sources lib/trellis.sh itself, but through ${SCRIPT_DIR}, which
# here is test/ — so without this the dashboard's Trellis checks were missing
# functions, and a test that expected "no Trellis update pending" passed on the
# 127 from "command not found" rather than on the version comparison.
# shellcheck source=../lib/trellis.sh
. "${REPO_ROOT}/lib/trellis.sh"
# lib/apply.sh is nothing but function definitions and a few array inits, so it
# sources cleanly outside a real run — which is what lets the dashboard's menu
# ordering be tested without a terminal.
# shellcheck source=../lib/apply.sh
. "${REPO_ROOT}/lib/apply.sh"

echo "vibe-init unit tests"

# --- block discovery ------------------------------------------------------
profiles="$(list_available_profiles | sort | tr '\n' ' ')"
is "profiles are discovered from the blocks dir" "${profiles}" "service tool "

integrations="$(list_available_integrations | tr '\n' ' ')"
is "integrations are discovered" "${integrations}" "trellis "

# --- AGENTS.md assembly ---------------------------------------------------
assemble_agents_md "${WORK}/agents-ask.md" "ask" ""
out="$(cat "${WORK}/agents-ask.md")"
has   "ask keeps the metadata block"   "${out}" "<METADATA>"
has   "ask keeps the product block"    "${out}" "<PRODUCT>"
has   "ask keeps the phase block"      "${out}" "<PROJECT_PHASE>"
has   "ask keeps the core rules"       "${out}" "<CORE_RULES>"
has   "ask keeps the setup note"       "${out}" "<PROFILE_SETUP>"
has   "ask keeps the service profile"  "${out}" '<PROFILE id="service">'
has   "ask keeps the tool profile"     "${out}" '<PROFILE id="tool">'
hasnt "ask adds no integration"        "${out}" "<INTEGRATION"

assemble_agents_md "${WORK}/agents-tool.md" "tool" "trellis"
out="$(cat "${WORK}/agents-tool.md")"
has   "tool keeps its own profile"     "${out}" '<PROFILE id="tool">'
hasnt "tool drops the other profile"   "${out}" '<PROFILE id="service">'
hasnt "a chosen profile drops the setup note" "${out}" "<PROFILE_SETUP>"
has   "requested integration is added" "${out}" '<INTEGRATION id="trellis">'

# A generated file must not open or close with blank lines: a trailing one is
# what makes a later block removal leave a double blank behind.
first="$(head -1 "${WORK}/agents-tool.md")"
last="$(tail -1 "${WORK}/agents-tool.md")"
if [[ -n "${first}" && -n "${last}" ]]; then
  ok "assembled files have no leading or trailing blank line"
else
  ko "assembled files have no leading or trailing blank line" "first=[${first}] last=[${last}]"
fi

# --- CLAUDE.md assembly ---------------------------------------------------
assemble_claude_md "${WORK}/claude-off.md" 0
hasnt "cc-workflow off leaves no reference" "$(cat "${WORK}/claude-off.md")" "CC-Cowork-Workflow.md"

assemble_claude_md "${WORK}/claude-on.md" 1
has "cc-workflow on references the file"  "$(cat "${WORK}/claude-on.md")" "CC-Cowork-Workflow.md"
has "cc-workflow on carries the block"    "$(cat "${WORK}/claude-on.md")" '<FEATURE id="cc-workflow">'

# --- the CC-Workflow variant ----------------------------------------------
is "no trellis picks the base variant"      "$(cc_workflow_variant "")"             "base"
is "trellis picks the trellis variant"      "$(cc_workflow_variant "trellis")"      "trellis"
is "trellis among others still matches"     "$(cc_workflow_variant "foo,trellis")"  "trellis"

# --- has_block ------------------------------------------------------------
if has_block "${WORK}/agents-tool.md" "CORE_RULES"; then ok "has_block finds a plain tag"; else ko "has_block finds a plain tag" "not found"; fi
if has_block "${WORK}/agents-tool.md" "PROFILE" "tool"; then ok "has_block finds a tag by id"; else ko "has_block finds a tag by id" "not found"; fi
if has_block "${WORK}/agents-tool.md" "PROFILE" "service"; then ko "has_block rejects a wrong id" "matched"; else ok "has_block rejects a wrong id"; fi

# --- file_format ------------------------------------------------------------
# Three states: the tag present (modern), the file there without it (legacy —
# the pre-block scaffolds this repo used to ship), and no file at all.
is "file_format: modern file reports modern" \
  "$(file_format "${WORK}/agents-tool.md" "CORE_RULES")" "modern"
printf 'plain markdown\nno tags anywhere\n' > "${WORK}/legacy-agents.md"
is "file_format: tag-less file reports legacy" \
  "$(file_format "${WORK}/legacy-agents.md" "CORE_RULES")" "legacy"
is "file_format: missing file reports missing" \
  "$(file_format "${WORK}/does-not-exist.md" "CORE_RULES")" "missing"
is "file_format: id-tagged file counts as modern" \
  "$(file_format "${WORK}/agents-tool.md" "PROFILE" "tool")" "modern"

# --- append / remove round trip -------------------------------------------
# Enabling and then disabling a feature has to leave the file exactly as it was,
# which is the whole promise of editing by block rather than by rewrite.
assemble_claude_md "${WORK}/rt-orig.md" 0
cp "${WORK}/rt-orig.md" "${WORK}/rt-work.md"
append_block_if_missing "${WORK}/rt-work.md" "FEATURE" "cc-workflow" \
  "${TEMPLATE_ROOT}/blocks/features/cc-workflow/claude-ref.md"
has "append adds the block" "$(cat "${WORK}/rt-work.md")" '<FEATURE id="cc-workflow">'
remove_block "${WORK}/rt-work.md" "FEATURE" "cc-workflow"
files_match "enable then disable is byte-identical" "${WORK}/rt-orig.md" "${WORK}/rt-work.md"

# Appending twice must not duplicate.
append_block_if_missing "${WORK}/rt-work.md" "FEATURE" "cc-workflow" \
  "${TEMPLATE_ROOT}/blocks/features/cc-workflow/claude-ref.md"
append_block_if_missing "${WORK}/rt-work.md" "FEATURE" "cc-workflow" \
  "${TEMPLATE_ROOT}/blocks/features/cc-workflow/claude-ref.md"
count="$(grep -c '<FEATURE id="cc-workflow">' "${WORK}/rt-work.md")"
is "append is idempotent" "${count}" "1"

# --- remove_block reports whether it did anything -------------------------
printf 'plain file\nno tags here\n' > "${WORK}/no-tags.md"
if remove_block "${WORK}/no-tags.md" "FEATURE" "cc-workflow"; then
  ko "remove_block reports a missing block" "returned success"
else
  ok "remove_block reports a missing block"
fi
is "a failed removal leaves the file alone" "$(cat "${WORK}/no-tags.md")" "$(printf 'plain file\nno tags here')"

# --- user content around a removed block is preserved ---------------------
cat > "${WORK}/mixed.md" <<'MD'
# My file

Something I wrote.


<FEATURE id="cc-workflow">
generated content
</FEATURE>

## My own section

- a bullet I care about
MD
remove_block "${WORK}/mixed.md" "FEATURE" "cc-workflow"
out="$(cat "${WORK}/mixed.md")"
hasnt "removal drops the block body"       "${out}" "generated content"
has   "removal keeps prose above"          "${out}" "Something I wrote."
has   "removal keeps the section below"    "${out}" "## My own section"
has   "removal keeps the user's bullet"    "${out}" "a bullet I care about"
blanks="$(awk 'BEGIN { run = 0; max = 0 } NF == 0 { run++; if (run > max) max = run; next } { run = 0 } END { print max }' "${WORK}/mixed.md")"
is "removal does not collapse the user's own blank lines" "${blanks}" "2"

# --- replace_block --------------------------------------------------------
printf '<CORE_RULES>\nold rules\n</CORE_RULES>\n' > "${WORK}/repl.md"
printf 'keep me\n' >> "${WORK}/repl.md"
printf '<CORE_RULES>\nnew rules\n</CORE_RULES>\n' > "${WORK}/repl-src.md"
replace_block "${WORK}/repl.md" "CORE_RULES" "" "${WORK}/repl-src.md"
out="$(cat "${WORK}/repl.md")"
has   "replace swaps the block body" "${out}" "new rules"
hasnt "replace drops the old body"   "${out}" "old rules"
has   "replace keeps the rest"       "${out}" "keep me"

if replace_block "${WORK}/no-tags.md" "CORE_RULES" "" "${WORK}/repl-src.md"; then
  ko "replace_block reports a missing block" "returned success"
else
  ok "replace_block reports a missing block"
fi

# --- materialize_template_set --------------------------------------------
materialize_template_set "${WORK}/set-plain" "ask" "" 0
if [[ -f "${WORK}/set-plain/AGENTS.md" && -f "${WORK}/set-plain/CLAUDE.md" \
   && -f "${WORK}/set-plain/.claude/settings.json" ]]; then
  ok "the set carries the managed files"
else
  ko "the set carries the managed files" "missing files in ${WORK}/set-plain"
fi
if [[ -f "${WORK}/set-plain/CC-Cowork-Workflow.md" ]]; then
  ko "cc-workflow off keeps the doc out of the set" "the file is there"
else
  ok "cc-workflow off keeps the doc out of the set"
fi
has "the settings still deny secrets" "$(cat "${WORK}/set-plain/.claude/settings.json")" "secrets/**"

materialize_template_set "${WORK}/set-trellis" "tool" "trellis" 1
has "cc-workflow on puts the doc in the set" "$(ls "${WORK}/set-trellis")" "CC-Cowork-Workflow.md"
has "a trellis set gets the trellis variant" "$(cat "${WORK}/set-trellis/CC-Cowork-Workflow.md")" "trellis-check"

materialize_template_set "${WORK}/set-base-cc" "tool" "" 1
hasnt "a plain set gets the plain variant" "$(cat "${WORK}/set-base-cc/CC-Cowork-Workflow.md")" "trellis-check"

# The document delegates through the subagent, so the feature has to be one
# thing: a project that got the doc without the agent reads instructions for a
# tool it does not have.
if [[ -f "${WORK}/set-base-cc/.claude/agents/codex-run.md" \
   && -f "${WORK}/set-trellis/.claude/agents/codex-run.md" ]]; then
  ok "cc-workflow on ships the delegation subagent too"
else
  ko "cc-workflow on ships the delegation subagent too" "no .claude/agents/codex-run.md in the set"
fi
if [[ -f "${WORK}/set-plain/.claude/agents/codex-run.md" ]]; then
  ko "cc-workflow off keeps the subagent out" "the file is there"
else
  ok "cc-workflow off keeps the subagent out"
fi
# The name in the frontmatter is what the Agent tool is called with; the
# document names `codex-run`, and a rename on one side alone breaks the flow.
has "the subagent answers to the name the doc uses" \
  "$(cat "${WORK}/set-base-cc/.claude/agents/codex-run.md")" "name: codex-run"
has "the doc points at the agent file it ships" \
  "$(cat "${WORK}/set-base-cc/CC-Cowork-Workflow.md")" ".claude/agents/codex-run.md"
# The courier's two load-bearing defaults. Losing either is how the old flow
# went wrong: a rewritten prompt, or a write-capable run nobody asked for.
has "the subagent forbids touching the prompt" \
  "$(cat "${WORK}/set-base-cc/.claude/agents/codex-run.md")" "by path, never by value"
has "the subagent defaults to read-only" \
  "$(cat "${WORK}/set-base-cc/.claude/agents/codex-run.md")" "no\` (read-only)"
# The waiter is what makes a long job cost the same as a short one. Lose it and
# the agent falls back to chunked waiting bounded by the foreground time limit,
# which is the design this replaced.
has "the subagent waits by arming a detached waiter" \
  "$(cat "${WORK}/set-base-cc/.claude/agents/codex-run.md")" "run_in_background"
has "and is told never to poll" \
  "$(cat "${WORK}/set-base-cc/.claude/agents/codex-run.md")" "Never poll"

# The manual test checklist is a feature, not part of common/ — a project that
# never opens one should not carry it. common/ is copied whole, so the only way
# to make it optional was to move it out of there.
materialize_template_set "${WORK}/set-list-on" "tool" "" 0 1
if [[ -f "${WORK}/set-list-on/Test/templates-test-checklist.html" ]]; then
  ok "the checklist is in the set when asked for"
else
  ko "the checklist is in the set when asked for" "no Test/templates-test-checklist.html"
fi
if [[ -f "${WORK}/set-plain/Test/templates-test-checklist.html" ]]; then
  ko "and stays out of it when not" "the file is there"
else
  ok "and stays out of it when not"
fi
has "the checklist that ships is the real page" \
  "$(head -3 "${WORK}/set-list-on/Test/templates-test-checklist.html")" "<!DOCTYPE html>"

# The variants are kept line-for-line so a change to one is visibly a change to
# the other; equal length is the cheap proof that no edit landed in only one.
base_lines="$(wc -l < "${TEMPLATE_ROOT}/blocks/features/cc-workflow/base.md" | tr -d ' ')"
trellis_lines="$(wc -l < "${TEMPLATE_ROOT}/blocks/features/cc-workflow/trellis.md" | tr -d ' ')"
is "both workflow variants stay the same length" "${base_lines}" "${trellis_lines}"
# The repo keeps its own copy of the workflow document at the root, for this
# project's agents. Nothing syncs it, so the test is what keeps it honest.
files_match "the repo's own copy matches the template" \
  "${REPO_ROOT}/CC-Cowork-Workflow.md" "${TEMPLATE_ROOT}/blocks/features/cc-workflow/base.md"

# --- the renderer ---------------------------------------------------------
# Nothing may put a newline inside a status row: one there breaks the layout,
# and `git rev-parse` on a repository with no commits returns exactly that.
rows="$( { ui_kv "Label" "$(printf 'two\nlines')"; } 2>&1 )"
is "a status row stays on one line" "$(printf '%s' "${rows}" | wc -l | tr -d ' ')" "1"

long="$( { ui_kv "Label" "$(printf 'x%.0s' $(seq 1 200))"; } 2>&1 )"
if [[ "${#long}" -lt 260 ]]; then
  ok "an over-long value is truncated"
else
  ko "an over-long value is truncated" "row is ${#long} chars"
fi

# lib/ui.sh defines its glyphs and colors twice, once per branch of the color
# check. A name defined in only one of them is invisible until the day output is
# piped, and then it takes the whole run down with an unbound variable under
# `set -u`. Compare the two branches directly rather than hoping a smoke test
# happens to touch the missing one.
ui_branch_names() {
  awk -v want="$1" '
    # branch starts at -1, not the implicit 0: 0 means the plain branch, so an
    # uninitialized variable would sweep in the assignments above the if.
    BEGIN { branch = -1 }
    index($0, "if ") == 1 && index($0, "UI_COLOR_ENABLED") && index($0, "-eq 1") {
      branch = 1
      next
    }
    branch == 1 && $0 == "else" { branch = 0; next }
    branch == 0 && $0 == "fi"   { branch = -1; next }
    branch == want && /^  UI_[A-Z_]+=/ {
      name = $0
      sub(/=.*/, "", name)
      gsub(/^ +/, "", name)
      print name
    }
  ' "${REPO_ROOT}/lib/ui.sh" | sort
}
color_names="$(ui_branch_names 1)"
plain_names="$(ui_branch_names 0)"
if [[ -n "${color_names}" && "${color_names}" == "${plain_names}" ]]; then
  ok "both color branches define the same UI_ names"
else
  ko "both color branches define the same UI_ names" "$(diff <(printf '%s\n' "${color_names}") <(printf '%s\n' "${plain_names}") | tr '\n' ' ')"
fi

# And the messages themselves still render, with the wording scripts match on.
levels="$(NO_COLOR=1 bash -c '
  set -euo pipefail
  . "'"${REPO_ROOT}"'/lib/ui.sh"
  ui_log log; ui_ok ok; ui_warn warn; ui_error err
  ui_intro title sub; ui_step Q A; ui_section S; ui_kv K V; ui_gap; ui_outro bye
  echo SURVIVED' 2>&1)"
has "every message level renders without color" "${levels}" "SURVIVED"
has "warnings keep their plain wording"         "${levels}" "warning: warn"
has "errors keep their plain wording"           "${levels}" "error: err"

# --- prompt contracts without a terminal ----------------------------------
# The CLI leans on these: with no terminal to read from, a prompt answers with
# its default and prints nothing that would confuse a parser.
opts_a="$(prompt_opt alpha Alpha first)"
opts_b="$(prompt_opt beta Beta second)"
answer="$(ui_select "Pick" "beta" "${opts_a}" "${opts_b}" </dev/null 2>/dev/null)"
is "a selector with no terminal returns its default" "${answer}" "beta"

answer="$(ui_input "Name" "fallback" </dev/null 2>/dev/null)"
is "an input with no terminal returns its default" "${answer}" "fallback"

answer="$(ui_multiselect "Files" "all" "${opts_a}" "${opts_b}" </dev/null 2>/dev/null | tr '\n' ' ')"
is "a checklist with no terminal returns everything" "${answer}" "alpha beta "

answer="$(ui_multiselect "Files" "none" "${opts_a}" "${opts_b}" </dev/null 2>/dev/null | tr '\n' ' ')"
is "a checklist preselected none returns nothing" "${answer}" ""

if ui_confirm "Sure?" "yes" </dev/null 2>/dev/null; then ok "confirm defaults to yes"; else ko "confirm defaults to yes" "returned no"; fi
if ui_confirm "Sure?" "no" </dev/null 2>/dev/null; then ko "confirm defaults to no" "returned yes"; else ok "confirm defaults to no"; fi

# Records survive labels and hints containing spaces and punctuation.
_prompt_split "$(prompt_opt "--claude --codex" "Claude Code + Codex" "two: platforms")"
is "a record round-trips its value" "${PROMPT_VALUE}" "--claude --codex"
is "a record round-trips its label" "${PROMPT_LABEL}" "Claude Code + Codex"
is "a record round-trips its hint"  "${PROMPT_HINT}"  "two: platforms"

# --- the semantic state palette --------------------------------------------
# Color encodes what kind of state a value is, not what the word says. The one
# that matters most is "off": deliberately-off and absent states are dim, not
# red, because CC-Workflow is off in most projects by design and a card that
# cries wolf on the normal case spends the color that should mean "act now".
is "ok reads green"    "$(UI_GREEN=G  _ui_state_color ok)"   "G"
is "info reads cyan"   "$(UI_CYAN=C   _ui_state_color info)" "C"
is "todo reads yellow" "$(UI_YELLOW=Y _ui_state_color todo)" "Y"
is "bad reads red"     "$(UI_RED=R    _ui_state_color bad)"  "R"
is "off reads dim"     "$(UI_DIM=D    _ui_state_color off)"  "D"
is "an unknown level falls back to dim" "$(UI_DIM=D _ui_state_color nonsense)" "D"

# Plain mode has to render exactly what ui_kv would have printed. Everything
# that greps this tool's output — the whole dry-run suite included — reads that
# string, so the colored version may not change a single byte of it.
plain_row="$(NO_COLOR=1 bash -c '
  set -euo pipefail
  . "'"${REPO_ROOT}"'/lib/ui.sh"
  ui_kv_state "Trellis" ok "Active" "Project v1 / CLI v2"
  ui_kv_state "CC-Workflow" off "Disabled"
' 2>&1)"
has "a plain state row keeps the state and detail together" "${plain_row}" "Active (Project v1 / CLI v2)"
has "a plain state row with no detail is just the word"     "${plain_row}" "Disabled"
hasnt "a plain state row carries no parens of its own"      "${plain_row}" "Disabled ("

rich_row="$(bash -c '
  set -euo pipefail
  . "'"${REPO_ROOT}"'/lib/ui.sh"
  UI_RICH=1; UI_DIM="<d>"; UI_RESET="<r>"; UI_GREEN="<g>"; UI_G_BAR="|"
  ui_kv_state "Trellis" ok "Active" "Project v1 / CLI v2"
' 2>&1)"
has "the state word carries the color"  "${rich_row}" "<g>Active<r>"
has "the detail beside it is dimmed"    "${rich_row}" "<d>(Project v1 / CLI v2)<r>"

# --- option records carry an optional hint level ----------------------------
# The fourth field is new; a three-field record has to keep splitting exactly as
# it did, because every other caller in the tool still builds one.
_prompt_split "$(prompt_opt sync "Sync template files" "2 to review" todo)"
is "a four-field record keeps its hint"  "${PROMPT_HINT}"       "2 to review"
is "a four-field record keeps its level" "${PROMPT_HINT_LEVEL}" "todo"
_prompt_split "$(prompt_opt quit "Exit" "")"
is "a three-field record still splits"   "${PROMPT_LABEL}"      "Exit"
is "a record with no level reports none" "${PROMPT_HINT_LEVEL}" ""
_prompt_split "$(prompt_opt trellis "Trellis management" "platforms, update, upgrade")"
is "a legacy hint survives untouched"    "${PROMPT_HINT}"       "platforms, update, upgrade"
is "a legacy hint stays level-less"      "${PROMPT_HINT_LEVEL}" ""

# --- plan states map to one palette -----------------------------------------
# The file list, the sync report and the menu hint all read the same plan, so
# they have to color the same state the same way.
is "a new file reads ok"        "$(sync_state_level new)"    "ok"
is "a refresh reads info"       "$(sync_state_level update)" "info"
is "a review reads todo"        "$(sync_state_level review)" "todo"
is "a conversion reads todo"    "$(sync_state_level legacy)" "todo"
is "an up-to-date file reads off" "$(sync_state_level same)" "off"

is "one block is singular" "$(_sync_blocks_noun 1)" "block"
is "two blocks are plural" "$(_sync_blocks_noun 2)" "blocks"

# --- trellis update asks first when there is nothing to update --------------
# `trellis update` is not a no-op on a project already at the CLI's version: it
# rescans everything and stops to ask about each file the user has edited, which
# "Sync everything and exit" used to walk into on every single run.
FAKE_TRELLIS="${WORK}/fakebin"
mkdir -p "${FAKE_TRELLIS}"
printf '#!/usr/bin/env bash\n[[ "$1" == "--version" ]] && { echo "0.6.16"; exit 0; }\necho "RAN trellis $*"\n' \
  > "${FAKE_TRELLIS}/trellis"
chmod +x "${FAKE_TRELLIS}/trellis"
mkdir -p "${WORK}/trproj/.trellis"

trellis_update_run() {
  PATH="${FAKE_TRELLIS}:${PATH}" bash -c '
    set -uo pipefail
    . "'"${REPO_ROOT}"'/lib/ui.sh"
    . "'"${REPO_ROOT}"'/lib/trellis.sh"
    DRY_RUN=0
    run_in_dir() { local d="$1"; shift; (cd "${d}" && "$@"); }
    ask_yes_no() { printf "ASKED\n" >&2; [[ "'"$2"'" == yes ]]; }
    trellis_update_project "'"$1"'"
  ' 2>&1
}

printf '0.6.16\n' > "${WORK}/trproj/.trellis/.version"
out="$(trellis_update_run "${WORK}/trproj" no)"
has   "a matching version asks before updating" "${out}" "ASKED"
has   "and says why it is asking"               "${out}" "already at v0.6.16"
hasnt "and declining runs nothing"              "${out}" "RAN trellis update"

out="$(trellis_update_run "${WORK}/trproj" yes)"
has "accepting still runs the update" "${out}" "RAN trellis update"

printf '0.5.0\n' > "${WORK}/trproj/.trellis/.version"
out="$(trellis_update_run "${WORK}/trproj" no)"
hasnt "a version behind the CLI does not ask" "${out}" "ASKED"
has   "a version behind the CLI just updates" "${out}" "RAN trellis update"

# --- copying anyway, when the plan says there is nothing to copy ------------
# The mirror of the Trellis version gate. The plan is very nearly always right
# that an up-to-date project needs no copy, and "nearly" is why the escape
# hatch exists: a template edited by hand is invisible to a hash comparison.
ANYPROJ="${WORK}/anyproj"
mkdir -p "${ANYPROJ}"
TEMPLATE_FILES=("AGENTS.md" "CLAUDE.md" ".claude/settings.json")
DRY_RUN=0
ensure_dir() { [[ -d "$1" ]] || mkdir -p "$1"; }
materialize_template_set "${TEMPLATE_DIR}" "ask" "" 0
cp "${TEMPLATE_DIR}/AGENTS.md" "${ANYPROJ}/AGENTS.md"
APPLIED_TEMPLATES=()
APPLIED_LEGACY=()
copy_all_templates_anyway "${ANYPROJ}"

if [[ -f "${ANYPROJ}/AGENTS.md.template" ]]; then
  ok "copying anyway writes the template beside a matching file"
else
  ko "copying anyway writes the template beside a matching file" "no AGENTS.md.template"
fi
if [[ -f "${ANYPROJ}/CLAUDE.md" && ! -f "${ANYPROJ}/CLAUDE.md.template" ]]; then
  ok "a file that was absent is created outright"
else
  ko "a file that was absent is created outright" "CLAUDE.md handling wrong"
fi
is "and the pair is recorded for the merge prompt" \
  "${APPLIED_TEMPLATES[*]}" "AGENTS.md"

# And the gate in front of it actually reaches the copy. Testing the helper
# alone left this uncovered: a mutation that deleted the call from the gate
# passed every assertion.
GATEPROJ="${WORK}/gateproj"
mkdir -p "${GATEPROJ}"
cp "${TEMPLATE_DIR}/AGENTS.md" "${GATEPROJ}/AGENTS.md"
_prompt_can_ask() { return 0; }
GATE_ANSWER="no"
ask_yes_no() { [[ "${GATE_ANSWER}" == "yes" ]]; }

APPLIED_TEMPLATES=(); APPLIED_LEGACY=()
offer_copy_anyway "${GATEPROJ}"
if [[ -e "${GATEPROJ}/AGENTS.md.template" ]]; then
  ko "declining the offer copies nothing" "wrote a template anyway"
else
  ok "declining the offer copies nothing"
fi

GATE_ANSWER="yes"
APPLIED_TEMPLATES=(); APPLIED_LEGACY=()
offer_copy_anyway "${GATEPROJ}"
if [[ -f "${GATEPROJ}/AGENTS.md.template" ]]; then
  ok "accepting the offer performs the copy"
else
  ko "accepting the offer performs the copy" "no template was written"
fi

ASSUME_DEFAULTS=1
rm -f "${GATEPROJ}/AGENTS.md.template"
offer_copy_anyway "${GATEPROJ}"
if [[ -e "${GATEPROJ}/AGENTS.md.template" ]]; then
  ko "a scripted run is never offered the copy" "wrote a template under -y"
else
  ok "a scripted run is never offered the copy"
fi
ASSUME_DEFAULTS=0

# --- the cursor reveals a toggle's state ------------------------------------
# The hint itself must not move as the selection travels — only the active note
# appears — so the menu does not shuffle sideways under the cursor.
draw_menu() {
  bash -c '
    set -euo pipefail
    . "'"${REPO_ROOT}"'/lib/ui.sh"
    . "'"${REPO_ROOT}"'/lib/prompt.sh"
    UI_RICH=1; UI_DIM="<d>"; UI_RESET="<r>"; UI_GREEN="<g>"; UI_YELLOW="<y>"
    UI_G_BAR="|"; UI_S_ON="*"; UI_S_OFF="o"
    _prompt_draw_options '"$1"' \
      "$(prompt_opt integ "Toggle Trellis block" "in AGENTS.md" ok on)" \
      "$(prompt_opt quit  "Exit")"
  ' 2>&1
}
selected_row="$(draw_menu 0)"
other_row="$(draw_menu 1)"
has   "the selected row shows its state"      "${selected_row}" "<g>on<r>"
hasnt "an unselected row keeps its state off" "${other_row}"    "<g>on"
has   "the hint is there either way"          "${selected_row}" "<d>in AGENTS.md<r>"
has   "and reads identically when not selected" "${other_row}"  "<d>in AGENTS.md<r>"

# The note goes in FRONT, which pushes the hint right on the selected row only.
# That sideways shift is deliberate — it is what makes the state impossible to
# miss on the one row where Enter changes something — so assert it happens.
sel_col="$(printf '%s' "${selected_row}" | sed -n '1p' | sed 's/<[a-z]*>//g' | awk '{ print index($0, "in AGENTS.md") }')"
oth_col="$(printf '%s' "${other_row}"    | sed -n '1p' | sed 's/<[a-z]*>//g' | awk '{ print index($0, "in AGENTS.md") }')"
if [[ "${sel_col}" -gt "${oth_col}" && "${oth_col}" -gt 0 ]]; then
  ok "the note pushes the hint right on the selected row"
else
  ko "the note pushes the hint right on the selected row" "selected col ${sel_col}, unselected col ${oth_col}"
fi

# And "off" is readable rather than hidden: a legitimate state must not be dim,
# which is the one thing the reader is there to check.
off_row="$(bash -c '
  set -euo pipefail
  . "'"${REPO_ROOT}"'/lib/ui.sh"
  . "'"${REPO_ROOT}"'/lib/prompt.sh"
  UI_RICH=1; UI_DIM="<d>"; UI_RESET="<r>"; UI_GREEN="<g>"
  UI_G_BAR="|"; UI_S_ON="*"; UI_S_OFF="o"
  _prompt_draw_options 0 "$(prompt_opt integ "Toggle Trellis block" "in AGENTS.md" neutral off)"
' 2>&1)"
has   "an off state is shown"          "${off_row}" "off"
hasnt "an off state is not dimmed"     "${off_row}" "<d>off"
is    "neutral carries no color at all" "$(UI_DIM=D UI_GREEN=G _ui_state_color neutral)" ""

# Resident text is always dim, even carrying a level. It never varies, so it has
# no news to deliver; all colour belongs to the part that changes. A row that
# coloured its resident text would compete with its own reveal.
sync_row="$(bash -c '
  set -euo pipefail
  . "'"${REPO_ROOT}"'/lib/ui.sh"
  . "'"${REPO_ROOT}"'/lib/prompt.sh"
  UI_RICH=1; UI_DIM="<d>"; UI_RESET="<r>"; UI_YELLOW="<y>"
  UI_G_BAR="|"; UI_S_ON="*"; UI_S_OFF="o"
  _prompt_draw_options 0 "$(prompt_opt sync "Sync template files" "templates" todo "2 to review")"
' 2>&1)"
has   "resident text stays dim whatever its level" "${sync_row}" "<d>templates<r>"
has   "and the reveal is what carries the colour"  "${sync_row}" "<y>2 to review<r>"
hasnt "the resident text is never level-coloured"  "${sync_row}" "<y>templates"

# A five-field record has to round-trip, and shorter ones must not change.
_prompt_split "$(prompt_opt integ "Toggle Trellis block" "in AGENTS.md" ok on)"
is "a five-field record keeps its hint"   "${PROMPT_HINT}"       "in AGENTS.md"
is "a five-field record keeps its level"  "${PROMPT_HINT_LEVEL}" "ok"
is "a five-field record keeps its note"   "${PROMPT_ACTIVE}"     "on"
_prompt_split "$(prompt_opt sync "Sync template files" "2 to review" todo)"
is "a four-field record has no note"      "${PROMPT_ACTIVE}"     ""
is "a four-field record keeps its level"  "${PROMPT_HINT_LEVEL}" "todo"
_prompt_split "$(prompt_opt trellis "Trellis management" "platforms, update, upgrade")"
is "a three-field record is unchanged"    "${PROMPT_HINT}"       "platforms, update, upgrade"
is "a three-field record has no note"     "${PROMPT_ACTIVE}"     ""

# There is no cursor in the no-color list, so the state cannot be hidden behind
# one: it shows on every row instead.
plain_menu="$(NO_COLOR=1 bash -c '
  set -euo pipefail
  . "'"${REPO_ROOT}"'/lib/ui.sh"
  . "'"${REPO_ROOT}"'/lib/prompt.sh"
  _prompt_select_plain "Pick" 0 \
    "$(prompt_opt integ "Toggle Trellis block" "in AGENTS.md" ok on)" </dev/null
' 2>&1)"
has "the no-color list still shows the state" "${plain_menu}" "in AGENTS.md (on)"

# --- every dynamic value lives in the reveal, not the resident text ---------
# The principle in AGENTS.md: resident text names what a row is about and never
# varies; anything that changes is revealed under the cursor. A row whose
# resident text moved with the project would teach the reader to re-scan the
# whole column instead of trusting it.
NOTEPROJ="${WORK}/noteproj"
mkdir -p "${NOTEPROJ}"
# The dashboard asks the Trellis CLI for its version. Point it at the fake so
# the rows below never depend on whatever trellis this machine has installed.
PATH_BEFORE_FAKE="${PATH}"
PATH="${FAKE_TRELLIS}:${PATH}"
SYNC_N_NEW=0 SYNC_N_UPDATE=0 SYNC_N_REVIEW=0 SYNC_N_LEGACY=0

resident_of() {
  _prompt_split "$(dashboard_actions "${NOTEPROJ}" | grep -F "$1")"
  printf '%s' "${PROMPT_HINT}"
}
reveal_of() {
  _prompt_split "$(dashboard_actions "${NOTEPROJ}" | grep -F "$1")"
  printf '%s' "${PROMPT_ACTIVE}"
}

before_sync="$(resident_of sync)"
before_all="$(resident_of syncall)"
SYNC_N_REVIEW=3
after_sync="$(resident_of sync)"
after_all="$(resident_of syncall)"
is "the sync row's resident text does not move with the plan"  "${before_sync}" "${after_sync}"
is "nor does sync-everything's"                                "${before_all}"  "${after_all}"
is "and it names what the row is about"                        "${after_sync}"  "templates"

# The version the sync would bring the project to is revealed, not resident.
has "the reveal carries the template version" "$(reveal_of sync)" "v${VIBE_INIT_VERSION}"
has "and the shape of the work beside it"     "$(reveal_of sync)" "3 to review"
SYNC_N_REVIEW=0

# "Sync everything and exit" used to promise "templates + Trellis update"
# unconditionally. On a project with nothing to do it does neither.
is "with nothing pending it says so" "$(reveal_of syncall)" "nothing to do"

# A reveal must never be dimmer than the resident text it sits next to, or the
# two read as one run-on phrase and the reveal stops being a reveal.
_prompt_split "$(dashboard_actions "${NOTEPROJ}" | grep -F 'syncall')"
is    "an idle reveal reads neutral, not dim" "${PROMPT_HINT_LEVEL}" "neutral"
_prompt_split "$(dashboard_actions "${NOTEPROJ}" | grep -F "$(printf 'sync\x1f')")"
is    "so does an up-to-date sync reveal"     "${PROMPT_HINT_LEVEL}" "neutral"
is    "off is lifted to neutral"              "$(reveal_level off)"  "neutral"
is    "an empty level is lifted too"          "$(reveal_level "")"   "neutral"
is    "a real level passes through"           "$(reveal_level todo)" "todo"

# Trellis reveals what opening the submenu would show, so the versions can be
# read without a trip in and back out.
trellis_note_for() {
  PATH="${FAKE_TRELLIS}:${PATH}" bash -c '
    set -uo pipefail
    SCRIPT_DIR="'"${WORK}"'"
    . "'"${REPO_ROOT}"'/lib/ui.sh"
    . "'"${REPO_ROOT}"'/lib/prompt.sh"
    . "'"${REPO_ROOT}"'/lib/block_engine.sh"
    . "'"${REPO_ROOT}"'/lib/state.sh"
    . "'"${REPO_ROOT}"'/lib/trellis.sh"
    . "'"${REPO_ROOT}"'/lib/apply.sh"
    trellis_menu_note "'"$1"'"
  ' 2>/dev/null
}
mkdir -p "${WORK}/tnote/.trellis"
printf '0.6.16\n' > "${WORK}/tnote/.trellis/.version"
has "a current Trellis reads as current" "$(trellis_note_for "${WORK}/tnote")" "v0.6.16, current"
printf '0.5.0\n' > "${WORK}/tnote/.trellis/.version"
has "a stale one shows the move"         "$(trellis_note_for "${WORK}/tnote")" "v0.5.0 -> CLI v0.6.16"
mkdir -p "${WORK}/tnote2"
has "a project without Trellis says so"  "$(trellis_note_for "${WORK}/tnote2")" "not initialized"

# --- the dashboard leads with whatever has work -----------------------------
# On a project already in sync, "Sync template files" can only repeat the card
# above it, so it must not sit on the default and spend the first row.
menu_order() {
  dashboard_actions "$1" "hint" "off" | while IFS= read -r rec; do
    _prompt_split "${rec}"
    printf '%s ' "${PROMPT_VALUE}"
  done
}
MENUPROJ="${WORK}/menuproj"
mkdir -p "${MENUPROJ}"

SYNC_N_NEW=0 SYNC_N_UPDATE=0 SYNC_N_REVIEW=0 SYNC_N_LEGACY=0
is "with nothing to sync, sync drops below the toggles" \
  "$(menu_order "${MENUPROJ}")" "trellis ccflow checklist integ sync syncall quit "

SYNC_N_REVIEW=2
is "with work to do, sync leads the menu" \
  "$(menu_order "${MENUPROJ}")" "sync trellis ccflow checklist integ syncall quit "
SYNC_N_REVIEW=0

# Each toggle reports the state the project is actually in.
_prompt_split "$(dashboard_actions "${MENUPROJ}" "" "" | grep -F 'ccflow')"
is "an absent workflow file reads off"       "${PROMPT_ACTIVE}"     "off"
is "and reads neutral, not dim"              "${PROMPT_HINT_LEVEL}" "neutral"
is "while its hint names what it toggles"    "${PROMPT_HINT}"       "CC-Cowork-Workflow.md"
printf 'workflow\n' > "${MENUPROJ}/CC-Cowork-Workflow.md"
printf '<INTEGRATION id="trellis">\nx\n</INTEGRATION>\n' > "${MENUPROJ}/AGENTS.md"
_prompt_split "$(dashboard_actions "${MENUPROJ}" "" "" | grep -F 'ccflow')"
is "a present workflow file reads on"        "${PROMPT_ACTIVE}"     "on"
is "and takes the ok level"                  "${PROMPT_HINT_LEVEL}" "ok"
_prompt_split "$(dashboard_actions "${MENUPROJ}" "" "" | grep -F 'integ')"
is "the Trellis block reports itself present" "${PROMPT_ACTIVE}"    "on"
is "while its hint stays put"                 "${PROMPT_HINT}"      "in AGENTS.md"
# The checklist is a file with no block anywhere, so presence is the whole
# state — and absent must read as a choice (neutral), never as something due.
_prompt_split "$(dashboard_actions "${MENUPROJ}" "" "" | grep -F 'checklist')"
is "an absent checklist reads off"            "${PROMPT_ACTIVE}"     "off"
is "and reads neutral, not dim"               "${PROMPT_HINT_LEVEL}" "neutral"
is "while its hint names the file"            "${PROMPT_HINT}"       "Test/templates-test-checklist.html"
mkdir -p "${MENUPROJ}/Test"
printf 'checklist\n' > "${MENUPROJ}/Test/templates-test-checklist.html"
_prompt_split "$(dashboard_actions "${MENUPROJ}" "" "" | grep -F 'checklist')"
is "a present checklist reads on"             "${PROMPT_ACTIVE}"     "on"
is "and takes the ok level"                   "${PROMPT_HINT_LEVEL}" "ok"
rm -rf "${MENUPROJ}/Test"
PATH="${PATH_BEFORE_FAKE}"

# --- every ui_* the tool calls has to exist ---------------------------------
# ui_info did not. lib/ui.sh defines ui_log, and eleven call sites across
# lib/apply.sh and lib/trellis.sh asked for ui_info instead, so both dashboard
# toggles and three Trellis operations died with "ui_info: command not found"
# the moment a user picked them. Neither suite can reach an interactive menu, so
# a name check is what catches this class — not a smoke test.
ui_defined="$(grep -hoE '^ui_[a-z_]+\(\)' "${REPO_ROOT}"/lib/*.sh | tr -d '()' | sort -u)"
ui_missing=""
for name in $(grep -rhoE '\bui_[a-z_]+\b' "${REPO_ROOT}"/lib/*.sh "${REPO_ROOT}/vibe-init.sh" | sort -u); do
  printf '%s\n' "${ui_defined}" | grep -qx "${name}" || ui_missing="${ui_missing}${name} "
done
is "every ui_* the tool calls is defined somewhere in lib/" "${ui_missing% }" ""

# --- the info level is dim, and the copy block is not in the gutter ---------
rich_info="$(bash -c '
  set -euo pipefail
  . "'"${REPO_ROOT}"'/lib/ui.sh"
  UI_RICH=1; UI_DIM="<dim>"; UI_RESET="<off>"; UI_G_BAR="|"
  ui_info "copied a file"
' 2>&1)"
has "rich info is drawn dim" "${rich_info}" "<dim>copied a file<off>"

plain_info="$(NO_COLOR=1 bash -c '
  set -euo pipefail
  . "'"${REPO_ROOT}"'/lib/ui.sh"
  ui_info "copied a file"
' 2>&1)"
is "plain info keeps the bare wording" "${plain_info}" "[vibe-init] copied a file"

plain_fence="$(NO_COLOR=1 bash -c '
  set -euo pipefail
  . "'"${REPO_ROOT}"'/lib/ui.sh"
  ui_copy_open "suggested prompt for your AI agent"
  ui_copy_close
' 2>&1)"
has   "the copy block announces itself"     "${plain_fence}" "suggested prompt for your AI agent"
hasnt "the copy block never hangs off the gutter" "${plain_fence}" "|"
hasnt "the copy block carries no plain prefix"    "${plain_fence}" "[vibe-init]"

rich_fence="$(bash -c '
  set -euo pipefail
  . "'"${REPO_ROOT}"'/lib/ui.sh"
  UI_RICH=1; UI_DIM="<dim>"; UI_RESET="<off>"; UI_RULE="-"
  ui_copy_open "a title"
' 2>&1)"
has "the copy rule is dim, not the loudest thing on screen" "${rich_fence}" "<dim>---------- a title ----------<off>"

# --- list_blocks / extract_block -------------------------------------------
# The opening tag has to own its line to count. That is how the assembled files
# are written, and it is what keeps tag-shaped prose out of the vocabulary — the
# CC-Workflow document really does contain a `<YYYY>/<MM>/<DD>` path.
printf '<ALPHA>\nbody\n</ALPHA>\n\n<BETA id="two">\nmore\n</BETA>\n\nsee ~/x/<YYYY>/<MM>/rollout\n' \
  > "${WORK}/blocks.md"
listed="$(list_blocks "${WORK}/blocks.md" | tr '\t\n' ',;')"
is    "list_blocks reports tag and id in order" "${listed}" "ALPHA,;BETA,two;"
hasnt "list_blocks ignores tag-shaped prose"    "${listed}" "YYYY"

is "extract_block returns the block with its tags" \
  "$(extract_block "${WORK}/blocks.md" BETA two)" '<BETA id="two">
more
</BETA>'
if extract_block "${WORK}/blocks.md" NOPE >/dev/null 2>&1; then
  ko "extract_block reports a missing block" "returned success"
else
  ok "extract_block reports a missing block"
fi

# A block hash taken out of an assembled file must equal the hash of the
# templates/blocks/ fragment it came from, or nothing downstream can compare
# a project against the template it was built from.
assemble_agents_md "${WORK}/agents-hash.md" "ask" ""
is "a block hashes the same as its source fragment" \
  "$(hash_block "${WORK}/agents-hash.md" CORE_RULES)" \
  "$(hash_file "${TEMPLATE_ROOT}/blocks/core_rules.md")"

# --- merge_verdict ----------------------------------------------------------
# The whole sync rests on these four answers.
is "verdict: target already is the template"        "$(merge_verdict A A B)" "same"
is "verdict: template has not moved, edits are ours" "$(merge_verdict B A B)" "local"
is "verdict: template moved, target did not"        "$(merge_verdict A B B)" "forward"
is "verdict: both moved"                            "$(merge_verdict A B C)" "review"
is "verdict: no merge base means review"            "$(merge_verdict A B '')"  "review"

if block_is_optional PROFILE; then ok "a pruned profile counts as optional"; else ko "a pruned profile counts as optional" "not optional"; fi
if block_is_optional CORE_RULES; then ko "core rules are not optional" "reported optional"; else ok "core rules are not optional"; fi

# --- the state manifest -----------------------------------------------------
PROJ="${WORK}/proj"
mkdir -p "${PROJ}"
STATE_RECORDS=()
state_record_file  "AGENTS.md" "hash-file-1"
state_record_block "AGENTS.md" "CORE_RULES" "" "hash-core-1"
state_record_block "AGENTS.md" "PROFILE" "tool" "hash-tool-1"
state_flush "${PROJ}"

if [[ -f "${PROJ}/.vibe-init/manifest" ]]; then ok "state_flush writes the manifest"; else ko "state_flush writes the manifest" "no manifest"; fi
is "a file hash round-trips"          "$(state_file_hash  "${PROJ}" "AGENTS.md")" "hash-file-1"
is "a block hash round-trips"         "$(state_block_hash "${PROJ}" "AGENTS.md" "CORE_RULES" "")" "hash-core-1"
is "a block hash is keyed by its id"  "$(state_block_hash "${PROJ}" "AGENTS.md" "PROFILE" "tool")" "hash-tool-1"
is "an unrecorded file has no hash"   "$(state_file_hash  "${PROJ}" "CLAUDE.md")" ""
is "the manifest carries the version" "$(state_get "${PROJ}" version)" "test"
if state_is_tracked "${PROJ}"; then ok "a project with a manifest reads as tracked"; else ko "a project with a manifest reads as tracked" "not tracked"; fi

# A second flush must replace only what it re-records. A block left out keeps
# its old merge base — that is what lets a conflicted block stay comparable on
# the next run instead of being forgotten.
STATE_RECORDS=()
state_record_block "AGENTS.md" "CORE_RULES" "" "hash-core-2"
state_flush "${PROJ}"
is "re-recording a block replaces it"    "$(state_block_hash "${PROJ}" "AGENTS.md" "CORE_RULES" "")" "hash-core-2"
is "an untouched block keeps its base"   "$(state_block_hash "${PROJ}" "AGENTS.md" "PROFILE" "tool")" "hash-tool-1"
is "an untouched file keeps its base"    "$(state_file_hash  "${PROJ}" "AGENTS.md")" "hash-file-1"

# A run can stage no records at all and still flush: record_trellis_state sets
# one header field and writes. The merge awk keyed on NR == FNR, which with an
# empty staging file matched every line of the manifest instead — so pausing
# Trellis silently dropped every hash and took the merge base with it, leaving
# the next sync to call every file a conflict.
STATE_RECORDS=()
STATE_SET_TRELLIS="paused"
state_flush "${PROJ}"
STATE_SET_TRELLIS=""
is "a flush with nothing staged keeps file hashes"  "$(state_file_hash  "${PROJ}" "AGENTS.md")" "hash-file-1"
is "and keeps block hashes"                         "$(state_block_hash "${PROJ}" "AGENTS.md" "PROFILE" "tool")" "hash-tool-1"
is "and still writes the header it came for"        "$(state_get "${PROJ}" trellis)" "paused"

# Disabling a feature twice must not destroy what the first disable saved —
# that archive is the only copy of the user's own edits.
ARCH="${WORK}/arch"
mkdir -p "${ARCH}"
printf 'first\n' > "${ARCH}/codex-run.md"
arch1="$(archive_disabled "${ARCH}/codex-run.md")"
printf 'second\n' > "${ARCH}/codex-run.md"
arch2="$(archive_disabled "${ARCH}/codex-run.md")"
is "the first archive takes the plain name" "$(basename -- "${arch1}")" "codex-run.md.disabled"
is "a second archive steps aside"           "$(basename -- "${arch2}")" "codex-run.md.disabled.2"
is "so the first archive survives"          "$(cat "${ARCH}/codex-run.md.disabled")" "first"

# Enabling CC-Workflow must not overwrite a codex-run.md the user already
# carries. Theirs wins and the tool's copy lands beside it, the same contract
# every other managed file gets.
CCP="${WORK}/ccproj"
mkdir -p "${CCP}/.claude/agents"
printf 'mine\n' > "${CCP}/.claude/agents/codex-run.md"
(
  ask_yes_no() { true; }
  ensure_dir() { mkdir -p "$1"; }
  toggle_cc_workflow "${CCP}"
) >/dev/null 2>&1
is "enabling keeps the user's own subagent" "$(cat "${CCP}/.claude/agents/codex-run.md")" "mine"
if [[ -f "${CCP}/.claude/agents/codex-run.md.template" ]]; then
  ok "and leaves the tool's copy as .template"
else
  ko "and leaves the tool's copy as .template" "no .template beside it"
fi

is "an untracked project reports no version" "$(state_get "${WORK}" version)" ""
if state_is_tracked "${WORK}"; then ko "a project with no manifest is untracked" "reported tracked"; else ok "a project with no manifest is untracked"; fi

# --- .gitignore -------------------------------------------------------------
# The manifest is local bookkeeping, so a git-tracked project must ignore it —
# and asking twice must not append the entry twice.
GITPROJ="${WORK}/gitproj"
mkdir -p "${GITPROJ}"
git -C "${GITPROJ}" init -q 2>/dev/null
printf 'node_modules/\n' > "${GITPROJ}/.gitignore"
ensure_state_gitignored "${GITPROJ}"
ensure_state_gitignored "${GITPROJ}"
is    "the state dir is ignored exactly once" \
  "$(grep -cxF '.vibe-init/' "${GITPROJ}/.gitignore")" "1"
has   "the user's own .gitignore lines survive" "$(cat "${GITPROJ}/.gitignore")" "node_modules/"

NOGIT="${WORK}/nogit"
mkdir -p "${NOGIT}"
ensure_state_gitignored "${NOGIT}"
if [[ -e "${NOGIT}/.gitignore" ]]; then ko "a non-repo gets no .gitignore" "created one"; else ok "a non-repo gets no .gitignore"; fi

# --- a run with nothing to record still writes the manifest -----------------
# An old project whose every file needs review or a format conversion stages no
# record at all, and state_flush used to return before writing anything — so
# the project that most needs a merge base never got a .vibe-init/.
EMPTYPROJ="${WORK}/emptyproj"
mkdir -p "${EMPTYPROJ}"
STATE_RECORDS=()
state_flush "${EMPTYPROJ}"
if [[ -f "${EMPTYPROJ}/.vibe-init/manifest" ]]; then
  ok "a flush with no records still writes the manifest"
else
  ko "a flush with no records still writes the manifest" "no manifest"
fi

# A run can stage one key twice: the base a finished merge promotes, then what
# the sync itself found. Two lines would leave the lookup to sort order.
STATE_RECORDS=()
state_record_block "AGENTS.md" "CORE_RULES" "" "hash-second"
state_record_block "AGENTS.md" "CORE_RULES" "" "hash-first"
state_flush "${EMPTYPROJ}"
is "a key staged twice keeps the later record" \
  "$(state_block_hash "${EMPTYPROJ}" "AGENTS.md" "CORE_RULES" "")" "hash-first"
is "and writes it once" \
  "$(grep -c "^block	AGENTS.md	CORE_RULES" "${EMPTYPROJ}/.vibe-init/manifest")" "1"

STATE_SET_TRELLIS="paused"
state_flush "${EMPTYPROJ}"
STATE_SET_TRELLIS=""
state_flush "${EMPTYPROJ}"
is "the Trellis state survives a flush that does not set it" \
  "$(state_get "${EMPTYPROJ}" trellis)" "paused"

# --- a merge finished outside the tool becomes the merge base ---------------
# The agent merges; the only signal that comes back is it deleting the
# .template. Without acting on that, a block the user kept their own way had no
# base and read "review" on every run, forever.
MB_SET="${WORK}/mb-set"
materialize_template_set "${MB_SET}" "ask" "" 0
TEMPLATE_DIR="${MB_SET}"
TEMPLATE_FILES=("AGENTS.md" ".claude/settings.json")
TEMPLATE_SET_LABEL="test"
MBPROJ="${WORK}/mbproj"
mkdir -p "${MBPROJ}/.claude"
awk '/^<\/CORE_RULES>/ { print "- a rule of my own" } { print }' \
  "${MB_SET}/AGENTS.md" > "${MBPROJ}/AGENTS.md"
cp "${MB_SET}/.claude/settings.json" "${MBPROJ}/.claude/settings.json"
STATE_RECORDS=()

sync_run "${MBPROJ}" plan "${TEMPLATE_FILES[@]}"
is "with no base, an edited block needs review" "${SYNC_N_REVIEW}" "1"

sync_run "${MBPROJ}" apply "AGENTS.md" 2>/dev/null
if [[ -f "$(state_pending_path "${MBPROJ}" "AGENTS.md")" ]]; then
  ok "handing out a .template keeps the template it was"
else
  ko "handing out a .template keeps the template it was" "nothing under pending/"
fi
sync_run "${MBPROJ}" plan "${TEMPLATE_FILES[@]}"
is "while the .template is there the merge is still open" "${SYNC_N_REVIEW}" "1"

rm -f "${MBPROJ}/AGENTS.md.template"
sync_run "${MBPROJ}" plan "${TEMPLATE_FILES[@]}"
is "once the agent deletes it, the plan reads the merge as done" "${SYNC_N_REVIEW}" "0"

# Nothing is selectable now, so this is the path that used to record nothing.
ASSUME_DEFAULTS=1
apply_templates "${MBPROJ}" 2>/dev/null
ASSUME_DEFAULTS=0
is "the finished merge's template becomes the recorded base" \
  "$(state_block_hash "${MBPROJ}" "AGENTS.md" "CORE_RULES" "")" \
  "$(hash_block "${MB_SET}/AGENTS.md" "CORE_RULES")"
if [[ -e "$(state_pending_path "${MBPROJ}" "AGENTS.md")" ]]; then
  ko "and the kept copy is forgotten" "still under pending/"
else
  ok "and the kept copy is forgotten"
fi
is "a file identical to the template is adopted though never offered" \
  "$(state_file_hash "${MBPROJ}" ".claude/settings.json")" \
  "$(hash_file "${MB_SET}/.claude/settings.json")"
sync_run "${MBPROJ}" plan "${TEMPLATE_FILES[@]}"
is "later runs stay quiet" "${SYNC_N_REVIEW}" "0"

awk '/^<\/CORE_RULES>/ { print "- a new upstream rule" } { print }' \
  "${MB_SET}/AGENTS.md" > "${WORK}/mb-moved" && mv "${WORK}/mb-moved" "${MB_SET}/AGENTS.md"
sync_run "${MBPROJ}" plan "${TEMPLATE_FILES[@]}"
is "when the template moves again, both sides moved" "${SYNC_N_REVIEW}" "1"

# An old project: its AGENTS.md needs a format conversion and its settings file
# already matches. The sync that selects AGENTS.md must still adopt the other.
materialize_template_set "${MB_SET}" "ask" "" 0
OLDPROJ="${WORK}/oldproj"
mkdir -p "${OLDPROJ}/.claude"
printf '# AGENTS\n\n## Rules\nold rules\n' > "${OLDPROJ}/AGENTS.md"
cp "${MB_SET}/.claude/settings.json" "${OLDPROJ}/.claude/settings.json"
STATE_RECORDS=()
ASSUME_DEFAULTS=1
apply_templates "${OLDPROJ}" 2>/dev/null
ASSUME_DEFAULTS=0
if [[ -f "${OLDPROJ}/.vibe-init/manifest" ]]; then
  ok "an old project gets a manifest on its first sync"
else
  ko "an old project gets a manifest on its first sync" "no manifest"
fi
is "the matching file beside a selected one is adopted" \
  "$(state_file_hash "${OLDPROJ}" ".claude/settings.json")" \
  "$(hash_file "${MB_SET}/.claude/settings.json")"
if [[ -f "${OLDPROJ}/AGENTS.md.template" && ! -e "$(state_pending_path "${OLDPROJ}" "AGENTS.md")" ]]; then
  ok "a format conversion keeps no template: its merge is the next round"
else
  ko "a format conversion keeps no template: its merge is the next round" "pending copy written"
fi

# --- pausing, restoring and uninstalling Trellis ----------------------------
# Mid-project, .trellis/ holds tasks, specs, journals and memory. Pausing is
# Trellis's own reversible `ablate`; uninstalling deletes the lot, so it asks
# first when git could not give the work back. None of them pass --yes.
TR_BIN="${WORK}/trbin"
mkdir -p "${TR_BIN}"
cat > "${TR_BIN}/trellis" <<'FAKE'
#!/usr/bin/env bash
# TR_DECLINE=1 stands for the user saying no at Trellis's own prompt.
[[ "$1" == "--version" ]] && { echo "0.6.16"; exit 0; }
echo "RAN trellis $*"
[[ "${TR_DECLINE:-0}" == 1 ]] && exit 1
case "$1" in
  ablate)    mv .trellis .trellis-ablated ;;
  restore)   mv .trellis-ablated .trellis ;;
  uninstall) rm -rf .trellis ;;
esac
FAKE
chmod +x "${TR_BIN}/trellis"

# trellis_ops <project_dir> <yes|no> <menu choice, or "" for the default> <code>
# Runs <code> with the libraries loaded and the fake CLI on PATH. Every
# confirmation answers <yes|no>; the first menu answers the choice and any later
# one "back", so a loop cannot spin.
trellis_ops() {
  rm -f "${WORK}/tr-selected"
  TR_PROJ="$1" TR_ANSWER="$2" TR_SELECT="$3" TR_WORK="${WORK}" TR_REPO="${REPO_ROOT}" \
    TR_DECLINE="${TR_DECLINE:-0}" PATH="${TR_BIN}:${PATH}" bash -c '
    set -uo pipefail
    SCRIPT_DIR="${TR_WORK}"
    TEMPLATE_ROOT="${TR_REPO}/templates"
    DRY_RUN=0; ASSUME_DEFAULTS=0; VIBE_INIT_VERSION="test"
    CC_WORKFLOW_ENABLED=0; TEMPLATE_INTEGRATIONS="trellis"
    info() { printf "[test] %s\n" "$*" >&2; }
    warn() { printf "[test] warning: %s\n" "$*" >&2; }
    for lib in ui prompt block_engine state sync trellis apply; do
      . "${TR_REPO}/lib/${lib}.sh"
    done
    run_in_dir() { local d="$1"; shift; (cd "${d}" && "$@"); }
    prepare_template_set() { :; }
    resolve_trellis_setup() { printf "INIT\n" >&2; TRELLIS_READY=0; }
    ask_yes_no() { printf "ASKED %s\n" "$1" >&2; [[ "${TR_ANSWER}" == yes ]]; }
    ui_select() {
      if [[ -e "${TR_WORK}/tr-selected" ]]; then printf "back\n"; return; fi
      : > "${TR_WORK}/tr-selected"
      printf "%s\n" "${TR_SELECT:-$2}"
    }
    eval "$1"
  ' _ "$4" 2>&1
}
trellis_ran() { printf '%s\n' "$1" | grep '^RAN trellis' || true; }

# A project mid-work: a task, and the integration block in AGENTS.md.
TRP="${WORK}/trpause"
mkdir -p "${TRP}/.trellis/tasks/t1"
printf 'decisions\n' > "${TRP}/.trellis/tasks/t1/prd.md"
{ printf '<CORE_RULES>\nrules\n</CORE_RULES>\n\n'; cat "${TEMPLATE_ROOT}/blocks/integrations/trellis.md"; } \
  > "${TRP}/AGENTS.md"

TR_DECLINE=1
out="$(trellis_ops "${TRP}" yes pause 'manage_trellis "${TR_PROJ}"')"
TR_DECLINE=0
if [[ -d "${TRP}/.trellis" ]] && [[ "$(state_get "${TRP}" trellis)" != "paused" ]]; then
  ok "declining at Trellis's prompt records no pause"
else
  ko "declining at Trellis's prompt records no pause" "recorded or moved"
fi
hasnt "and asks nothing about the block" "${out}" "ASKED Remove the Trellis integration block"

out="$(trellis_ops "${TRP}" yes pause 'manage_trellis "${TR_PROJ}"')"
is    "pause runs trellis ablate, leaving the confirmation to Trellis" "$(trellis_ran "${out}")" "RAN trellis ablate"
is    "and records the project as paused" "$(state_get "${TRP}" trellis)" "paused"
if has_block "${TRP}/AGENTS.md" "INTEGRATION" "trellis"; then
  ko "the integration block goes when the user agrees" "still there"
else
  ok "the integration block goes when the user agrees"
fi

has "a paused project reads paused in the menu" \
  "$(trellis_ops "${TRP}" no "" 'trellis_menu_note "${TR_PROJ}"')" "paused"
has "and on the diagnostics card" \
  "$(trellis_ops "${TRP}" no "" 'show_project_diagnostics "${TR_PROJ}"')" "Paused"

out="$(trellis_ops "${TRP}" yes "" 'manage_trellis "${TR_PROJ}"')"
is "a paused project's Trellis menu leads with restore" "$(trellis_ran "${out}")" "RAN trellis restore"
if [[ -f "${TRP}/.trellis/tasks/t1/prd.md" ]]; then ok "restore brings the work back"; else ko "restore brings the work back" "no prd.md"; fi
is "and records the project as active" "$(state_get "${TRP}" trellis)" "active"
if has_block "${TRP}/AGENTS.md" "INTEGRATION" "trellis"; then
  ok "and offers the integration block back"
else
  ko "and offers the integration block back" "block not re-added"
fi

NEVER="${WORK}/trnever"
mkdir -p "${NEVER}"
# Once the sync has nothing left, this submenu is the dashboard's default row,
# so its own default must not be an init: Enter three times wrote a Trellis tree.
hasnt "a project that never had Trellis does not default to init" \
  "$(trellis_ops "${NEVER}" no "" 'manage_trellis "${TR_PROJ}"')" "INIT"
has "but init is still one choice away" \
  "$(trellis_ops "${NEVER}" no init 'manage_trellis "${TR_PROJ}"')" "INIT"

# Uninstall: uncommitted work outside git asks first, and no means nothing runs.
if trellis_has_unprotected_data "${TRP}"; then
  ok "work outside a git repository is unprotected"
else
  ko "work outside a git repository is unprotected" "reported protected"
fi
out="$(trellis_ops "${TRP}" no uninstall 'manage_trellis "${TR_PROJ}"')"
has   "uninstalling unprotected work asks first" "${out}" "ASKED Uninstall and delete them anyway?"
is    "and declining runs nothing" "$(trellis_ran "${out}")" ""
if [[ -d "${TRP}/.trellis" ]]; then ok "and deletes nothing"; else ko "and deletes nothing" ".trellis is gone"; fi

out="$(trellis_ops "${TRP}" yes uninstall 'manage_trellis "${TR_PROJ}"')"
is "agreeing runs trellis uninstall without --yes" "$(trellis_ran "${out}")" "RAN trellis uninstall"
is "and records Trellis as gone" "$(state_get "${TRP}" trellis)" "none"

GITTR="${WORK}/trgit"
mkdir -p "${GITTR}/.trellis/tasks/t1"
printf 'decisions\n' > "${GITTR}/.trellis/tasks/t1/prd.md"
git -C "${GITTR}" init -q
git -C "${GITTR}" add -A
git -C "${GITTR}" -c user.name=t -c user.email=t@example.com commit -qm init
if trellis_has_unprotected_data "${GITTR}"; then
  ko "committed work is protected" "reported unprotected"
else
  ok "committed work is protected"
fi
hasnt "so uninstalling it does not ask" \
  "$(trellis_ops "${GITTR}" no uninstall 'trellis_uninstall_project "${TR_PROJ}"')" "ASKED"
git -C "${GITTR}" checkout -q -- .trellis
mkdir -p "${GITTR}/.trellis/workspace"
printf 'journal\n' > "${GITTR}/.trellis/workspace/journal.md"
printf '.trellis/workspace/\n' > "${GITTR}/.gitignore"
if trellis_has_unprotected_data "${GITTR}"; then
  ok "ignored work under .trellis/ is unprotected"
else
  ko "ignored work under .trellis/ is unprotected" "reported protected"
fi

# What still points at Trellis once it has gone.
CCTR="${WORK}/trcc"
mkdir -p "${CCTR}"
cp "${TEMPLATE_ROOT}/blocks/features/cc-workflow/trellis.md" "${CCTR}/CC-Cowork-Workflow.md"
has "a Trellis-variant workflow document is named" \
  "$(trellis_ops "${CCTR}" no "" 'after_trellis_left "${TR_PROJ}"')" "still describes the Trellis co-work loop"
cp "${TEMPLATE_ROOT}/blocks/features/cc-workflow/base.md" "${CCTR}/CC-Cowork-Workflow.md"
hasnt "the plain variant is not" \
  "$(trellis_ops "${CCTR}" no "" 'after_trellis_left "${TR_PROJ}"')" "co-work loop"

# Removing the block alone leaves Trellis set up; the toggle says so.
mkdir -p "${TRP}/.trellis"
cat "${TEMPLATE_ROOT}/blocks/integrations/trellis.md" >> "${TRP}/AGENTS.md"
has "the block toggle says Trellis itself stays" \
  "$(trellis_ops "${TRP}" no "" 'toggle_trellis_integration "${TR_PROJ}"')" "Trellis itself stays set up"

echo
if [[ "${FAIL}" -eq 0 ]]; then
  printf 'PASS — %d assertions, 0 failures\n' "${PASS}"
  exit 0
fi
printf 'FAIL — %d failed, %d passed\n' "${FAIL}" "${PASS}"
exit 1
