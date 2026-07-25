#!/usr/bin/env bash
# Codex Dev Box - Proxmox VE LXC installer
# Ubuntu 24.04 LTS, SSH key access, Codex CLI, no Docker
# License: MIT

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

APP="Codex Dev Box"
VERSION="1.0.0"
UBUNTU_VERSION="24.04"

DEFAULT_HOSTNAME="codex-devbox"
DEFAULT_CORES="4"
DEFAULT_MEMORY="8192"
DEFAULT_SWAP="512"
DEFAULT_DISK="32"
DEFAULT_USER="dev"
DEFAULT_BRIDGE="vmbr0"

LOG_FILE="/tmp/codex-devbox-install-$(date +%Y%m%d-%H%M%S).log"
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

msg_info() { echo -e "${INFO} ${YW}$*${CL}"; }
msg_ok()   { echo -e "${CHECK} ${GN}$*${CL}"; }
fatal()    { echo -e "${CROSS} ${RD}$*${CL}" >&2; exit 1; }

on_error() {
  local code=$?
  local line="${BASH_LINENO[0]:-${LINENO}}"
  local command="${BASH_COMMAND:-unbekannt}"

  trap - ERR
  echo >&2
  echo -e "${CROSS} ${RD}Installation fehlgeschlagen.${CL}" >&2
  echo -e "${RD}Schritt:     ${CURRENT_STEP}${CL}" >&2
  echo -e "${RD}Zeile:       ${line}${CL}" >&2
  echo -e "${RD}Exit-Code:   ${code}${CL}" >&2
  echo -e "${RD}Befehl:      ${command}${CL}" >&2
  echo -e "${RD}Logdatei:    ${LOG_FILE}${CL}" >&2

  if [[ "${CT_CREATED}" -eq 1 ]] && pct status "${CTID:-0}" >/dev/null 2>&1; then
    echo -e "${YW}Der unvollständige Container ${CTID} wurde zur Diagnose beibehalten.${CL}" >&2
    echo -e "${YW}Entfernen: pct stop ${CTID} 2>/dev/null || true; pct destroy ${CTID} --purge${CL}" >&2
  fi

  exit "$code"
}
trap on_error ERR

header() {
  clear 2>/dev/null || true
  cat <<'BANNER'
   ______          __             ____             ____
  / ____/___  ____/ /___  _  __  / __ \___  _   __/ __ )____  _  __
 / /   / __ \/ __  / __ \| |/_/ / / / / _ \| | / / __  / __ \| |/_/
/ /___/ /_/ / /_/ / /_/ />  <  / /_/ /  __/| |/ / /_/ / /_/ />  <
\____/\____/\__,_/\____/_/|_| /_____/\___/ |___/_____/\____/_/|_|
BANNER
  echo -e "${BOLD}Proxmox VE LXC Installer – Ubuntu ${UBUNTU_VERSION}, SSH und Codex CLI${CL}"
  echo -e "Version ${VERSION}\n"
}

require_pve() {
  [[ "${EUID}" -eq 0 ]] || fatal "Dieses Skript muss als root ausgeführt werden."

  local cmd
  for cmd in pct pveam pvesm pvesh; do
    command -v "$cmd" >/dev/null 2>&1 ||
      fatal "${cmd} fehlt. Das Skript muss auf einem Proxmox-VE-Host laufen."
  done
}

install_dialog() {
  if ! command -v whiptail >/dev/null 2>&1; then
    msg_info "Installiere whiptail"
    apt-get update
    apt-get install -y whiptail
  fi
}

next_ctid() {
  pvesh get /cluster/nextid
}

rootfs_storages() {
  pvesm status -content rootdir 2>/dev/null |
    awk 'NR > 1 && $3 == "active" { print $1 }'
}

template_storages() {
  pvesm status -content vztmpl 2>/dev/null |
    awk 'NR > 1 && $3 == "active" { print $1 }'
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
  HOSTNAME="$DEFAULT_HOSTNAME"
  CORES="$DEFAULT_CORES"
  MEMORY="$DEFAULT_MEMORY"
  SWAP="$DEFAULT_SWAP"
  DISK="$DEFAULT_DISK"
  DEV_USER="$DEFAULT_USER"
  BRIDGE="$DEFAULT_BRIDGE"
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
  HOSTNAME="$(dialog_input "Hostname" "Hostname:" "$HOSTNAME")" || return 1
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

  for key_file in /root/.ssh/id_ed25519.pub /root/.ssh/id_ecdsa.pub /root/.ssh/id_rsa.pub; do
    if [[ -s "$key_file" ]]; then
      if whiptail \
        --backtitle "$APP" \
        --title "SSH-Schlüssel" \
        --yesno "Vorhandenen Schlüssel verwenden?\n\n${key_file}" \
        11 72; then
        key="$(<"$key_file")"
        break
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

  case "$key" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *)
      SSH_PUBLIC_KEY="$key"
      ;;
    *)
      fatal "Der eingegebene öffentliche SSH-Schlüssel ist ungültig."
      ;;
  esac
}

validate_settings() {
  [[ "$CTID" =~ ^[1-9][0-9]{2,8}$ ]] ||
    fatal "Die Container-ID muss eine Zahl ab 100 sein."

  [[ "$CORES" =~ ^[1-9][0-9]*$ ]] ||
    fatal "Die Anzahl der CPU-Kerne ist ungültig."

  [[ "$MEMORY" =~ ^[1-9][0-9]*$ ]] ||
    fatal "Die RAM-Angabe ist ungültig."

  [[ "$SWAP" =~ ^[0-9]+$ ]] ||
    fatal "Die Swap-Angabe ist ungültig."

  [[ "$DISK" =~ ^[1-9][0-9]*$ ]] ||
    fatal "Die Disk-Angabe ist ungültig."

  [[ "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] ||
    fatal "Der Hostname ist ungültig."

  [[ "$DEV_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
    fatal "Der Benutzername ist ungültig."

  [[ "$BRIDGE" =~ ^[a-zA-Z0-9_.:-]+$ ]] ||
    fatal "Der Bridge-Name ist ungültig."

  if [[ "$IPV4_MODE" == "static" ]]; then
    [[ "$IPV4_ADDRESS" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])$ ]] ||
      fatal "Die statische IPv4-Adresse ist ungültig."

    [[ "$IPV4_GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] ||
      fatal "Das IPv4-Gateway ist ungültig."
  fi

  if pct config "$CTID" >/dev/null 2>&1; then
    fatal "Die Container-ID ${CTID} ist bereits belegt."
  fi

  pvesm status -storage "$STORAGE" >/dev/null 2>&1 ||
    fatal "Root-Disk-Storage '${STORAGE}' wurde nicht gefunden."

  pvesm status -storage "$TEMPLATE_STORAGE" >/dev/null 2>&1 ||
    fatal "Template-Storage '${TEMPLATE_STORAGE}' wurde nicht gefunden."
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
Hostname:          ${HOSTNAME}
CPU:               ${CORES}
RAM:               ${MEMORY} MiB
Swap:              ${SWAP} MiB
Disk:              ${DISK} GiB
Root-Disk-Storage: ${STORAGE}
Template-Storage:  ${TEMPLATE_STORAGE}
Bridge:            ${BRIDGE}
IPv4:              ${network_summary}
Benutzer:          ${DEV_USER}

Docker wird nicht installiert." \
    24 78
}

find_template() {
  CURRENT_STEP="Ubuntu-LXC-Template vorbereiten"
  msg_info "$CURRENT_STEP"

  pveam update

  TEMPLATE="$(
    pveam available --section system |
      awk -v version="ubuntu-${UBUNTU_VERSION}-standard" '
        $2 ~ version {
          print $2
        }
      ' |
      sort -V |
      tail -n 1
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
  if [[ "$IPV4_MODE" == "dhcp" ]]; then
    net_config="name=eth0,bridge=${BRIDGE},ip=dhcp,type=veth"
  else
    net_config="name=eth0,bridge=${BRIDGE},ip=${IPV4_ADDRESS},gw=${IPV4_GATEWAY},type=veth"
  fi

  pct create "$CTID" "$TEMPLATE_VOLUME" \
    --arch amd64 \
    --cores "$CORES" \
    --hostname "$HOSTNAME" \
    --memory "$MEMORY" \
    --net0 "$net_config" \
    --onboot 1 \
    --ostype ubuntu \
    --rootfs "${STORAGE}:${DISK}" \
    --start 0 \
    --swap "$SWAP" \
    --tags "codex;devbox" \
    --timezone host \
    --unprivileged 1

  CT_CREATED=1
  pct start "$CTID"
  msg_ok "Container ${CTID} erstellt und gestartet"
}

wait_for_container() {
  CURRENT_STEP="Container-Start abwarten"
  msg_info "$CURRENT_STEP"

  local attempt
  for attempt in {1..60}; do
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

  local attempt
  for attempt in {1..60}; do
    if pct exec "$CTID" -- getent ahostsv4 archive.ubuntu.com >/dev/null 2>&1; then
      msg_ok "Netzwerk und DNS sind verfügbar"
      return 0
    fi
    sleep 2
  done

  fatal "Im Container ist nach 120 Sekunden keine Netzwerk-/DNS-Verbindung verfügbar."
}

install_devbox() {
  CURRENT_STEP="Entwicklungsumgebung installieren"
  msg_info "$CURRENT_STEP"

  pct exec "$CTID" -- env \
    DEV_USER="$DEV_USER" \
    SSH_PUBLIC_KEY="$SSH_PUBLIC_KEY" \
    bash -s <<'INNER'
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

log() {
  printf '\n==> %s\n' "$*"
}

log "APT-Paketlisten aktualisieren"
apt-get update

log "Basispakete installieren"
apt-get install -y --no-install-recommends \
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

log "Node.js 22 installieren"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
  gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg

cat >/etc/apt/sources.list.d/nodesource.list <<'NODE_REPO'
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main
NODE_REPO

apt-get update
apt-get install -y --no-install-recommends nodejs

log "Entwickler-Benutzer einrichten"
if ! id "$DEV_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DEV_USER"
fi

usermod -aG sudo "$DEV_USER"

cat >"/etc/sudoers.d/90-codex-devbox" <<SUDOERS
${DEV_USER} ALL=(ALL:ALL) NOPASSWD:ALL
SUDOERS
chmod 0440 /etc/sudoers.d/90-codex-devbox
visudo -cf /etc/sudoers.d/90-codex-devbox

install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" "/home/${DEV_USER}/.ssh"
printf '%s\n' "$SSH_PUBLIC_KEY" >"/home/${DEV_USER}/.ssh/authorized_keys"
chown "$DEV_USER:$DEV_USER" "/home/${DEV_USER}/.ssh/authorized_keys"
chmod 0600 "/home/${DEV_USER}/.ssh/authorized_keys"

install -d -m 0755 -o "$DEV_USER" -g "$DEV_USER" "/home/${DEV_USER}/workspace"

log "Codex CLI installieren"
npm install --global @openai/codex

if [[ -x /usr/bin/fdfind ]]; then
  ln -sfn /usr/bin/fdfind /usr/local/bin/fd
fi

log "SSH absichern"
cat >/etc/ssh/sshd_config.d/60-codex-devbox.conf <<SSHD
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers ${DEV_USER}
AllowAgentForwarding yes
X11Forwarding no
ClientAliveInterval 60
ClientAliveCountMax 3
SSHD

/usr/sbin/sshd -t
systemctl enable ssh
systemctl restart ssh

log "Shell und Workspace konfigurieren"
cat >/etc/profile.d/codex-devbox.sh <<'PROFILE'
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
PROFILE
chmod 0644 /etc/profile.d/codex-devbox.sh

cat >>"/home/${DEV_USER}/.bashrc" <<'BASHRC'

# Codex Dev Box
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
if [[ $- == *i* ]] && [[ -d "$HOME/workspace" ]]; then
  cd "$HOME/workspace"
fi
BASHRC

chown "$DEV_USER:$DEV_USER" "/home/${DEV_USER}/.bashrc"

log "Git LFS und automatische Sicherheitsupdates aktivieren"
sudo -u "$DEV_USER" -H git lfs install --skip-repo
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

log "Installation prüfen"
command -v codex
command -v node
command -v npm
command -v git
command -v python3
command -v rg
command -v fd
sudo -u "$DEV_USER" -H bash -lc 'codex --version'

apt-get clean
INNER

  msg_ok "Entwicklungsumgebung installiert"
}

show_summary() {
  CURRENT_STEP="Installation abschließen"

  local ip=""
  ip="$(
    pct exec "$CTID" -- hostname -I 2>/dev/null |
      awk '{ print $1 }'
  )"

  [[ -n "$ip" ]] || ip="<CONTAINER-IP>"

  cat <<EOF

${GN}${BOLD}Installation erfolgreich abgeschlossen${CL}

Container:  ${CTID}
Hostname:   ${HOSTNAME}
IP-Adresse: ${ip}
Benutzer:   ${DEV_USER}
Workspace:  /home/${DEV_USER}/workspace
Logdatei:   ${LOG_FILE}

Lokale SSH-Konfiguration (~/.ssh/config):

Host ${HOSTNAME}
    HostName ${ip}
    User ${DEV_USER}
    IdentityFile ~/.ssh/id_ed25519
    ForwardAgent yes
    ServerAliveInterval 60
    ServerAliveCountMax 3

Anschließend:

  ssh ${HOSTNAME}
  codex login --device-auth
  cd ~/workspace
  codex

Hinweis: Codex darf über sudo weitere benötigte Werkzeuge installieren.
EOF
}

main() {
  exec > >(tee -a "$LOG_FILE") 2>&1

  header

  CURRENT_STEP="Proxmox-Umgebung prüfen"
  require_pve
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

main "$@"
