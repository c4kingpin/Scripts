#!/usr/bin/env bash
# Codex Dev Box - Proxmox VE LXC installer
# Ubuntu 24.04 LTS, SSH key access, Codex CLI, no Docker
# License: MIT

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

readonly APP="Codex Dev Box"
readonly VERSION="1.2.1"
readonly UBUNTU_VERSION="24.04"
readonly NODE_MAJOR="${NODE_MAJOR:-24}"
readonly CODEX_RELEASE="${CODEX_RELEASE:-latest}"
readonly NODESOURCE_KEY_FINGERPRINT="6F71F525282841EEDAF851B42F59B5F99B1BE0B4"

readonly DEFAULT_CT_HOSTNAME="codex-devbox"
readonly DEFAULT_CORES="4"
readonly DEFAULT_MEMORY="8192"
readonly DEFAULT_SWAP="512"
readonly DEFAULT_DISK="32"
readonly DEFAULT_USER="dev"
readonly DEFAULT_BRIDGE="vmbr0"
readonly DEFAULT_AGENT_FORWARDING="no"

LOG_FILE="<noch nicht initialisiert>"
CT_CREATED=0
CURRENT_STEP="Initialisierung"

YW='\033[33m'
BL='\033[36m'
GN='\033[1;92m'
RD='\033[01;31m'
CL='\033[m'
BOLD='\033[1m'

CHECK="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${BL}ℹ${CL}"

msg_info() { printf '%b\n' "${INFO} ${YW}$*${CL}"; }
msg_ok()   { printf '%b\n' "${CHECK} ${GN}$*${CL}"; }
fatal()    { printf '%b\n' "${CROSS} ${RD}$*${CL}" >&2; exit 1; }

summarize_command() {
  local command="${1%%$'\n'*}"
  local max_length=240

  if ((${#command} > max_length)); then
    printf '%s...\n' "${command:0:max_length - 3}"
  else
    printf '%s\n' "$command"
  fi
}

on_error() {
  local code=$?
  local line="${BASH_LINENO[0]:-${LINENO}}"
  local command
  command="$(summarize_command "${BASH_COMMAND:-unbekannt}")"

  trap - ERR
  printf '\n' >&2
  printf '%b\n' "${CROSS} ${RD}Installation fehlgeschlagen.${CL}" >&2
  printf '%b\n' "${RD}Schritt:     ${CURRENT_STEP}${CL}" >&2
  printf '%b\n' "${RD}Zeile:       ${line}${CL}" >&2
  printf '%b\n' "${RD}Exit-Code:   ${code}${CL}" >&2
  printf '%b\n' "${RD}Befehl:      ${command}${CL}" >&2
  printf '%b\n' "${RD}Logdatei:    ${LOG_FILE}${CL}" >&2

  if [[ "${CT_CREATED}" -eq 1 ]] && pct status "${CTID:-0}" >/dev/null 2>&1; then
    printf '%b\n' "${YW}Der unvollständige Container ${CTID} wurde zur Diagnose beibehalten.${CL}" >&2
    printf '%b\n' "${YW}Entfernen: pct stop ${CTID} 2>/dev/null || true; pct destroy ${CTID} --purge${CL}" >&2
  fi

  exit "$code"
}

on_signal() {
  local signal="$1"
  trap - ERR INT TERM HUP
  printf '\n%b\n' "${CROSS} ${RD}Installation durch Signal ${signal} abgebrochen.${CL}" >&2
  if [[ "${CT_CREATED}" -eq 1 ]] && pct status "${CTID:-0}" >/dev/null 2>&1; then
    printf '%b\n' "${YW}Container ${CTID} wurde zur Diagnose beibehalten.${CL}" >&2
  fi
  exit 130
}

usage() {
  cat <<EOF
Verwendung: $(basename "$0") [--help] [--version]

Erstellt interaktiv einen gehärteten Ubuntu-${UBUNTU_VERSION}-LXC-Container
auf einem Proxmox-VE-Host und installiert eine Codex-Entwicklungsumgebung.

Optionale Umgebungsvariablen:
  NODE_MAJOR     Node.js-Hauptversion (22 oder 24; Standard: ${NODE_MAJOR})
  CODEX_RELEASE  Codex-Version oder "latest" (Standard: ${CODEX_RELEASE})
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --version)
        printf '%s %s\n' "$APP" "$VERSION"
        exit 0
        ;;
      *)
        printf 'Unbekannte Option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

init_runtime() {
  local old_umask
  old_umask="$(umask)"
  umask 077
  install -d -m 0700 /var/log/codex-devbox
  LOG_FILE="$(
    mktemp "/var/log/codex-devbox/install-$(date +%Y%m%d-%H%M%S)-XXXXXX.log"
  )"
  chmod 0600 "$LOG_FILE"
  umask "$old_umask"

  exec 9>/run/lock/codex-devbox.lock
  flock -n 9 ||
    fatal "Eine weitere Codex-Dev-Box-Installation läuft bereits."

  exec > >(tee -a "$LOG_FILE") 2>&1
}

header() {
  clear 2>/dev/null || true
  cat <<'BANNER'
   ______          __             ____             ____
  / ____/___  ____/ /___  _  __  / __ \___  _   __/ __ )____  _  __
 / /   / __ \/ __  / __ \| |/_/ / / / / _ \| | / / __  / __ \| |/_/
/ /___/ /_/ / /_/ / /_/ />  <  / /_/ /  __/| |/ / /_/ / /_/ />  <
\____/\____/\__,_/\____/_/|_| /_____/\___/ |___/_____/\____/_/|_|
BANNER
  printf '%b\n' "${BOLD}Proxmox VE LXC Installer – Ubuntu ${UBUNTU_VERSION}, SSH und Codex CLI${CL}"
  printf 'Version %s\n\n' "$VERSION"
}

pve_major_version() {
  local version="$1"

  [[ "$version" =~ ^pve-manager/([0-9]+)\. ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

require_pve() {
  [[ "${EUID}" -eq 0 ]] || fatal "Dieses Skript muss als root ausgeführt werden."
  [[ -t 0 ]] ||
    fatal "Für die interaktive Installation wird ein Terminal benötigt."

  local cmd
  local host_arch
  local pve_major
  local pve_version
  for cmd in \
    apt-get awk chmod date dpkg flock grep install mktemp pct pveam pvesh \
    pvesm pveversion sort ssh-keygen tail tee; do
    command -v "$cmd" >/dev/null 2>&1 ||
      fatal "${cmd} fehlt. Das Skript muss auf einem Proxmox-VE-Host laufen."
  done

  host_arch="$(dpkg --print-architecture)"
  [[ "$host_arch" == "amd64" ]] ||
    fatal "Diese Version unterstützt ausschließlich amd64-Proxmox-Hosts."

  pve_version="$(pveversion)"
  if ! pve_major="$(pve_major_version "$pve_version")"; then
    fatal "Die Proxmox-VE-Version konnte nicht ermittelt werden."
  fi
  ((10#${pve_major} >= 8)) ||
    fatal "Proxmox VE 8 oder neuer ist erforderlich."

  [[ "$NODE_MAJOR" =~ ^(22|24)$ ]] ||
    fatal "NODE_MAJOR muss 22 oder 24 sein."

  [[ "$CODEX_RELEASE" == "latest" ||
    "$CODEX_RELEASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta)(\.[0-9]+)?)?$ ]] ||
    fatal "CODEX_RELEASE muss 'latest' oder eine Version wie 1.2.3 sein."
}

install_dialog() {
  if ! command -v whiptail >/dev/null 2>&1; then
    msg_info "Installiere whiptail"
    DEBIAN_FRONTEND=noninteractive apt-get \
      -o Acquire::Retries=5 \
      -o Acquire::http::Timeout=30 \
      -o Acquire::https::Timeout=30 \
      -o APT::Update::Error-Mode=any \
      -o DPkg::Lock::Timeout=120 \
      update
    DEBIAN_FRONTEND=noninteractive apt-get \
      -o Acquire::Retries=5 \
      -o Acquire::http::Timeout=30 \
      -o Acquire::https::Timeout=30 \
      -o DPkg::Lock::Timeout=120 \
      install -y --no-install-recommends whiptail
  fi
}

next_ctid() {
  pvesh get /cluster/nextid
}

vmid_is_available() {
  local vmid="$1"

  pvesh get /cluster/nextid --vmid "$vmid" >/dev/null 2>&1
}

rootfs_storages() {
  pvesm status -content rootdir 2>/dev/null |
    awk 'NR > 1 && $3 == "active" { print $1 }'
}

template_storages() {
  pvesm status -content vztmpl 2>/dev/null |
    awk 'NR > 1 && $3 == "active" { print $1 }'
}

storage_available_kib() {
  local storage="$1"

  pvesm status -storage "$storage" 2>/dev/null |
    awk 'NR > 1 && $3 == "active" { print $6; exit }'
}

storage_is_active() {
  local storage="$1"

  pvesm status -storage "$storage" 2>/dev/null |
    awk 'NR > 1 && $3 == "active" { found=1 } END { exit !found }'
}

bridge_exists() {
  local bridge="$1"
  [[ -e "/sys/class/net/${bridge}" ]]
}

is_ipv4() {
  local address="$1"
  local octets=()
  local octet

  [[ "$address" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$address"
  ((${#octets[@]} == 4)) || return 1

  for octet in "${octets[@]}"; do
    ((${#octet} <= 3)) || return 1
    [[ "$octet" == "0" || "$octet" != 0* ]] || return 1
    ((10#${octet} <= 255)) || return 1
  done
}

is_ipv4_cidr() {
  local value="$1"
  local address prefix

  [[ "$value" == */* ]] || return 1
  address="${value%/*}"
  prefix="${value##*/}"

  is_ipv4 "$address" &&
    [[ "$prefix" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]]
}

ipv4_to_int() {
  local address="$1"
  local octet1 octet2 octet3 octet4
  local result

  is_ipv4 "$address" || return 1
  IFS='.' read -r octet1 octet2 octet3 octet4 <<<"$address"
  result=$((
    (10#${octet1} << 24) |
    (10#${octet2} << 16) |
    (10#${octet3} << 8) |
    10#${octet4}
  ))
  printf '%u\n' "$result"
}

static_network_is_usable() {
  local value="$1"
  local gateway="$2"
  local address prefix
  local address_int gateway_int mask network broadcast

  is_ipv4_cidr "$value" && is_ipv4 "$gateway" || return 1
  address="${value%/*}"
  prefix="${value##*/}"

  # Normale LXC-LAN-Konfigurationen benötigen ein Netz mit Host-Adressen.
  ((10#${prefix} >= 1 && 10#${prefix} <= 30)) || return 1

  address_int="$(ipv4_to_int "$address")"
  gateway_int="$(ipv4_to_int "$gateway")"
  mask=$(((0xffffffff << (32 - 10#${prefix})) & 0xffffffff))
  network=$((address_int & mask))
  broadcast=$((network | (0xffffffff ^ mask)))

  ((address_int != network && address_int != broadcast)) &&
    ((gateway_int != network && gateway_int != broadcast)) &&
    ((address_int != gateway_int)) &&
    (((gateway_int & mask) == network))
}

ssh_public_key_fingerprint() {
  local key="$1"
  local key_file
  local fingerprint

  key_file="$(mktemp)"
  chmod 0600 "$key_file"
  printf '%s\n' "$key" >"$key_file"
  if ! fingerprint="$(ssh-keygen -l -f "$key_file" 2>/dev/null | awk '{ print $2 }')"; then
    rm -f "$key_file"
    return 1
  fi
  rm -f "$key_file"
  [[ -n "$fingerprint" ]] || return 1
  printf '%s\n' "$fingerprint"
}

validate_ssh_public_key() {
  local key="$1"
  local key_type key_data _key_comment

  [[ -n "$key" && "$key" != *$'\n'* && "$key" != *$'\r'* ]] || return 1
  read -r key_type key_data _key_comment <<<"$key"
  [[ -n "$key_data" ]] || return 1

  case "$key_type" in
    ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
      ;;
    *)
      return 1
      ;;
  esac

  ssh_public_key_fingerprint "$key" >/dev/null
}

choose_storage() {
  local title="$1"
  local prompt="$2"
  local default_value="$3"
  shift 3

  local options=()
  local item
  for item in "$@"; do
    if [[ "$item" == "$default_value" ]]; then
      options+=("$item" "" ON)
    else
      options+=("$item" "" OFF)
    fi
  done

  whiptail \
    --backtitle "$APP" \
    --title "$title" \
    --radiolist "$prompt" \
    18 72 10 \
    "${options[@]}" \
    3>&1 1>&2 2>&3
}

dialog_input() {
  local title="$1"
  local prompt="$2"
  local default_value="$3"

  whiptail \
    --backtitle "$APP" \
    --title "$title" \
    --inputbox "$prompt" \
    9 72 "$default_value" \
    3>&1 1>&2 2>&3
}

load_defaults() {
  CTID="$(next_ctid)"
  CT_HOSTNAME="$DEFAULT_CT_HOSTNAME"
  CORES="$DEFAULT_CORES"
  MEMORY="$DEFAULT_MEMORY"
  SWAP="$DEFAULT_SWAP"
  DISK="$DEFAULT_DISK"
  DEV_USER="$DEFAULT_USER"
  BRIDGE="$DEFAULT_BRIDGE"
  ALLOW_AGENT_FORWARDING="$DEFAULT_AGENT_FORWARDING"
  IPV4_MODE="dhcp"
  IPV4_ADDRESS=""
  IPV4_GATEWAY=""

  mapfile -t STORAGES < <(rootfs_storages)
  mapfile -t TEMPLATE_STORAGES < <(template_storages)

  ((${#STORAGES[@]} > 0)) ||
    fatal "Kein aktiver Storage mit dem Inhaltstyp 'rootdir' gefunden."
  ((${#TEMPLATE_STORAGES[@]} > 0)) ||
    fatal "Kein aktiver Storage mit dem Inhaltstyp 'vztmpl' gefunden."

  STORAGE="${STORAGES[0]}"
  TEMPLATE_STORAGE="${TEMPLATE_STORAGES[0]}"
}

advanced_settings() {
  CTID="$(dialog_input "Container-ID" "Container-ID:" "$CTID")" || return 1
  CT_HOSTNAME="$(dialog_input "Hostname" "Hostname:" "$CT_HOSTNAME")" || return 1
  CORES="$(dialog_input "CPU" "Anzahl CPU-Kerne:" "$CORES")" || return 1
  MEMORY="$(dialog_input "Arbeitsspeicher" "RAM in MiB:" "$MEMORY")" || return 1
  SWAP="$(dialog_input "Swap" "Swap in MiB:" "$SWAP")" || return 1
  DISK="$(dialog_input "Festplatte" "Root-Disk in GiB:" "$DISK")" || return 1
  DEV_USER="$(dialog_input "Benutzer" "Entwickler-Benutzer:" "$DEV_USER")" || return 1

  STORAGE="$(choose_storage \
    "Root-Disk-Storage" \
    "Storage für die Container-Root-Disk:" \
    "$STORAGE" \
    "${STORAGES[@]}")" || return 1

  TEMPLATE_STORAGE="$(choose_storage \
    "Template-Storage" \
    "Storage für das Ubuntu-LXC-Template:" \
    "$TEMPLATE_STORAGE" \
    "${TEMPLATE_STORAGES[@]}")" || return 1

  BRIDGE="$(dialog_input "Netzwerk" "Proxmox-Bridge:" "$BRIDGE")" || return 1

  local forwarding_status
  if whiptail \
    --backtitle "$APP" \
    --title "SSH-Agent-Forwarding" \
    --yesno "SSH-Agent-Forwarding aktivieren?\n\nNur für vertrauenswürdige Container empfohlen." \
    12 72; then
    ALLOW_AGENT_FORWARDING="yes"
  else
    forwarding_status=$?
    [[ "$forwarding_status" -eq 1 ]] || return 1
    ALLOW_AGENT_FORWARDING="no"
  fi

  IPV4_MODE="$(
    whiptail \
      --backtitle "$APP" \
      --title "IPv4-Konfiguration" \
      --menu "IPv4-Konfiguration auswählen:" \
      13 68 2 \
      dhcp "Adresse automatisch beziehen" \
      static "Statische IPv4-Adresse verwenden" \
      3>&1 1>&2 2>&3
  )" || return 1

  if [[ "$IPV4_MODE" == "static" ]]; then
    IPV4_ADDRESS="$(dialog_input \
      "Statische IPv4-Adresse" \
      "Adresse mit Präfix, z. B. 192.168.1.50/24:" \
      "")" || return 1

    IPV4_GATEWAY="$(dialog_input \
      "IPv4-Gateway" \
      "Gateway, z. B. 192.168.1.1:" \
      "")" || return 1
  fi
}

read_ssh_key() {
  local key=""
  local key_file
  local key_status

  for key_file in /root/.ssh/id_ed25519.pub /root/.ssh/id_ecdsa.pub /root/.ssh/id_rsa.pub; do
    if [[ -s "$key_file" ]]; then
      if whiptail \
        --backtitle "$APP" \
        --title "SSH-Schlüssel" \
        --yesno "Vorhandenen Schlüssel verwenden?\n\n${key_file}" \
        11 72; then
        key="$(<"$key_file")"
        break
      else
        key_status=$?
        [[ "$key_status" -eq 1 ]] || return 1
      fi
    fi
  done

  if [[ -z "$key" ]]; then
    key="$(
      whiptail \
        --backtitle "$APP" \
        --title "SSH-Schlüssel" \
        --inputbox "Öffentlichen SSH-Schlüssel vollständig einfügen:" \
        11 86 \
        3>&1 1>&2 2>&3
    )" || return 1
  fi

  validate_ssh_public_key "$key" ||
    fatal "Der eingegebene öffentliche SSH-Schlüssel ist ungültig."

  SSH_PUBLIC_KEY="$key"
  SSH_KEY_FINGERPRINT="$(ssh_public_key_fingerprint "$key")"
}

validate_settings() {
  local available_kib
  local required_kib

  [[ "$CTID" =~ ^[1-9][0-9]{2,8}$ ]] ||
    fatal "Die Container-ID muss eine Zahl ab 100 sein."

  if ! [[ "$CORES" =~ ^[1-9][0-9]*$ && ${#CORES} -le 3 ]] ||
    ! ((10#${CORES} <= 512)); then
    fatal "Die Anzahl der CPU-Kerne ist ungültig."
  fi

  if ! [[ "$MEMORY" =~ ^[1-9][0-9]*$ && ${#MEMORY} -le 7 ]] ||
    ! ((10#${MEMORY} >= 2048 && 10#${MEMORY} <= 1048576)); then
    fatal "Die RAM-Angabe ist ungültig (mindestens 2048 MiB)."
  fi

  if ! [[ "$SWAP" =~ ^(0|[1-9][0-9]*)$ && ${#SWAP} -le 7 ]] ||
    ! ((10#${SWAP} <= 1048576)); then
    fatal "Die Swap-Angabe ist ungültig."
  fi

  if ! [[ "$DISK" =~ ^[1-9][0-9]*$ && ${#DISK} -le 7 ]] ||
    ! ((10#${DISK} >= 16 && 10#${DISK} <= 1048576)); then
    fatal "Die Disk-Angabe ist ungültig (mindestens 16 GiB)."
  fi

  [[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] ||
    fatal "Der Hostname ist ungültig."

  [[ "$DEV_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
    fatal "Der Benutzername ist ungültig."
  [[ "$DEV_USER" != "root" ]] ||
    fatal "Der Benutzername 'root' ist nicht zulässig."

  [[ "$BRIDGE" =~ ^[a-zA-Z0-9_.:-]+$ ]] ||
    fatal "Der Bridge-Name ist ungültig."
  bridge_exists "$BRIDGE" ||
    fatal "Die Bridge '${BRIDGE}' existiert auf diesem Proxmox-Host nicht."

  [[ "$ALLOW_AGENT_FORWARDING" =~ ^(yes|no)$ ]] ||
    fatal "Die Agent-Forwarding-Einstellung ist ungültig."

  [[ "$IPV4_MODE" =~ ^(dhcp|static)$ ]] ||
    fatal "Der IPv4-Modus ist ungültig."

  if [[ "$IPV4_MODE" == "static" ]]; then
    is_ipv4_cidr "$IPV4_ADDRESS" ||
      fatal "Die statische IPv4-Adresse ist ungültig."

    is_ipv4 "$IPV4_GATEWAY" ||
      fatal "Das IPv4-Gateway ist ungültig."
    [[ "$IPV4_GATEWAY" != "0.0.0.0" &&
      "$IPV4_GATEWAY" != "255.255.255.255" ]] ||
      fatal "Das IPv4-Gateway ist keine verwendbare Host-Adresse."

    static_network_is_usable "$IPV4_ADDRESS" "$IPV4_GATEWAY" ||
      fatal "IPv4-Adresse und Gateway müssen nutzbare Hosts im selben /1- bis /30-Subnetz sein."
  fi

  if ! vmid_is_available "$CTID"; then
    fatal "Die Container-ID ${CTID} konnte clusterweit nicht als frei bestätigt werden."
  fi

  storage_is_active "$STORAGE" ||
    fatal "Root-Disk-Storage '${STORAGE}' ist nicht aktiv."

  storage_is_active "$TEMPLATE_STORAGE" ||
    fatal "Template-Storage '${TEMPLATE_STORAGE}' ist nicht aktiv."

  available_kib="$(storage_available_kib "$STORAGE")"
  [[ "$available_kib" =~ ^[0-9]+$ ]] ||
    fatal "Freier Speicherplatz auf '${STORAGE}' konnte nicht ermittelt werden."
  required_kib=$((10#${DISK} * 1024 * 1024))
  ((10#${available_kib} >= required_kib)) ||
    fatal "Auf '${STORAGE}' sind keine ${DISK} GiB verfügbar."
}

confirm_settings() {
  local network_summary="DHCP"
  if [[ "$IPV4_MODE" == "static" ]]; then
    network_summary="${IPV4_ADDRESS}, Gateway ${IPV4_GATEWAY}"
  fi

  whiptail \
    --backtitle "$APP" \
    --title "Installation bestätigen" \
    --yesno "Ubuntu ${UBUNTU_VERSION} LXC erstellen?

CTID:              ${CTID}
Hostname:          ${CT_HOSTNAME}
CPU:               ${CORES}
RAM:               ${MEMORY} MiB
Swap:              ${SWAP} MiB
Disk:              ${DISK} GiB
Root-Disk-Storage: ${STORAGE}
Template-Storage:  ${TEMPLATE_STORAGE}
Bridge:            ${BRIDGE}
IPv4:              ${network_summary}
Benutzer:          ${DEV_USER}
SSH-Key:           ${SSH_KEY_FINGERPRINT}
Agent-Forwarding:  ${ALLOW_AGENT_FORWARDING}
Node.js:           ${NODE_MAJOR}.x
Codex:             ${CODEX_RELEASE}

Docker wird nicht installiert." \
    28 82
}

latest_ubuntu_template() {
  awk -v version="ubuntu-${UBUNTU_VERSION}-standard" '
    index($2, version "_") == 1 && $2 ~ /_amd64\.tar\.(gz|xz|zst)$/ {
      print $2
    }
  ' |
    sort -V |
    tail -n 1
}

find_template() {
  CURRENT_STEP="Ubuntu-LXC-Template vorbereiten"
  msg_info "$CURRENT_STEP"

  pveam update

  TEMPLATE="$(
    pveam available --section system |
      latest_ubuntu_template
  )"

  [[ -n "$TEMPLATE" ]] ||
    fatal "Kein Ubuntu-${UBUNTU_VERSION}-Standard-Template gefunden."

  TEMPLATE_VOLUME="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"

  if ! pveam list "$TEMPLATE_STORAGE" |
    awk 'NR > 1 { print $1 }' |
    grep -Fxq "$TEMPLATE_VOLUME"; then
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  fi

  msg_ok "Template bereit: ${TEMPLATE}"
}

create_container() {
  CURRENT_STEP="LXC-Container erstellen"
  msg_info "$CURRENT_STEP"

  local net_config
  vmid_is_available "$CTID" ||
    fatal "Die Container-ID ${CTID} ist nicht mehr clusterweit verfügbar."

  if [[ "$IPV4_MODE" == "dhcp" ]]; then
    net_config="name=eth0,bridge=${BRIDGE},ip=dhcp,type=veth"
  else
    net_config="name=eth0,bridge=${BRIDGE},ip=${IPV4_ADDRESS},gw=${IPV4_GATEWAY},type=veth"
  fi

  if ! pct create "$CTID" "$TEMPLATE_VOLUME" \
    --arch amd64 \
    --cores "$CORES" \
    --hostname "$CT_HOSTNAME" \
    --memory "$MEMORY" \
    --net0 "$net_config" \
    --onboot 1 \
    --ostype ubuntu \
    --rootfs "${STORAGE}:${DISK}" \
    --start 0 \
    --swap "$SWAP" \
    --tags "codex;devbox" \
    --timezone host \
    --unprivileged 1; then
    if pct config "$CTID" >/dev/null 2>&1; then
      CT_CREATED=1
    fi
    return 1
  fi

  CT_CREATED=1
  pct start "$CTID"
  msg_ok "Container ${CTID} erstellt und gestartet"
}

wait_for_container() {
  CURRENT_STEP="Container-Start abwarten"
  msg_info "$CURRENT_STEP"

  local _attempt
  for _attempt in {1..60}; do
    if pct exec "$CTID" -- true >/dev/null 2>&1; then
      msg_ok "Container ist erreichbar"
      return 0
    fi
    sleep 2
  done

  fatal "Der Container ist nach 120 Sekunden nicht erreichbar."
}

wait_for_network() {
  CURRENT_STEP="Netzwerk und DNS prüfen"
  msg_info "$CURRENT_STEP"

  local required_hosts=(
    archive.ubuntu.com
    chatgpt.com
    deb.nodesource.com
    security.ubuntu.com
  )
  local missing_hosts=()
  local _attempt
  for _attempt in {1..60}; do
    # shellcheck disable=SC2016 # Expansion erfolgt absichtlich im Container.
    if pct exec "$CTID" -- sh -c '
      for host do
        getent ahostsv4 "$host" >/dev/null || exit 1
      done
    ' sh "${required_hosts[@]}" >/dev/null 2>&1; then
      msg_ok "Netzwerk und DNS sind verfügbar"
      return 0
    fi
    sleep 2
  done

  local host
  for host in "${required_hosts[@]}"; do
    if ! pct exec "$CTID" -- getent ahostsv4 "$host" >/dev/null 2>&1; then
      missing_hosts+=("$host")
    fi
  done

  fatal "DNS-Auflösung im Container fehlgeschlagen: ${missing_hosts[*]:-unbekannter Netzwerkfehler}."
}

install_devbox() {
  CURRENT_STEP="Entwicklungsumgebung installieren"
  msg_info "$CURRENT_STEP"

  pct exec "$CTID" -- env \
    ALLOW_AGENT_FORWARDING="$ALLOW_AGENT_FORWARDING" \
    CODEX_RELEASE="$CODEX_RELEASE" \
    CT_HOSTNAME="$CT_HOSTNAME" \
    DEV_USER="$DEV_USER" \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    NODESOURCE_KEY_FINGERPRINT="$NODESOURCE_KEY_FINGERPRINT" \
    NODE_MAJOR="$NODE_MAJOR" \
    SSH_PUBLIC_KEY="$SSH_PUBLIC_KEY" \
    bash -s <<'INNER'
set -Eeuo pipefail
umask 022

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

INNER_STEP="Provisionierung initialisieren"
nodesource_key=""
codex_installer=""
codex_version_output=""
fd_binary=""
gpg_home=""
sshd_effective=""

cleanup() {
  [[ -z "$nodesource_key" ]] || rm -f "$nodesource_key"
  [[ -z "$codex_installer" ]] || rm -f "$codex_installer"
  [[ -z "$gpg_home" ]] || rm -rf -- "$gpg_home"
}
trap cleanup EXIT

on_inner_error() {
  local code=$?
  local line="${BASH_LINENO[0]:-${LINENO}}"
  local command="${BASH_COMMAND:-unbekannt}"

  trap - ERR
  command="${command%%$'\n'*}"
  if ((${#command} > 200)); then
    command="${command:0:197}..."
  fi

  printf '\nProvisionierung im Container fehlgeschlagen.\n' >&2
  printf 'Teilschritt: %s\n' "$INNER_STEP" >&2
  printf 'Innere Zeile: %s\n' "$line" >&2
  printf 'Kommando: %s\n' "$command" >&2
  exit "$code"
}
trap on_inner_error ERR

log() {
  INNER_STEP="$*"
  printf '\n==> %s\n' "$*"
}

apt_get() {
  apt-get \
    -o Acquire::Retries=5 \
    -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 \
    -o APT::Update::Error-Mode=any \
    -o DPkg::Lock::Timeout=120 \
    "$@"
}

run_as_dev() {
  sudo -u "$DEV_USER" -H sh -c '
    cd "$HOME"
    exec "$@"
  ' sh "$@"
}

assert_sshd_setting() {
  local key="$1"
  local expected="$2"
  local actual

  actual="$(
    awk -v key="$key" '
      $1 == key {
        $1=""
        sub(/^[[:space:]]+/, "")
        print
        exit
      }
    ' <<<"$sshd_effective"
  )"
  [[ "$actual" == "$expected" ]] ||
    {
      printf 'Unerwartete effektive SSH-Einstellung %s: %s\n' \
        "$key" "${actual:-<fehlt>}" >&2
      exit 1
    }
}

download() {
  local url="$1"
  local destination="$2"

  curl \
    --proto '=https' \
    --tlsv1.2 \
    --connect-timeout 15 \
    --max-time 300 \
    --retry 5 \
    --retry-all-errors \
    --fail \
    --silent \
    --show-error \
    --location \
    --output "$destination" \
    "$url"
}

[[ "$DEV_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$DEV_USER" != "root" ]] ||
  {
    printf 'Ungültiger Entwickler-Benutzer.\n' >&2
    exit 1
  }
[[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] ||
  {
    printf 'Ungültiger Container-Hostname.\n' >&2
    exit 1
  }
[[ "$ALLOW_AGENT_FORWARDING" =~ ^(yes|no)$ ]] ||
  {
    printf 'Ungültige Agent-Forwarding-Einstellung.\n' >&2
    exit 1
  }
[[ "$NODE_MAJOR" =~ ^(22|24)$ ]] ||
  {
    printf 'Nicht unterstützte Node.js-Hauptversion.\n' >&2
    exit 1
  }
[[ "$CODEX_RELEASE" == "latest" ||
  "$CODEX_RELEASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta)(\.[0-9]+)?)?$ ]] ||
  {
    printf 'Ungültige Codex-Version.\n' >&2
    exit 1
  }

log "APT-Paketlisten aktualisieren"
apt_get update

log "Ubuntu-Sicherheits- und Paketupdates installieren"
apt_get full-upgrade -y

log "Basispakete installieren"
apt_get install -y --no-install-recommends \
  bash-completion \
  build-essential \
  ca-certificates \
  curl \
  fd-find \
  git \
  git-lfs \
  gnupg \
  jq \
  less \
  nano \
  openssh-server \
  pipx \
  python3 \
  python3-pip \
  python3-venv \
  ripgrep \
  rsync \
  shellcheck \
  sudo \
  tmux \
  unattended-upgrades \
  unzip \
  vim \
  wget \
  zip

log "Node.js ${NODE_MAJOR} installieren"
install -d -m 0755 /usr/share/keyrings
nodesource_key="$(mktemp)"
gpg_home="$(mktemp -d)"
chmod 0700 "$gpg_home"
download \
  "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
  "$nodesource_key"

nodesource_key_info="$(
  GNUPGHOME="$gpg_home" \
    gpg --batch --show-keys --with-colons "$nodesource_key"
)"
nodesource_pub_count="$(
  awk -F: '$1 == "pub" { count++ } END { print count + 0 }' \
    <<<"$nodesource_key_info"
)"
nodesource_fingerprint="$(
  awk -F: '
    $1 == "pub" { in_primary=1; next }
    in_primary && $1 == "fpr" { print $10; exit }
  ' <<<"$nodesource_key_info"
)"
[[ "$nodesource_pub_count" -eq 1 &&
  "$nodesource_fingerprint" == "$NODESOURCE_KEY_FINGERPRINT" ]] ||
  {
    printf 'NodeSource-Signaturschlüssel konnte nicht verifiziert werden.\n' >&2
    exit 1
  }

GNUPGHOME="$gpg_home" gpg \
  --batch \
  --dearmor \
  --yes \
  --output /usr/share/keyrings/nodesource.gpg \
  "$nodesource_key"
chmod 0644 /usr/share/keyrings/nodesource.gpg

cat >/etc/apt/sources.list.d/nodesource.sources <<NODE_REPO
Types: deb
URIs: https://deb.nodesource.com/node_${NODE_MAJOR}.x
Suites: nodistro
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/nodesource.gpg
NODE_REPO

cat >/etc/apt/preferences.d/nodesource <<'NODE_PIN'
Package: *
Pin: origin deb.nodesource.com
Pin-Priority: 100

Package: nodejs
Pin: origin deb.nodesource.com
Pin-Priority: 600
NODE_PIN

apt_get update
apt_get install -y --no-install-recommends nodejs

[[ "$(node --version)" == "v${NODE_MAJOR}."* ]] ||
  {
    printf 'Unerwartete Node.js-Version: %s\n' "$(node --version)" >&2
    exit 1
  }

log "Entwickler-Benutzer einrichten"
if id "$DEV_USER" >/dev/null 2>&1; then
  printf 'Benutzer %s existiert im frischen Template bereits.\n' "$DEV_USER" >&2
  exit 1
fi

useradd --create-home --user-group --shell /bin/bash "$DEV_USER"
DEV_HOME="$(getent passwd "$DEV_USER" | cut -d: -f6)"
[[ "$DEV_HOME" == "/home/${DEV_USER}" ]] ||
  {
    printf 'Unerwartetes Home-Verzeichnis für %s: %s\n' "$DEV_USER" "$DEV_HOME" >&2
    exit 1
  }

# Der Account bleibt per SSH auf Public-Key-Authentifizierung beschränkt.
# Ein leeres lokales Passwort verhindert, dass OpenSSH den Account als
# vollständig gesperrt behandelt; Passwort-Login ist in sshd deaktiviert.
passwd --delete "$DEV_USER"
usermod -aG sudo "$DEV_USER"

printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$DEV_USER" \
  >/etc/sudoers.d/90-codex-devbox
chmod 0440 /etc/sudoers.d/90-codex-devbox
visudo -cf /etc/sudoers.d/90-codex-devbox

install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" "${DEV_HOME}/.ssh"
printf '%s\n' "$SSH_PUBLIC_KEY" >"${DEV_HOME}/.ssh/authorized_keys"
chown "$DEV_USER:$DEV_USER" "${DEV_HOME}/.ssh/authorized_keys"
chmod 0600 "${DEV_HOME}/.ssh/authorized_keys"

install -d -m 0755 -o "$DEV_USER" -g "$DEV_USER" "${DEV_HOME}/workspace"

log "Codex CLI ${CODEX_RELEASE} installieren"
codex_installer="$(mktemp)"
download "https://chatgpt.com/codex/install.sh" "$codex_installer"
chmod 0755 "$codex_installer"
run_as_dev env \
  CODEX_INSTALL_DIR="${DEV_HOME}/.local/bin" \
  CODEX_NON_INTERACTIVE=true \
  CODEX_RELEASE="$CODEX_RELEASE" \
  PATH="${DEV_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin" \
  sh "$codex_installer"

fd_binary="$(command -v fdfind || true)"
if [[ -z "$fd_binary" && -x /usr/lib/cargo/bin/fd ]]; then
  fd_binary="/usr/lib/cargo/bin/fd"
fi
[[ -n "$fd_binary" && -x "$fd_binary" ]] ||
  {
    printf 'Das Paket fd-find enthält keine ausführbare fd-Binärdatei.\n' >&2
    exit 1
  }
ln -sfn -- "$fd_binary" /usr/local/bin/fd
[[ -x /usr/local/bin/fd ]]

log "SSH absichern"
install -d -m 0755 /etc/ssh/sshd_config.d
rm -f /etc/ssh/sshd_config.d/60-codex-devbox.conf
cat >/etc/ssh/sshd_config.d/00-codex-devbox.conf <<SSHD
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers ${DEV_USER}
AllowAgentForwarding ${ALLOW_AGENT_FORWARDING}
AllowTcpForwarding no
AllowStreamLocalForwarding no
X11Forwarding no
PermitTunnel no
PermitUserEnvironment no
GatewayPorts no
UseDNS no
LogLevel VERBOSE
LoginGraceTime 30
MaxAuthTries 3
ClientAliveInterval 60
ClientAliveCountMax 3
SSHD
chmod 0644 /etc/ssh/sshd_config.d/00-codex-devbox.conf

# In einem frisch gestarteten Container existiert das flüchtige Runtime-
# Verzeichnis möglicherweise noch nicht, wenn sshd erstmals geprüft wird.
install -d -m 0755 /run/sshd
/usr/sbin/sshd -t
sshd_effective="$(
  /usr/sbin/sshd -T \
    -C "user=${DEV_USER},host=${CT_HOSTNAME},addr=127.0.0.1,laddr=127.0.0.1,lport=22"
)"
assert_sshd_setting permitrootlogin no
assert_sshd_setting passwordauthentication no
assert_sshd_setting permitemptypasswords no
assert_sshd_setting kbdinteractiveauthentication no
assert_sshd_setting pubkeyauthentication yes
assert_sshd_setting authenticationmethods publickey
assert_sshd_setting allowusers "$DEV_USER"
assert_sshd_setting allowagentforwarding "$ALLOW_AGENT_FORWARDING"
assert_sshd_setting allowtcpforwarding no
assert_sshd_setting allowstreamlocalforwarding no
assert_sshd_setting x11forwarding no
assert_sshd_setting permittunnel no
assert_sshd_setting permituserenvironment no
assert_sshd_setting gatewayports no
assert_sshd_setting usedns no
assert_sshd_setting loglevel VERBOSE
systemctl enable ssh.service
systemctl restart ssh.service

log "Shell und Workspace konfigurieren"
cat >/etc/profile.d/codex-devbox.sh <<'PROFILE'
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
PROFILE
chmod 0644 /etc/profile.d/codex-devbox.sh

cat >>"${DEV_HOME}/.bashrc" <<'BASHRC'

# Codex Dev Box
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
if [[ $- == *i* ]] && [[ -d "$HOME/workspace" ]]; then
  cd "$HOME/workspace"
fi
BASHRC

chown "$DEV_USER:$DEV_USER" "${DEV_HOME}/.bashrc"

log "Git LFS und automatische Sicherheitsupdates aktivieren"
run_as_dev git lfs install --skip-repo
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'AUTO_UPGRADES'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
AUTO_UPGRADES
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

log "Installation prüfen"
command -v node
command -v npm
command -v git
command -v python3
command -v rg
command -v fd
node --version
npm --version
git lfs version
python3 --version
rg --version
fd --version
codex_version_output="$(
  run_as_dev "${DEV_HOME}/.local/bin/codex" --version
)"
printf '%s\n' "$codex_version_output"
if [[ "$CODEX_RELEASE" != "latest" &&
  "$codex_version_output" != *"$CODEX_RELEASE"* ]]; then
  printf 'Installierte Codex-Version entspricht nicht %s: %s\n' \
    "$CODEX_RELEASE" "$codex_version_output" >&2
  exit 1
fi
run_as_dev test -w "${DEV_HOME}/workspace"
run_as_dev sudo -n true
[[ "$(stat -c '%U:%G:%a' "${DEV_HOME}/.ssh")" == \
  "${DEV_USER}:${DEV_USER}:700" ]]
[[ "$(stat -c '%U:%G:%a' "${DEV_HOME}/.ssh/authorized_keys")" == \
  "${DEV_USER}:${DEV_USER}:600" ]]
/usr/sbin/sshd -t
systemctl is-active --quiet ssh.service
systemctl is-enabled --quiet ssh.service
systemctl is-enabled --quiet apt-daily.timer
systemctl is-enabled --quiet apt-daily-upgrade.timer

apt-get clean
INNER

  msg_ok "Entwicklungsumgebung installiert"
}

show_summary() {
  CURRENT_STEP="Installation abschließen"

  local ip=""
  local forward_agent_setting="no"
  ip="$(
    pct exec "$CTID" -- hostname -I 2>/dev/null |
      awk '{ print $1 }'
  )"

  [[ -n "$ip" ]] || ip="<CONTAINER-IP>"
  if [[ "$ALLOW_AGENT_FORWARDING" == "yes" ]]; then
    forward_agent_setting="yes"
  fi

  cat <<EOF

${GN}${BOLD}Installation erfolgreich abgeschlossen${CL}

Container:  ${CTID}
Hostname:   ${CT_HOSTNAME}
IP-Adresse: ${ip}
Benutzer:   ${DEV_USER}
Workspace:  /home/${DEV_USER}/workspace
SSH-Key:    ${SSH_KEY_FINGERPRINT}
Logdatei:   ${LOG_FILE}

Lokale SSH-Konfiguration (~/.ssh/config):

Host ${CT_HOSTNAME}
    HostName ${ip}
    User ${DEV_USER}
    ForwardAgent ${forward_agent_setting}
    ServerAliveInterval 60
    ServerAliveCountMax 3

Anschließend:

  ssh ${CT_HOSTNAME}
  cd ~/workspace
  codex

Beim ersten Start bietet Codex die Anmeldung an.
Hinweis: Der Benutzer darf über sudo weitere benötigte Werkzeuge installieren.
EOF
}

main() {
  parse_args "$@"
  trap on_error ERR
  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM
  trap 'on_signal HUP' HUP

  header

  CURRENT_STEP="Proxmox-Umgebung prüfen"
  require_pve
  init_runtime
  msg_info "Installationslog: ${LOG_FILE}"
  install_dialog
  load_defaults

  local mode
  mode="$(
    whiptail \
      --backtitle "$APP" \
      --title "Installationsmodus" \
      --menu "Installationsmodus auswählen:" \
      14 78 2 \
      standard "Empfohlen: 4 CPU, 8 GiB RAM, 32 GiB Disk, DHCP" \
      advanced "Ressourcen, Storage und Netzwerk selbst festlegen" \
      3>&1 1>&2 2>&3
  )" || exit 0

  if [[ "$mode" == "advanced" ]]; then
    advanced_settings || exit 0
  fi

  read_ssh_key || exit 0
  validate_settings
  confirm_settings || exit 0

  header
  find_template
  create_container
  wait_for_container
  wait_for_network
  install_devbox
  show_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
