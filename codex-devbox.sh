#!/usr/bin/env bash
# Codex Dev Box - Proxmox VE LXC installer
# License: MIT
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

APP="Codex Dev Box"
DEFAULT_HOSTNAME="codex-devbox"
DEFAULT_CORES=4
DEFAULT_MEMORY=8192
DEFAULT_SWAP=512
DEFAULT_DISK=32
DEFAULT_USER="dev"
DEFAULT_BRIDGE="vmbr0"
UBUNTU_VERSION="24.04"
YW='\033[33m'; BL='\033[36m'; GN='\033[1;92m'; RD='\033[01;31m'; CL='\033[m'; BOLD='\033[1m'
CHECK="${GN}✓${CL}"; CROSS="${RD}✗${CL}"; INFO="${BL}ℹ${CL}"
msg_info(){ echo -e "${INFO} ${YW}$*${CL}"; }
msg_ok(){ echo -e "${CHECK} ${GN}$*${CL}"; }
fatal(){ echo -e "${CROSS} ${RD}$*${CL}" >&2; exit 1; }
trap 'code=$?; echo -e "\n${CROSS} ${RD}Fehler in Zeile ${BASH_LINENO[0]:-?} (Exit-Code ${code}).${CL}" >&2; exit $code' ERR

header(){
  clear 2>/dev/null || true
  cat <<'BANNER'
   ______          __             ____             ____
  / ____/___  ____/ /___  _  __  / __ \___  _   __/ __ )____  _  __
 / /   / __ \/ __  / __ \| |/_/ / / / / _ \| | / / __  / __ \| |/_/
/ /___/ /_/ / /_/ / /_/ />  <  / /_/ /  __/| |/ / /_/ / /_/ />  <
\____/\____/\__,_/\____/_/|_| /_____/\___/ |___/_____/\____/_/|_|
BANNER
  echo -e "${BOLD}Proxmox VE LXC Installer – Ubuntu ${UBUNTU_VERSION}, SSH und Codex CLI${CL}\n"
}

require_pve(){
  [[ $EUID -eq 0 ]] || fatal "Als root ausführen."
  for cmd in pct pveam pvesm pvesh; do command -v "$cmd" >/dev/null || fatal "$cmd fehlt; bitte auf einem Proxmox-VE-Host ausführen."; done
}
install_dialog(){ command -v whiptail >/dev/null || { apt-get update -qq; apt-get install -y -qq whiptail >/dev/null; }; }
next_ctid(){ pvesh get /cluster/nextid; }
storage_list(){ pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}'; }
template_storage_list(){ pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}'; }
choose(){ local title=$1 prompt=$2 def=$3; shift 3; local opts=() x; for x in "$@"; do [[ $x == "$def" ]] && opts+=("$x" "" ON) || opts+=("$x" "" OFF); done; whiptail --backtitle "$APP" --title "$title" --radiolist "$prompt" 18 72 10 "${opts[@]}" 3>&1 1>&2 2>&3; }

read_key(){
  local key="" f
  for f in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub; do
    if [[ -s $f ]] && whiptail --backtitle "$APP" --title "SSH-Schlüssel" --yesno "${f} verwenden?" 9 65; then key=$(<"$f"); break; fi
  done
  [[ -n $key ]] || key=$(whiptail --backtitle "$APP" --title "SSH-Schlüssel" --inputbox "Öffentlichen SSH-Schlüssel einfügen:" 10 78 3>&1 1>&2 2>&3)
  [[ $key =~ ^ssh-(ed25519|rsa)[[:space:]]|^ecdsa-sha2- ]] || fatal "Ungültiger öffentlicher SSH-Schlüssel."
  SSH_PUBLIC_KEY=$key
}

defaults(){
  CTID=$(next_ctid); HOSTNAME=$DEFAULT_HOSTNAME; CORES=$DEFAULT_CORES; MEMORY=$DEFAULT_MEMORY; SWAP=$DEFAULT_SWAP; DISK=$DEFAULT_DISK; DEV_USER=$DEFAULT_USER; BRIDGE=$DEFAULT_BRIDGE; IPV4=dhcp
  mapfile -t STORAGES < <(storage_list); mapfile -t TEMPLATE_STORAGES < <(template_storage_list)
  ((${#STORAGES[@]})) || fatal "Kein Storage für LXC-Rootdisks gefunden."
  ((${#TEMPLATE_STORAGES[@]})) || fatal "Kein Storage für LXC-Templates gefunden."
  STORAGE=${STORAGES[0]}; TEMPLATE_STORAGE=${TEMPLATE_STORAGES[0]}
}
advanced(){
  CTID=$(whiptail --backtitle "$APP" --inputbox "Container-ID" 8 60 "$CTID" 3>&1 1>&2 2>&3)
  HOSTNAME=$(whiptail --backtitle "$APP" --inputbox "Hostname" 8 60 "$HOSTNAME" 3>&1 1>&2 2>&3)
  CORES=$(whiptail --backtitle "$APP" --inputbox "CPU-Kerne" 8 60 "$CORES" 3>&1 1>&2 2>&3)
  MEMORY=$(whiptail --backtitle "$APP" --inputbox "RAM in MiB" 8 60 "$MEMORY" 3>&1 1>&2 2>&3)
  SWAP=$(whiptail --backtitle "$APP" --inputbox "Swap in MiB" 8 60 "$SWAP" 3>&1 1>&2 2>&3)
  DISK=$(whiptail --backtitle "$APP" --inputbox "Disk in GiB" 8 60 "$DISK" 3>&1 1>&2 2>&3)
  DEV_USER=$(whiptail --backtitle "$APP" --inputbox "Entwickler-Benutzer" 8 60 "$DEV_USER" 3>&1 1>&2 2>&3)
  STORAGE=$(choose "Storage" "Rootdisk-Storage" "$STORAGE" "${STORAGES[@]}")
  TEMPLATE_STORAGE=$(choose "Template" "Template-Storage" "$TEMPLATE_STORAGE" "${TEMPLATE_STORAGES[@]}")
  BRIDGE=$(whiptail --backtitle "$APP" --inputbox "Netzwerk-Bridge" 8 60 "$BRIDGE" 3>&1 1>&2 2>&3)
  local mode addr gw
  mode=$(whiptail --backtitle "$APP" --menu "IPv4" 12 65 2 dhcp "Automatisch" static "Statisch" 3>&1 1>&2 2>&3)
  if [[ $mode == static ]]; then
    addr=$(whiptail --backtitle "$APP" --inputbox "Adresse, z. B. 192.168.1.50/24" 8 70 "" 3>&1 1>&2 2>&3)
    gw=$(whiptail --backtitle "$APP" --inputbox "Gateway, z. B. 192.168.1.1" 8 70 "" 3>&1 1>&2 2>&3)
    IPV4="$addr,gw=$gw"
  fi
}
validate(){
  [[ $CTID =~ ^[0-9]+$ && $CORES =~ ^[1-9][0-9]*$ && $MEMORY =~ ^[1-9][0-9]*$ && $SWAP =~ ^[0-9]+$ && $DISK =~ ^[1-9][0-9]*$ ]] || fatal "Ungültige Ressourcenangabe."
  [[ $DEV_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || fatal "Ungültiger Benutzername."
  pct status "$CTID" >/dev/null 2>&1 && fatal "CTID $CTID ist bereits belegt."
}
find_template(){
  msg_info "Suche Ubuntu-${UBUNTU_VERSION}-Template"
  pveam update >/dev/null
  TEMPLATE=$(pveam available --section system | awk -v v="ubuntu-${UBUNTU_VERSION}" '$2 ~ v && $2 ~ /standard/ {print $2; exit}')
  [[ -n $TEMPLATE ]] || fatal "Ubuntu-${UBUNTU_VERSION}-Template nicht gefunden."
  TEMPLATE_VOLUME="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
  pveam list "$TEMPLATE_STORAGE" | awk '{print $1}' | grep -qx "$TEMPLATE_VOLUME" || pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  msg_ok "Template bereit"
}
create_ct(){
  local net="name=eth0,bridge=${BRIDGE},ip=${IPV4}"
  msg_info "Erstelle Container ${CTID}"
  pct create "$CTID" "$TEMPLATE_VOLUME" --hostname "$HOSTNAME" --ostype ubuntu --arch amd64 --cores "$CORES" --memory "$MEMORY" --swap "$SWAP" --rootfs "${STORAGE}:${DISK}" --net0 "$net" --unprivileged 1 --onboot 1 --start 1 --tags "codex;devbox"
  msg_ok "Container erstellt"
}
wait_network(){
  msg_info "Warte auf Netzwerk"
  for _ in {1..60}; do pct exec "$CTID" -- getent hosts github.com >/dev/null 2>&1 && { msg_ok "Netzwerk verfügbar"; return; }; sleep 2; done
  fatal "Keine Netzwerk-/DNS-Verbindung im Container."
}
install_box(){
  msg_info "Installiere Entwicklungsumgebung"
  pct exec "$CTID" -- env DEV_USER="$DEV_USER" SSH_PUBLIC_KEY="$SSH_PUBLIC_KEY" bash -s <<'INNER'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get dist-upgrade -y -qq
apt-get install -y -qq ca-certificates curl wget gnupg openssh-server sudo git git-lfs build-essential python3 python3-venv python3-pip pipx jq ripgrep fd-find tmux unzip zip rsync less nano vim shellcheck unattended-upgrades
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main\n' >/etc/apt/sources.list.d/nodesource.list
apt-get update -qq && apt-get install -y -qq nodejs
id "$DEV_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$DEV_USER"
usermod -aG sudo "$DEV_USER"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$DEV_USER" >/etc/sudoers.d/90-codex-devbox
chmod 0440 /etc/sudoers.d/90-codex-devbox
install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" "/home/$DEV_USER/.ssh"
printf '%s\n' "$SSH_PUBLIC_KEY" >"/home/$DEV_USER/.ssh/authorized_keys"
chown "$DEV_USER:$DEV_USER" "/home/$DEV_USER/.ssh/authorized_keys" && chmod 0600 "/home/$DEV_USER/.ssh/authorized_keys"
install -d -m 0755 -o "$DEV_USER" -g "$DEV_USER" "/home/$DEV_USER/workspace"
ln -sfn "/home/$DEV_USER/workspace" /workspace
npm install --global @openai/codex
ln -sfn /usr/bin/fdfind /usr/local/bin/fd
cat >/etc/ssh/sshd_config.d/60-codex-devbox.conf <<SSHD
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers $DEV_USER
AllowAgentForwarding yes
X11Forwarding no
ClientAliveInterval 60
ClientAliveCountMax 3
SSHD
/usr/sbin/sshd -t
systemctl enable --now ssh
systemctl restart ssh
cat >/etc/profile.d/codex-devbox.sh <<'PROFILE'
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
PROFILE
cat >>"/home/$DEV_USER/.bashrc" <<'BASHRC'
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
cd "$HOME/workspace" 2>/dev/null || true
BASHRC
chown "$DEV_USER:$DEV_USER" "/home/$DEV_USER/.bashrc"
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
sudo -u "$DEV_USER" -H git lfs install --skip-repo >/dev/null
sudo -u "$DEV_USER" -H bash -lc 'codex --version'
apt-get autoremove -y -qq && apt-get clean
INNER
  msg_ok "Codex Dev Box installiert"
}
summary(){
  local ip; ip=$(pct exec "$CTID" -- hostname -I | awk '{print $1}'); [[ -n $ip ]] || ip='<CONTAINER-IP>'
  cat <<EOF

${GN}${BOLD}Installation abgeschlossen${CL}

Container: ${CTID} (${HOSTNAME})
IP:        ${ip}
Benutzer:  ${DEV_USER}
Workspace: /home/${DEV_USER}/workspace

Lokale ~/.ssh/config:

Host ${HOSTNAME}
    HostName ${ip}
    User ${DEV_USER}
    IdentityFile ~/.ssh/id_ed25519
    ForwardAgent yes
    ServerAliveInterval 60

Danach:
  ssh ${HOSTNAME}
  codex login --device-auth
  codex
EOF
}
main(){
  header; require_pve; install_dialog; defaults
  local mode; mode=$(whiptail --backtitle "$APP" --title "Installationsmodus" --menu "Standard: 4 CPU, 8 GiB RAM, 32 GiB Disk.\nErweitert: eigene Werte." 14 76 2 standard "Empfohlene Werte" advanced "Eigene Einstellungen" 3>&1 1>&2 2>&3) || exit 0
  [[ $mode == advanced ]] && advanced
  read_key; validate
  whiptail --backtitle "$APP" --title "Bestätigung" --yesno "Ubuntu ${UBUNTU_VERSION} LXC erstellen?\n\nCTID: $CTID\nHostname: $HOSTNAME\nCPU: $CORES\nRAM: $MEMORY MiB\nDisk: $DISK GiB\nStorage: $STORAGE\nBridge: $BRIDGE\nBenutzer: $DEV_USER" 18 68 || exit 0
  header; find_template; create_ct; wait_network; install_box; summary
}
main "$@"
