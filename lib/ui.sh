#!/usr/bin/env bash
# lib/ui.sh — the visual language: colors, glyphs, and the gutter layout.
#
# Sourced by vibe-init.sh and lib/apply.sh. Everything is written to stderr, so
# stdout stays clean for command substitution (ask_value and friends echo their
# result there).
#
# Two renderings of the same messages:
#
#   Rich   — a human at a terminal. A left gutter threads the whole run together
#            (┌ at the start, │ down the side, └ at the end), the way a modern
#            scaffolder reads. Steps, prompts and results all hang off it.
#   Plain  — a pipe, a file, NO_COLOR, TERM=dumb. The familiar `[vibe-init] …`
#            lines, one per message, which scripts and the test suite parse.
#
# The message bodies are identical in both; only the frame changes.
#
# Both callers run under `set -euo pipefail`, so every variable defined in one
# branch below must be defined in the other too — a name that exists only in the
# rich branch takes the whole script down with an "unbound variable" the first
# time output is piped.
#
# Compatible with macOS Bash 3.2.

# Color and layout are decided together: a caller that asked for no color (or is
# not a terminal) gets the plain frame as well. Detection looks at stderr, since
# that is where all of this goes.
UI_COLOR_ENABLED=0
if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  UI_COLOR_ENABLED=1
fi
UI_RICH="${UI_COLOR_ENABLED}"

if [[ "${UI_COLOR_ENABLED}" -eq 1 ]]; then
  UI_RESET=$'\033[0m'
  UI_BOLD=$'\033[1m'
  UI_DIM=$'\033[2m'
  UI_RED=$'\033[31m'
  UI_GREEN=$'\033[32m'
  UI_YELLOW=$'\033[33m'
  UI_BLUE=$'\033[34m'
  UI_MAGENTA=$'\033[35m'
  UI_CYAN=$'\033[36m'
  UI_WHITE=$'\033[37m'

  # The gutter, drawn dim so the content reads first.
  UI_G_TOP="┌"
  UI_G_BAR="│"
  UI_G_END="└"

  UI_S_STEP="◇"      # a settled step
  UI_S_ACTIVE="◆"    # the question being asked
  UI_S_OK="✓"
  UI_S_WARN="▲"
  UI_S_ERR="■"
  UI_S_ON="●"        # selected option
  UI_S_OFF="○"       # unselected option
  UI_S_CHECKED="■"   # ticked box in a multi-select
  UI_S_UNCHECKED="□"

  UI_RULE="─"        # fences a copy-me block
else
  UI_RESET=""
  UI_BOLD=""
  UI_DIM=""
  UI_RED=""
  UI_GREEN=""
  UI_YELLOW=""
  UI_BLUE=""
  UI_MAGENTA=""
  UI_CYAN=""
  UI_WHITE=""

  UI_G_TOP="+"
  UI_G_BAR="|"
  UI_G_END="+"

  UI_S_STEP="*"
  UI_S_ACTIVE="*"
  UI_S_OK="v"
  UI_S_WARN="!"
  UI_S_ERR="x"
  UI_S_ON="(*)"
  UI_S_OFF="( )"
  UI_S_CHECKED="[x]"
  UI_S_UNCHECKED="[ ]"

  UI_RULE="-"
fi

# Prefix for plain-mode lines. Unchanged from the original output format: scripts
# and test/dry-run.sh match on what follows it.
UI_PLAIN_PREFIX="[vibe-init]"

# Default width of the label column in key/value rows.
UI_LABEL_WIDTH=16
# Wider column for rows labelled with a file path.
UI_PATH_WIDTH=38

_ui_repeat() {
  local ch="$1"
  local n="$2"
  local out=""

  while (( n-- > 0 )); do
    out="${out}${ch}"
  done
  printf '%s' "${out}"
}

# Flatten a value onto one line and pad it to a fixed width. Newlines are the
# hazard here: `git rev-parse` on a repository with no commits returns two lines,
# and one of those in a status row breaks the layout.
_ui_cell() {
  local text="$1"
  local width="$2"

  text="${text//$'\n'/ }"
  text="${text//$'\r'/ }"
  text="${text//$'\t'/ }"

  if (( ${#text} > width )); then
    text="${text:0:width - 3}..."
  fi
  printf '%s%s' "${text}" "$(_ui_repeat " " $(( width - ${#text} )))"
}

# One line hanging off the gutter, or one plain-prefixed line.
_ui_emit() {
  if [[ "${UI_RICH}" -eq 1 ]]; then
    printf '%s%s%s  %s\n' "${UI_DIM}" "${UI_G_BAR}" "${UI_RESET}" "$1" >&2
  else
    printf '%s %s\n' "${UI_PLAIN_PREFIX}" "$1" >&2
  fi
}

# Open the run. In plain mode this is a single ordinary line, so nothing that
# parses the output has to know about the frame.
ui_intro() {
  local title="$1"
  local subtitle="${2:-}"

  if [[ "${UI_RICH}" -ne 1 ]]; then
    if [[ -n "${subtitle}" ]]; then
      printf '%s %s — %s\n' "${UI_PLAIN_PREFIX}" "${title}" "${subtitle}" >&2
    else
      printf '%s %s\n' "${UI_PLAIN_PREFIX}" "${title}" >&2
    fi
    return
  fi

  printf '\n%s%s%s  %s%s%s' \
    "${UI_DIM}" "${UI_G_TOP}" "${UI_RESET}" "${UI_BOLD}${UI_CYAN}" "${title}" "${UI_RESET}" >&2
  if [[ -n "${subtitle}" ]]; then
    printf '  %s%s%s' "${UI_DIM}" "${subtitle}" "${UI_RESET}" >&2
  fi
  printf '\n' >&2
}

# Close the run.
ui_outro() {
  if [[ "${UI_RICH}" -ne 1 ]]; then
    printf '%s %s\n' "${UI_PLAIN_PREFIX}" "$1" >&2
    return
  fi

  ui_gap
  printf '%s%s%s  %s%s%s\n\n' \
    "${UI_DIM}" "${UI_G_END}" "${UI_RESET}" "${UI_BOLD}" "$1" "${UI_RESET}" >&2
}

# A bare gutter line, for breathing room between steps. Nothing in plain mode.
ui_gap() {
  [[ "${UI_RICH}" -eq 1 ]] || return 0
  printf '%s%s%s\n' "${UI_DIM}" "${UI_G_BAR}" "${UI_RESET}" >&2
}

# A settled step: the question, then the answer under it. The breathing room goes
# *before* a prompt rather than after an answer, so log lines emitted between two
# questions stay attached to the step they came from.
ui_step() {
  local label="$1"
  local value="${2:-}"

  if [[ "${UI_RICH}" -ne 1 ]]; then
    if [[ -n "${value}" ]]; then
      printf '%s %s: %s\n' "${UI_PLAIN_PREFIX}" "${label}" "${value}" >&2
    else
      printf '%s %s\n' "${UI_PLAIN_PREFIX}" "${label}" >&2
    fi
    return
  fi

  printf '%s%s%s  %s%s%s\n' \
    "${UI_DIM}" "${UI_S_STEP}" "${UI_RESET}" "${UI_BOLD}" "${label}" "${UI_RESET}" >&2
  if [[ -n "${value}" ]]; then
    printf '%s%s%s  %s%s%s\n' \
      "${UI_DIM}" "${UI_G_BAR}" "${UI_RESET}" "${UI_CYAN}" "${value}" "${UI_RESET}" >&2
  fi
}

# A heading for a group of rows or log lines. Like a prompt, it opens with a
# blank gutter line so it separates from whatever came before it.
ui_section() {
  if [[ "${UI_RICH}" -ne 1 ]]; then
    printf '%s %s\n' "${UI_PLAIN_PREFIX}" "$1" >&2
    return
  fi
  ui_gap
  printf '%s%s%s  %s%s%s\n' \
    "${UI_DIM}" "${UI_S_STEP}" "${UI_RESET}" "${UI_BOLD}" "$1" "${UI_RESET}" >&2
}

# An aligned label/value row inside a section. The label column defaults to
# UI_LABEL_WIDTH; pass a third argument where the labels are longer (file paths,
# say) so they are not truncated into uselessness.
ui_kv() {
  local label="$1"
  local value="$2"
  local width="${3:-${UI_LABEL_WIDTH}}"

  if [[ "${UI_RICH}" -ne 1 ]]; then
    printf '%s   %s %s\n' "${UI_PLAIN_PREFIX}" "$(_ui_cell "${label}" "${width}")" "${value}" >&2
    return
  fi
  printf '%s%s%s   %s%s%s %s\n' \
    "${UI_DIM}" "${UI_G_BAR}" "${UI_RESET}" \
    "${UI_DIM}" "$(_ui_cell "${label}" "${width}")" "${UI_RESET}" "${value}" >&2
}

# The semantic state levels, and the color each one reads as. Color encodes
# what KIND of state a value is, never what the word happens to say, so the
# vocabulary can grow without the palette drifting:
#
#   ok      green   ready, in use, current            Active, Initialized
#   info    cyan    a neutral identifier, not a state Modern, a version, a list
#   todo    yellow  works, but there is work to do    Legacy, Not initialized
#   off     dim     deliberately off, or absent       Disabled, None
#   bad     red     broken or blocking                Missing, CLI not installed
#   neutral none    plain, carrying no judgment       a toggle reading "off"
#
# "neutral" exists for a value that has to be READ rather than judged. A
# toggle's "off" is the case: it is a legitimate state, so red or yellow would
# libel it, but dim would hide the very thing the reader is checking. Left at
# the default foreground it stands out against a column that is otherwise all
# dim, without claiming anything is wrong.
#
# "off" is dim rather than red on purpose. CC-Workflow is off in most projects
# by design, and painting the normal case red spends the one color that should
# mean "act now" — after a few runs the user stops seeing it, and the real
# failures stop landing. Red stays scarce.
#
# The color is redundant with the word itself in every row, so nothing is lost
# to a color-blind reader or a piped log.
_ui_state_color() {
  case "$1" in
    ok)      printf '%s' "${UI_GREEN}" ;;
    info)    printf '%s' "${UI_CYAN}" ;;
    todo)    printf '%s' "${UI_YELLOW}" ;;
    bad)     printf '%s' "${UI_RED}" ;;
    neutral) printf '' ;;
    off|*)   printf '%s' "${UI_DIM}" ;;
  esac
}

# A status row whose value is a state word plus optional detail:
#
#   Trellis          Active (Project v0.6.16 / CLI v0.6.16)
#                    ^^^^^^ level color      ^^^^^^^^^^^^^^ dim
#
# Splitting the two is what gives a dense card a reading order: the eye lands on
# the state and the version numbers recede. A row rendered as one flat color —
# which is what ui_kv alone could do — has no such order, and a whole card of
# them is the "grey and white wall" this replaces.
#
# Plain mode renders exactly what ui_kv would have printed, "<state> (<detail>)",
# byte for byte, so anything grepping the output is unaffected.
# Usage: ui_kv_state <label> <level> <state> [detail] [label_width]
ui_kv_state() {
  local label="$1"
  local level="$2"
  local state="$3"
  local detail="${4:-}"
  local width="${5:-${UI_LABEL_WIDTH}}"
  local value=""

  if [[ -n "${detail}" ]]; then
    value="${state} (${detail})"
  else
    value="${state}"
  fi

  if [[ "${UI_RICH}" -ne 1 ]]; then
    ui_kv "${label}" "${value}" "${width}"
    return
  fi

  value="$(_ui_state_color "${level}")${state}${UI_RESET}"
  if [[ -n "${detail}" ]]; then
    value="${value} ${UI_DIM}(${detail})${UI_RESET}"
  fi
  ui_kv "${label}" "${value}" "${width}"
}

# The four message levels. Plain mode keeps the exact wording the tool has always
# printed — "warning: " and "error: " included — so nothing that greps the output
# has to change.
#
# Info is drawn dim on purpose: these are progress lines — what was copied, what
# is being applied — and they sit under the section headings and status rows that
# the eye should land on first. Undimmed they competed with the content for
# attention and made a routine sync read like a wall of alarms.
ui_info() {
  if [[ "${UI_RICH}" -eq 1 ]]; then
    _ui_emit "${UI_DIM}$*${UI_RESET}"
  else
    _ui_emit "$*"
  fi
}

# ui_log is the older name for the same level; vibe-init.sh's info() and a good
# deal of lib/ call it, so both stay.
ui_log() { ui_info "$@"; }

ui_ok() {
  if [[ "${UI_RICH}" -eq 1 ]]; then
    _ui_emit "${UI_GREEN}${UI_S_OK}${UI_RESET} $*"
  else
    _ui_emit "$*"
  fi
}

ui_warn() {
  if [[ "${UI_RICH}" -eq 1 ]]; then
    _ui_emit "${UI_YELLOW}${UI_S_WARN} $*${UI_RESET}"
  else
    _ui_emit "warning: $*"
  fi
}

ui_error() {
  if [[ "${UI_RICH}" -eq 1 ]]; then
    _ui_emit "${UI_RED}${UI_S_ERR} $*${UI_RESET}"
  else
    _ui_emit "error: $*"
  fi
}

# Open and close a block the user is meant to select and copy out of the
# terminal verbatim — an agent prompt, say.
#
# Deliberately NOT hung off the gutter: a copy-paste must not pick up "│  "
# prefixes, so the body between these two rules is printed raw by the caller.
# The rules themselves are dim, because they are packaging rather than content
# — undimmed they read as the loudest thing on screen, which is backwards.
# Usage: ui_copy_open [title]; …the body…; ui_copy_close
ui_copy_open() {
  local title="${1:-}"
  local rule=""

  rule="$(_ui_repeat "${UI_RULE}" 10)"
  if [[ -n "${title}" ]]; then
    printf '%s%s %s %s%s\n' \
      "${UI_DIM}" "${rule}" "${title}" "${rule}" "${UI_RESET}" >&2
  else
    printf '%s%s%s\n' "${UI_DIM}" "$(_ui_repeat "${UI_RULE}" 56)" "${UI_RESET}" >&2
  fi
}

ui_copy_close() {
  printf '%s%s%s\n' "${UI_DIM}" "$(_ui_repeat "${UI_RULE}" 56)" "${UI_RESET}" >&2
}
