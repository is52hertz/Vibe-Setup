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

# --- a hint's state token is highlighted, the rest is context ---------------
# A toggle is the one entry where a mis-keyed Enter changes something, so its
# state has to be visible in the menu, not only in the card above it.
hint_row="$(bash -c '
  set -euo pipefail
  . "'"${REPO_ROOT}"'/lib/ui.sh"
  . "'"${REPO_ROOT}"'/lib/prompt.sh"
  UI_RICH=1; UI_DIM="<d>"; UI_RESET="<r>"; UI_GREEN="<g>"; UI_CYAN="<c>"
  UI_G_BAR="|"; UI_S_ON="*"; UI_S_OFF="o"
  _prompt_draw_options 0 "$(prompt_opt integ "Toggle Trellis block" "(on) in AGENTS.md" ok)"
' 2>&1)"
has "the state token takes the level color" "${hint_row}" "<g>(on)<r>"
has "the rest of the hint stays dim"        "${hint_row}" "<d>in AGENTS.md<r>"

no_token="$(bash -c '
  set -euo pipefail
  . "'"${REPO_ROOT}"'/lib/ui.sh"
  . "'"${REPO_ROOT}"'/lib/prompt.sh"
  UI_RICH=1; UI_DIM="<d>"; UI_RESET="<r>"; UI_YELLOW="<y>"
  UI_G_BAR="|"; UI_S_ON="*"; UI_S_OFF="o"
  _prompt_draw_options 0 "$(prompt_opt sync "Sync template files" "2 to review" todo)"
' 2>&1)"
has "a hint with no token is colored whole" "${no_token}" "<y>2 to review<r>"

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
  "$(menu_order "${MENUPROJ}")" "trellis ccflow integ sync syncall quit "

SYNC_N_REVIEW=2
is "with work to do, sync leads the menu" \
  "$(menu_order "${MENUPROJ}")" "sync trellis ccflow integ syncall quit "
SYNC_N_REVIEW=0

# Each toggle reports the state the project is actually in.
_prompt_split "$(dashboard_actions "${MENUPROJ}" "" "" | grep -F 'ccflow')"
is "an absent workflow file reads off" "${PROMPT_HINT}" "(off) CC-Cowork-Workflow.md"
printf 'workflow\n' > "${MENUPROJ}/CC-Cowork-Workflow.md"
printf '<INTEGRATION id="trellis">\nx\n</INTEGRATION>\n' > "${MENUPROJ}/AGENTS.md"
_prompt_split "$(dashboard_actions "${MENUPROJ}" "" "" | grep -F 'ccflow')"
is "a present workflow file reads on"  "${PROMPT_HINT}" "(on) CC-Cowork-Workflow.md"
_prompt_split "$(dashboard_actions "${MENUPROJ}" "" "" | grep -F 'integ')"
is "the Trellis block reports itself present" "${PROMPT_HINT}" "(on) in AGENTS.md"

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

echo
if [[ "${FAIL}" -eq 0 ]]; then
  printf 'PASS — %d assertions, 0 failures\n' "${PASS}"
  exit 0
fi
printf 'FAIL — %d failed, %d passed\n' "${FAIL}" "${PASS}"
exit 1
