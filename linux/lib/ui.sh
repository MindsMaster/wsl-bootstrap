# shellcheck shell=bash
# Dialog helpers: whiptail when there is a terminal, plain prompts otherwise.
# Every ui_* returns 1 when the user cancels (Esc / Cancel / empty EOF).

UI_TITLE="WSL Bootstrap"
UI_H=20
UI_W=78

ui_init() {
  if command -v whiptail >/dev/null 2>&1 && [[ -t 0 && -t 1 ]] && [[ ${UI_PLAIN:-0} != 1 ]]; then
    UI=whiptail
    # Readable on both dark and light Windows Terminal themes.
    export NEWT_COLORS='root=,black window=,black border=cyan,black title=cyan,black
      textbox=white,black button=black,cyan actbutton=black,cyan compactbutton=white,black
      entry=white,black checkbox=white,black actcheckbox=black,cyan listbox=white,black
      actlistbox=black,cyan actsellistbox=black,cyan sellistbox=white,black'
  else
    UI=plain
  fi
}

_wt() { whiptail --title "$UI_TITLE" "$@" 3>&1 1>&2 2>&3; }

# Box height for an input dialog: text lines + room for the entry and buttons.
_ui_h() {
  local n
  n=$(printf '%s\n' "$1" | wc -l)
  n=$(( n + 8 ))
  (( n < 10 )) && n=10
  (( n > 24 )) && n=24
  echo "$n"
}

ui_msg() {
  if [[ $UI == whiptail ]]; then
    _wt --msgbox "$1" "$UI_H" "$UI_W" >/dev/null || true
  else
    printf '\n%s\n' "$1" >&2
    read -r -p "[回车继续] " _ || true
  fi
}

# ui_yesno <text> [y|n]
ui_yesno() {
  local def=${2:-y} ans
  if [[ $UI == whiptail ]]; then
    if [[ $def == n ]]; then _wt --defaultno --yesno "$1" "$UI_H" "$UI_W"; else _wt --yesno "$1" "$UI_H" "$UI_W"; fi
    return
  fi
  printf '\n%s\n' "$1" >&2
  read -r -p "[$([[ $def == y ]] && echo Y/n || echo y/N)] " ans || return 1
  ans=${ans:-$def}
  [[ $ans =~ ^[Yy] ]]
}

# ui_input <text> [default]
ui_input() {
  local ans
  if [[ $UI == whiptail ]]; then
    _wt --inputbox "$1" "$(_ui_h "$1")" "$UI_W" "${2:-}"
    return
  fi
  printf '\n%s\n' "$1" >&2
  read -r -e -i "${2:-}" -p "> " ans || return 1
  echo "${ans:-${2:-}}"
}

ui_password() {
  local ans
  if [[ $UI == whiptail ]]; then
    _wt --passwordbox "$1" "$(_ui_h "$1")" "$UI_W"
    return
  fi
  printf '\n%s\n' "$1" >&2
  read -r -s -p "> " ans || return 1
  echo >&2
  echo "$ans"
}

# ui_menu <text> <default-tag> tag desc [tag desc ...]
ui_menu() {
  local text=$1 def=$2 n ans
  shift 2
  if [[ $UI == whiptail ]]; then
    _wt --default-item "$def" --menu "$text" "$UI_H" "$UI_W" $(( $# / 2 > 10 ? 10 : $# / 2 )) "$@"
    return
  fi
  printf '\n%s\n' "$text" >&2
  local -a tags=()
  n=0
  while (( $# )); do
    n=$((n + 1)); tags[n]=$1
    printf '  %d) %s%s\n' "$n" "$2" "$([[ $1 == "$def" ]] && echo '  (默认)')" >&2
    shift 2
  done
  read -r -p "> " ans || return 1
  if [[ -z $ans ]]; then echo "$def"; return 0; fi
  [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= n )) || return 1
  echo "${tags[ans]}"
}

# ui_checklist <text> tag desc on|off [...]  -> selected tags, one per line
ui_checklist() {
  local text=$1
  shift
  if [[ $UI == whiptail ]]; then
    _wt --separate-output --checklist "$text" "$UI_H" "$UI_W" $(( $# / 3 )) "$@"
    return
  fi
  printf '\n%s\n' "$text" >&2
  while (( $# )); do
    if ui_yesno "  启用「$2」?" "$([[ $3 == on ]] && echo y || echo n)"; then
      echo "$1"
    fi
    shift 3
  done
}
