#!/usr/bin/env bash
# lib/ui.sh — Terminal UI, colors, boxes, and symbols.
# Compatible with macOS Bash 3.2. Sourced by vibe-init.sh and lib/apply.sh.

# Color & styling setup with automatic fallback.
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
  
  # Symbols
  UI_SYM_OK="${UI_GREEN}✓${UI_RESET}"
  UI_SYM_INFO="${UI_CYAN}ℹ${UI_RESET}"
  UI_SYM_WARN="${UI_YELLOW}⚠${UI_RESET}"
  UI_SYM_ERR="${UI_RED}✗${UI_RESET}"
  UI_SYM_DOT="${UI_DIM}○${UI_RESET}"
  UI_SYM_ARROW="${UI_CYAN}➜${UI_RESET}"
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

  # Plain ASCII symbols
  UI_SYM_OK="[OK]"
  UI_SYM_INFO="[i]"
  UI_WARN_SYM="[!]"
  UI_SYM_ERR="[X]"
  UI_SYM_DOT="[-]"
  UI_SYM_ARROW="->"
fi

ui_banner() {
  local subtitle="${1:-AI-Assisted Engineering Environment Toolkit}"
  printf '\n%s%s✦ vibe-init%s %s%s%s\n' "${UI_BOLD}" "${UI_CYAN}" "${UI_RESET}" "${UI_DIM}" "${subtitle}" "${UI_RESET}" >&2
  printf '%s%s%s\n\n' "${UI_DIM}" "────────────────────────────────────────────────────────────" "${UI_RESET}" >&2
}

ui_section() {
  local title="$1"
  printf '\n%s%s=== %s ===%s\n' "${UI_BOLD}" "${UI_CYAN}" "${title}" "${UI_RESET}" >&2
}

ui_ok() {
  printf '  %s %s\n' "${UI_SYM_OK}" "$*" >&2
}

ui_info() {
  printf '  %s %s\n' "${UI_SYM_INFO}" "$*" >&2
}

ui_warn() {
  printf '  %s %s%s%s\n' "${UI_SYM_WARN}" "${UI_YELLOW}" "$*" "${UI_RESET}" >&2
}

ui_error() {
  printf '  %s %s%s%s\n' "${UI_SYM_ERR}" "${UI_RED}" "$*" "${UI_RESET}" >&2
}

ui_item() {
  local label="$1"
  local val="$2"
  printf '  %s %s%-18s%s %s\n' "${UI_SYM_ARROW}" "${UI_BOLD}" "${label}:" "${UI_RESET}" "${val}" >&2
}

# Renders a formatted single-line border box for dashboard display.
# Usage:
#   ui_box_start "Title"
#   ui_box_row "Label" "Value"
#   ui_box_end
ui_box_start() {
  local title=" $1 "
  local line_len=62
  local title_len="${#title}"
  local dashes=$(( line_len - title_len - 3 ))
  local pad=""
  while (( dashes-- > 0 )); do pad="${pad}─"; done

  printf '%s┌─%s%s%s%s┐%s\n' "${UI_CYAN}" "${UI_BOLD}${UI_WHITE}" "${title}" "${UI_RESET}${UI_CYAN}" "${pad}" "${UI_RESET}" >&2
}

ui_box_row() {
  local label="$1"
  local value="$2"
  local formatted_label
  # Pad or trim label to 18 chars
  printf -v formatted_label '%-18s' "${label}"
  # Total inner width is 62 chars. Label (18) + separator (3) = 21. Value has ~40 chars.
  printf '%s│%s  %s%s%s : %-39s%s│%s\n' "${UI_CYAN}" "${UI_RESET}" "${UI_BOLD}" "${formatted_label}" "${UI_RESET}" "${value}" "${UI_CYAN}" "${UI_RESET}" >&2
}

ui_box_end() {
  local line_len=62
  local pad=""
  while (( line_len-- > 0 )); do pad="${pad}─"; done
  printf '%s└%s┘%s\n' "${UI_CYAN}" "${pad}" "${UI_RESET}" >&2
}
