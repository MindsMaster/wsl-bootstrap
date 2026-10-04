# shellcheck shell=bash
# Logging, distro detection and small install helpers for setup.sh.

if [[ -t 1 ]]; then
  C_G=$'\e[32m' C_R=$'\e[31m' C_Y=$'\e[33m' C_C=$'\e[36m' C_B=$'\e[1m' C_D=$'\e[2m' C_N=$'\e[0m'
else
  C_G="" C_R="" C_Y="" C_C="" C_B="" C_D="" C_N=""
fi

STEP_NO=0
step() { STEP_NO=$((STEP_NO + 1)); printf '\n%s==> [%d] %s%s\n' "$C_C$C_B" "$STEP_NO" "$*" "$C_N"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✔%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_N" "$*" >&2; }
die()  { printf '\n%s✘ %s%s\n' "$C_R$C_B" "$*" "$C_N" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "setup.sh 必须以 root 运行（Windows 端用 wsl -u root 调用）"; }

# Sets OS_ID (ubuntu|debian), OS_VERSION, OS_CODENAME.
detect_os() {
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID:-unknown}
  OS_VERSION=${VERSION_ID:-}
  OS_CODENAME=${VERSION_CODENAME:-}
  OS_PRETTY=${PRETTY_NAME:-$OS_ID}
}

apt_quiet() {
  DEBIAN_FRONTEND=noninteractive apt-get -y -q \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# install_payload <src> <dst> <mode>: copy with CRs stripped (repo may come
# from a Windows checkout with CRLF).
install_payload() {
  local src=$1 dst=$2 mode=${3:-0644}
  install -d -m 0755 "$(dirname "$dst")"
  tr -d '\r' <"$src" >"$dst.tmp.$$"
  chmod "$mode" "$dst.tmp.$$"
  mv -f "$dst.tmp.$$" "$dst"
}

backup_once() {
  local f=$1
  [[ -e $f && ! -e $f.wsl-bootstrap.bak ]] && cp -a "$f" "$f.wsl-bootstrap.bak"
  return 0
}

# answers.env persists choices between the configure and finalize phases.
STATE_DIR=/etc/wsl-bootstrap
STATE_FILE=$STATE_DIR/answers.env

state_save() {
  local var
  install -d -m 0755 "$STATE_DIR"
  {
    echo "# wsl-bootstrap answers ($(date -Is))"
    for var in "$@"; do printf '%s=%q\n' "$var" "${!var:-}"; done
  } >"$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

state_load() {
  # shellcheck disable=SC1090
  [[ -r $STATE_FILE ]] && . "$STATE_FILE"
}
