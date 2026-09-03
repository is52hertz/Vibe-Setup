#!/usr/bin/env bash
# lib/prompt.sh — the interactive prompts: confirm, input, select.
#
# Sourced by vibe-init.sh after lib/ui.sh, which supplies the glyphs and colors.
# Drawing goes to stderr; the answer goes to stdout, so a caller can capture it
# with $(...) while the user still sees the prompt.
#
# Every prompt has three renderings, picked by what the caller can actually do:
#
#   rich          stdin is a terminal and stderr takes color: draw the selector
#   plain         stdin is a terminal but color is off (NO_COLOR, a redirect,
#                 TERM=dumb): the classic `question [default]: ` line, so the
#                 tool stays usable rather than silently answering itself
#   non-terminal  no stdin to read from: return the default, print nothing
#
# Whether to ask at all is the caller's decision (--yes is handled in ask_value
# and ask_yes_no), so these functions never second-guess it.
#
# The selector is written against Bash 3.2: no fractional `read -t`, no
# associative arrays, no mapfile. Arrow keys arrive as ESC [ A / ESC [ B, which
# is read as one byte plus two more rather than with a timeout, since 3.2's
# `read -t` only takes whole seconds.
#
# Options are passed as "value<US>label<US>hint" records, built with prompt_opt,
# so a label or hint can contain anything but the unit separator.

# ASCII unit separator: not something a label will ever contain.
PROMPT_US=$'\037'

# Build one option record: prompt_opt <value> <label> [hint]
prompt_opt() {
  printf '%s%s%s%s%s' "$1" "${PROMPT_US}" "$2" "${PROMPT_US}" "${3:-}"
}

# Split one record into PROMPT_VALUE / PROMPT_LABEL / PROMPT_HINT. Done with
# parameter expansion rather than awk: the selector re-splits every option on
# every keypress, and a fork per field would be felt.
PROMPT_VALUE=""
PROMPT_LABEL=""
PROMPT_HINT=""
_prompt_split() {
  local record="$1"
  local rest=""

  PROMPT_VALUE="${record%%${PROMPT_US}*}"
  rest="${record#*${PROMPT_US}}"
  PROMPT_LABEL="${rest%%${PROMPT_US}*}"
  PROMPT_HINT="${rest#*${PROMPT_US}}"
}

# Is there a terminal on stdin to read an answer from?
_prompt_can_ask() {
  [[ -t 0 ]]
}

# Can we draw the full selector, or do we fall back to a plain question line?
_prompt_can_draw() {
  [[ "${UI_RICH}" -eq 1 ]]
}

# Read one keypress into PROMPT_KEY, normalized to: up, down, enter, space, esc,
# or the literal character. End of input reads as enter, so a closed stdin ends
# the prompt rather than spinning.
#
# This sets a global instead of echoing, deliberately. Echoing would mean a
# $(...) fork per keystroke, and each fork puts the terminal into raw mode and
# back on the way out — which splits and drops the multi-byte escape sequence an
# arrow key sends. One process, one mode change, no lost keys.
PROMPT_KEY=""
_prompt_read_key() {
  local key="" rest=""

  if ! IFS= read -rsn1 key; then
    PROMPT_KEY="enter"
    return 0
  fi

  case "${key}" in
    "")
      PROMPT_KEY="enter"
      ;;
    $'\033')
      # An escape sequence: the two bytes that follow arrive with it.
      IFS= read -rsn2 rest || true
      case "${rest}" in
        "[A") PROMPT_KEY="up" ;;
        "[B") PROMPT_KEY="down" ;;
        *)    PROMPT_KEY="esc" ;;
      esac
      ;;
    " ")
      PROMPT_KEY="space"
      ;;
    *)
      PROMPT_KEY="${key}"
      ;;
  esac
}

_prompt_cursor_hide() { [[ "${UI_RICH}" -eq 1 ]] && printf '\033[?25l' >&2; return 0; }
_prompt_cursor_show() { [[ "${UI_RICH}" -eq 1 ]] && printf '\033[?25h' >&2; return 0; }

# Redraw the option list in place: jump back up over it, then reprint. Called
# after the first draw, so the list never scrolls away while arrowing through it.
_prompt_redraw_up() {
  local lines="$1"
  [[ "${lines}" -gt 0 ]] || return 0
  printf '\033[%dA' "${lines}" >&2
}

_prompt_draw_options() {
  local selected="$1"
  shift
  local i=0 record="" label="" width=0 hinted=0

  # Hints line up in their own column, so the list reads as two columns rather
  # than one run-on sentence. Only pad when there is something to line up.
  for record in "$@"; do
    _prompt_split "${record}"
    [[ "${#PROMPT_LABEL}" -gt "${width}" ]] && width="${#PROMPT_LABEL}"
    [[ -n "${PROMPT_HINT}" ]] && hinted=1
  done

  for record in "$@"; do
    _prompt_split "${record}"
    label="${PROMPT_LABEL}"
    if [[ "${hinted}" -eq 1 ]]; then
      label="$(_ui_cell "${label}" "${width}")"
    fi

    printf '\033[2K' >&2
    if [[ "${i}" -eq "${selected}" ]]; then
      printf '%s%s%s  %s%s%s %s%s%s' \
        "${UI_DIM}" "${UI_G_BAR}" "${UI_RESET}" \
        "${UI_CYAN}" "${UI_S_ON}" "${UI_RESET}" \
        "${UI_BOLD}" "${label}" "${UI_RESET}" >&2
    else
      printf '%s%s%s  %s%s %s%s' \
        "${UI_DIM}" "${UI_G_BAR}" "${UI_RESET}" \
        "${UI_DIM}" "${UI_S_OFF}" "${label}" "${UI_RESET}" >&2
    fi
    if [[ -n "${PROMPT_HINT}" ]]; then
      printf '   %s%s%s' "${UI_DIM}" "${PROMPT_HINT}" "${UI_RESET}" >&2
    fi
    printf '\n' >&2
    i=$(( i + 1 ))
  done
}

# The no-color interactive fallback for ui_select: a numbered list and a read.
# Accepts the number or the value itself, and an empty line takes the default.
_prompt_select_plain() {
  local question="$1"
  local selected="$2"
  shift 2
  local -a options=("$@")
  local record="" answer="" i=0
  local count="${#options[@]}"
  local default_value=""

  _prompt_split "${options[${selected}]}"
  default_value="${PROMPT_VALUE}"

  printf '%s\n' "${question}" >&2
  i=0
  for record in "${options[@]}"; do
    _prompt_split "${record}"
    if [[ -n "${PROMPT_HINT}" ]]; then
      printf '  [%d] %-10s %s\n' "$(( i + 1 ))" "${PROMPT_VALUE}" "${PROMPT_HINT}" >&2
    else
      printf '  [%d] %s\n' "$(( i + 1 ))" "${PROMPT_VALUE}" >&2
    fi
    i=$(( i + 1 ))
  done

  while true; do
    printf 'choose [%s]: ' "${default_value}" >&2
    IFS= read -r answer || answer=""
    if [[ -z "${answer}" ]]; then
      printf '%s\n' "${default_value}"
      return 0
    fi
    if [[ "${answer}" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= count )); then
      _prompt_split "${options[$(( answer - 1 ))]}"
      printf '%s\n' "${PROMPT_VALUE}"
      return 0
    fi
    for record in "${options[@]}"; do
      _prompt_split "${record}"
      if [[ "${PROMPT_VALUE}" == "${answer}" ]]; then
        printf '%s\n' "${PROMPT_VALUE}"
        return 0
      fi
    done
    printf 'please choose one of the listed options\n' >&2
  done
}

# Draw the checkbox list. <checked_name> is the name of the caller's 0/1 array;
# bash 3.2 has no namerefs, so it is dereferenced indirectly.
_prompt_draw_checks() {
  local cursor="$1"
  local checked_name="$2"
  shift 2
  local i=0 record="" mark="" state="" label="" width=0 hinted=0

  for record in "$@"; do
    _prompt_split "${record}"
    [[ "${#PROMPT_LABEL}" -gt "${width}" ]] && width="${#PROMPT_LABEL}"
    [[ -n "${PROMPT_HINT}" ]] && hinted=1
  done

  for record in "$@"; do
    _prompt_split "${record}"
    label="${PROMPT_LABEL}"
    if [[ "${hinted}" -eq 1 ]]; then
      label="$(_ui_cell "${label}" "${width}")"
    fi
    eval "state=\${${checked_name}[${i}]}"

    if [[ "${state}" -eq 1 ]]; then
      mark="${UI_CYAN}${UI_S_CHECKED}${UI_RESET}"
    else
      mark="${UI_DIM}${UI_S_UNCHECKED}${UI_RESET}"
    fi

    printf '\033[2K' >&2
    if [[ "${i}" -eq "${cursor}" ]]; then
      printf '%s%s%s  %s %s%s%s' \
        "${UI_DIM}" "${UI_G_BAR}" "${UI_RESET}" "${mark}" \
        "${UI_BOLD}" "${label}" "${UI_RESET}" >&2
    else
      printf '%s%s%s  %s %s%s%s' \
        "${UI_DIM}" "${UI_G_BAR}" "${UI_RESET}" "${mark}" \
        "${UI_DIM}" "${label}" "${UI_RESET}" >&2
    fi
    if [[ -n "${PROMPT_HINT}" ]]; then
      printf '   %s%s%s' "${UI_DIM}" "${PROMPT_HINT}" "${UI_RESET}" >&2
    fi
    printf '\n' >&2
    i=$(( i + 1 ))
  done
}

# ui_select <question> <default_value> <option record>...
# Echoes the chosen value. Arrow keys or j/k move, Enter accepts; the initial
# highlight is the option whose value matches <default_value>.
ui_select() {
  local question="$1"
  local default_value="$2"
  shift 2
  local -a options=()
  local record=""
  local count=0 selected=0 i=0

  for record in "$@"; do
    options+=("${record}")
  done
  count="${#options[@]}"
  [[ "${count}" -gt 0 ]] || return 1

  # Start on the default.
  i=0
  for record in "${options[@]}"; do
    _prompt_split "${record}"
    if [[ "${PROMPT_VALUE}" == "${default_value}" ]]; then
      selected="${i}"
      break
    fi
    i=$(( i + 1 ))
  done

  if ! _prompt_can_ask; then
    _prompt_split "${options[${selected}]}"
    printf '%s\n' "${PROMPT_VALUE}"
    return 0
  fi

  if ! _prompt_can_draw; then
    _prompt_select_plain "${question}" "${selected}" "${options[@]}"
    return 0
  fi

  ui_gap
  printf '%s%s%s  %s%s%s %s%s%s\n' \
    "${UI_CYAN}" "${UI_S_ACTIVE}" "${UI_RESET}" \
    "${UI_BOLD}" "${question}" "${UI_RESET}" \
    "${UI_DIM}" "(arrows, enter)" "${UI_RESET}" >&2

  _prompt_cursor_hide
  _prompt_draw_options "${selected}" "${options[@]}"

  while true; do
    _prompt_read_key
    case "${PROMPT_KEY}" in
      up|k)
        selected=$(( selected > 0 ? selected - 1 : count - 1 ))
        ;;
      down|j)
        selected=$(( selected < count - 1 ? selected + 1 : 0 ))
        ;;
      enter)
        break
        ;;
      q|esc)
        break
        ;;
      *)
        # A digit picks that option outright.
        if [[ "${PROMPT_KEY}" =~ ^[1-9]$ && "${PROMPT_KEY}" -le "${count}" ]]; then
          selected=$(( PROMPT_KEY - 1 ))
          break
        fi
        ;;
    esac
    _prompt_redraw_up "${count}"
    _prompt_draw_options "${selected}" "${options[@]}"
  done

  # Collapse the whole prompt — question line and option list — into the settled
  # two-line form: the question, now marked done, and the answer under it.
  _prompt_redraw_up $(( count + 1 ))
  for (( i = 0; i <= count; i++ )); do
    printf '\033[2K\n' >&2
  done
  _prompt_redraw_up $(( count + 1 ))
  _prompt_cursor_show

  _prompt_split "${options[${selected}]}"
  ui_step "${question}" "${PROMPT_LABEL}"

  printf '%s\n' "${PROMPT_VALUE}"
}

# ui_confirm <question> <yes|no default> — returns 0 for yes, 1 for no.
ui_confirm() {
  local question="$1"
  local default_value="$2"
  local answer=""
  local -a options=()

  options+=("$(prompt_opt yes Yes)")
  options+=("$(prompt_opt no No)")

  answer="$(ui_select "${question}" "${default_value}" "${options[@]}")"

  [[ "${answer}" == "yes" ]]
}

# ui_input <question> <default> — echoes the answer, defaulting on an empty line.
ui_input() {
  local question="$1"
  local default_value="${2:-}"
  local value=""

  if ! _prompt_can_ask; then
    printf '%s\n' "${default_value}"
    return 0
  fi

  if ! _prompt_can_draw; then
    if [[ -n "${default_value}" ]]; then
      printf '%s [%s]: ' "${question}" "${default_value}" >&2
    else
      printf '%s: ' "${question}" >&2
    fi
    IFS= read -r value || value=""
    [[ -n "${value}" ]] || value="${default_value}"
    printf '%s\n' "${value}"
    return 0
  fi

  ui_gap
  printf '%s%s%s  %s%s%s' \
    "${UI_CYAN}" "${UI_S_ACTIVE}" "${UI_RESET}" "${UI_BOLD}" "${question}" "${UI_RESET}" >&2
  if [[ -n "${default_value}" ]]; then
    printf ' %s(%s)%s' "${UI_DIM}" "${default_value}" "${UI_RESET}" >&2
  fi
  printf '\n%s%s%s  ' "${UI_DIM}" "${UI_G_BAR}" "${UI_RESET}" >&2

  IFS= read -r value || value=""
  [[ -n "${value}" ]] || value="${default_value}"

  # Collapse to the same settled two-line form the selector leaves behind, so an
  # answered input and an answered choice read alike in the transcript.
  _prompt_redraw_up 2
  printf '\033[2K\n\033[2K\n' >&2
  _prompt_redraw_up 2
  ui_step "${question}" "${value}"

  printf '%s\n' "${value}"
}

# ui_multiselect <question> <preselected: all|none> <option record>...
# Space toggles the row under the cursor, "a" toggles everything, Enter accepts.
# Echoes the chosen values, one per line. Falls back the same way ui_select does:
# a plain numbered prompt without color, the preselection with no terminal.
ui_multiselect() {
  local question="$1"
  local preselect="$2"
  shift 2
  local -a options=()
  local -a checked=()
  local record=""
  local count=0 cursor=0 i=0 initial=1 chosen=0 all_set=0

  for record in "$@"; do
    options+=("${record}")
  done
  count="${#options[@]}"
  [[ "${count}" -gt 0 ]] || return 1
  [[ "${preselect}" == "all" ]] || initial=0

  for (( i = 0; i < count; i++ )); do
    checked+=("${initial}")
  done

  if ! _prompt_can_ask || ! _prompt_can_draw; then
    for (( i = 0; i < count; i++ )); do
      if [[ "${checked[${i}]}" -eq 1 ]]; then
        _prompt_split "${options[${i}]}"
        printf '%s\n' "${PROMPT_VALUE}"
      fi
    done
    return 0
  fi

  ui_gap
  printf '%s%s%s  %s%s%s %s%s%s\n' \
    "${UI_CYAN}" "${UI_S_ACTIVE}" "${UI_RESET}" \
    "${UI_BOLD}" "${question}" "${UI_RESET}" \
    "${UI_DIM}" "(space toggles, a all, enter accepts)" "${UI_RESET}" >&2

  _prompt_cursor_hide
  _prompt_draw_checks "${cursor}" checked "${options[@]}"

  while true; do
    _prompt_read_key
    case "${PROMPT_KEY}" in
      up|k)    cursor=$(( cursor > 0 ? cursor - 1 : count - 1 )) ;;
      down|j)  cursor=$(( cursor < count - 1 ? cursor + 1 : 0 )) ;;
      space)
        if [[ "${checked[${cursor}]}" -eq 1 ]]; then
          checked[${cursor}]=0
        else
          checked[${cursor}]=1
        fi
        ;;
      a)
        # Toggle everything: clear them all if they are already all set.
        all_set=1
        for (( i = 0; i < count; i++ )); do
          [[ "${checked[${i}]}" -eq 1 ]] || all_set=0
        done
        for (( i = 0; i < count; i++ )); do
          if [[ "${all_set}" -eq 1 ]]; then checked[${i}]=0; else checked[${i}]=1; fi
        done
        ;;
      enter|esc|q)
        break
        ;;
    esac
    _prompt_redraw_up "${count}"
    _prompt_draw_checks "${cursor}" checked "${options[@]}"
  done

  _prompt_redraw_up $(( count + 1 ))
  for (( i = 0; i <= count; i++ )); do
    printf '\033[2K\n' >&2
  done
  _prompt_redraw_up $(( count + 1 ))
  _prompt_cursor_show

  chosen=0
  for (( i = 0; i < count; i++ )); do
    [[ "${checked[${i}]}" -eq 1 ]] && chosen=$(( chosen + 1 ))
  done
  ui_step "${question}" "${chosen} of ${count} selected"

  for (( i = 0; i < count; i++ )); do
    if [[ "${checked[${i}]}" -eq 1 ]]; then
      _prompt_split "${options[${i}]}"
      printf '%s\n' "${PROMPT_VALUE}"
    fi
  done
}
