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

echo
if [[ "${FAIL}" -eq 0 ]]; then
  printf 'PASS — %d assertions, 0 failures\n' "${PASS}"
  exit 0
fi
printf 'FAIL — %d failed, %d passed\n' "${FAIL}" "${PASS}"
exit 1
