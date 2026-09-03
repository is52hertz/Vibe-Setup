#!/usr/bin/env bash
# lib/ui.sh — colors, semantic symbols and the dashboard box.
#
# Sourced by vibe-init.sh and lib/apply.sh. Both run under `set -euo pipefail`,
# so every variable this file defines must be defined on *every* branch: a name
# that only exists in the color branch takes the whole script down with an
# "unbound variable" the moment output is piped or NO_COLOR is set.
#
# Compatible with macOS Bash 3.2.

# Color is for a human at a terminal. Anything else — a pipe, a file, NO_COLOR,
# TERM=dumb — gets plain ASCII that greps and diffs cleanly.
UI_COLOR_ENABLED=0
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  UI_COLOR_ENABLED=1
fi

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

  UI_SYM_OK="${UI_GREEN}✓${UI_RESET}"
  UI_SYM_INFO="${UI_CYAN}ℹ${UI_RESET}"
  UI_SYM_WARN="${UI_YELLOW}⚠${UI_RESET}"
  UI_SYM_ERR="${UI_RED}✗${UI_RESET}"
  UI_SYM_DOT="${UI_DIM}○${UI_RESET}"
  UI_SYM_ARROW="${UI_CYAN}➜${UI_RESET}"

  UI_BOX_TL="┌"
  UI_BOX_TR="┐"
  UI_BOX_BL="└"
  UI_BOX_BR="┘"
  UI_BOX_H="─"
  UI_BOX_V="│"
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

  UI_SYM_OK="[OK]"
  UI_SYM_INFO="[i]"
  UI_SYM_WARN="[!]"
  UI_SYM_ERR="[X]"
  UI_SYM_DOT="[-]"
  UI_SYM_ARROW="->"

  UI_BOX_TL="+"
  UI_BOX_TR="+"
  UI_BOX_BL="+"
  UI_BOX_BR="+"
  UI_BOX_H="-"
  UI_BOX_V="|"
fi

# Inner width of the dashboard box, shared by all three of its rows so the
# borders actually line up: content is UI_BOX_WIDTH columns between the two
# verticals, split into two leading spaces, the label, " : ", and the value.
UI_BOX_WIDTH=62
UI_BOX_LABEL_WIDTH=18
UI_BOX_VALUE_WIDTH=$(( UI_BOX_WIDTH - UI_BOX_LABEL_WIDTH - 5 ))

_ui_repeat() {
  local ch="$1"
  local n="$2"
  local out=""

  while (( n-- > 0 )); do
    out="${out}${ch}"
  done
  printf '%s' "${out}"
}

# Force a value onto one line and into a fixed width. A newline inside a box row
# splits the border across two lines, and `git rev-parse` on a repository with no
# commits is exactly the kind of thing that returns two lines.
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

ui_banner() {
  local subtitle="${1:-AI-Assisted Engineering Environment Toolkit}"

  printf '\n%s%s✦ vibe-init%s %s%s%s\n' \
    "${UI_BOLD}" "${UI_CYAN}" "${UI_RESET}" "${UI_DIM}" "${subtitle}" "${UI_RESET}" >&2
  printf '%s%s%s\n\n' "${UI_DIM}" "$(_ui_repeat "${UI_BOX_H}" 60)" "${UI_RESET}" >&2
}

ui_section() {
  printf '\n%s%s=== %s ===%s\n' "${UI_BOLD}" "${UI_CYAN}" "$1" "${UI_RESET}" >&2
}

ui_ok()    { printf '  %s %s\n' "${UI_SYM_OK}" "$*" >&2; }
ui_info()  { printf '  %s %s\n' "${UI_SYM_INFO}" "$*" >&2; }
ui_warn()  { printf '  %s %s%s%s\n' "${UI_SYM_WARN}" "${UI_YELLOW}" "$*" "${UI_RESET}" >&2; }
ui_error() { printf '  %s %s%s%s\n' "${UI_SYM_ERR}" "${UI_RED}" "$*" "${UI_RESET}" >&2; }

ui_item() {
  printf '  %s %s%s%s %s\n' \
    "${UI_SYM_ARROW}" "${UI_BOLD}" "$(_ui_cell "$1:" "${UI_BOX_LABEL_WIDTH}")" "${UI_RESET}" "$2" >&2
}

# A single-line-border status card:
#   ui_box_start "Title"
#   ui_box_row "Label" "Value"
#   ui_box_end
ui_box_start() {
  local title=" $1 "
  local fill=$(( UI_BOX_WIDTH - ${#title} - 1 ))

  (( fill < 0 )) && fill=0
  printf '%s%s%s%s%s%s%s%s%s\n' \
    "${UI_CYAN}" "${UI_BOX_TL}" "${UI_BOX_H}" \
    "${UI_BOLD}${UI_WHITE}" "${title}" "${UI_RESET}${UI_CYAN}" \
    "$(_ui_repeat "${UI_BOX_H}" "${fill}")" "${UI_BOX_TR}" "${UI_RESET}" >&2
}

ui_box_row() {
  printf '%s%s%s  %s%s%s : %s%s%s%s\n' \
    "${UI_CYAN}" "${UI_BOX_V}" "${UI_RESET}" \
    "${UI_BOLD}" "$(_ui_cell "$1" "${UI_BOX_LABEL_WIDTH}")" "${UI_RESET}" \
    "$(_ui_cell "$2" "${UI_BOX_VALUE_WIDTH}")" \
    "${UI_CYAN}" "${UI_BOX_V}" "${UI_RESET}" >&2
}

ui_box_end() {
  printf '%s%s%s%s%s\n' \
    "${UI_CYAN}" "${UI_BOX_BL}" "$(_ui_repeat "${UI_BOX_H}" "${UI_BOX_WIDTH}")" \
    "${UI_BOX_BR}" "${UI_RESET}" >&2
}
