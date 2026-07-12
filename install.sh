#!/bin/bash
# VpsE Proxmox Lite — one-shot installer
# Van kale Debian 12/13 → Proxmox (LXC-only) + NAT + DHCP
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e " ${GREEN}✅${NC} $1"; }
warn() { echo -e " ${YELLOW}⚠️${NC} $1"; }
fail() { echo -e " ${RED}❌${NC} $1"; exit 1; }

echo "╔══════════════════════════════════╗"
echo "║   VpsE Proxmox Lite Installer   ║"
echo "╚══════════════════════════════════╝"
echo ""

# ─── Prerequisites ──────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  if command -v sudo &>/dev/null; then
    echo "🔄 Restarting with sudo..."
    exec sudo bash "$0" "$@"
  fi
  fail "Run as root"
fi
PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-VpsE}"
DEBIAN_CODENAME=$(grep -oP 'VERSION_CODENAME=\K\w+' /etc/os-release 2>/dev/null || echo "")
[ "$DEBIAN_CODENAME" = "bookworm" ] || [ "$DEBIAN_CODENAME" = "trixie" ] || \
  fail "Only Debian 12 (bookworm) or 13 (trixie) supported"
ok "Debian $DEBIAN_CODENAME"

PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+')
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || true)
HOSTNAME=$(hostname)

# ─── Proxmox node name ──────────────────────────────────────
DEFAULT_NAME="${HOSTNAME:-pve}"
PROXMOX_NAME="${PROXMOX_NAME:-$DEFAULT_NAME}"
echo "   Node name: $PROXMOX_NAME"

# ═════════════════════════════════════════════════════════════
# STAP 1 — Proxmox repository
# ═════════════════════════════════════════════════════════════
echo ""
echo "📦 Stap 1/7 — Proxmox repository"

echo "deb http://download.proxmox.com/debian/pve $DEBIAN_CODENAME pve-no-subscription" \
    > /etc/apt/sources.list.d/pve.list
# Disable enterprise repo (requires subscription)
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null || true
# trixie uses .sources (deb822) format — just rename to disable
mv /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.sources.disabled 2>/dev/null || true
curl -fsSL --insecure https://download.proxmox.com/debian/proxmox-release-$DEBIAN_CODENAME.gpg \
    -o /etc/apt/trusted.gpg.d/proxmox.gpg || {
  warn "GPG key download failed, retrying via insecure..."
  curl -fsSL --insecure https://download.proxmox.com/debian/proxmox-release-$DEBIAN_CODENAME.gpg \
    -o /etc/apt/trusted.gpg.d/proxmox.gpg
}
apt-get update -qq 2>/dev/null || {
  warn "apt-get update failed, retrying without quiet..."
  apt-get update 2>&1 | tail -5
}
ok "Repository gereed"

# ═════════════════════════════════════════════════════════════
# STAP 2 — /etc/hosts (pve-cluster vereist non-loopback hostname)
# ═════════════════════════════════════════════════════════════
echo ""
echo "🔧 Stap 2/7 — /etc/hosts"

sed -i '/127.0.1.1/d' /etc/hosts 2>/dev/null || true
hostnamectl set-hostname "$PROXMOX_NAME" 2>/dev/null || hostname "$PROXMOX_NAME"
if ! grep -q "$PUBLIC_IP" /etc/hosts 2>/dev/null; then
  echo "$PUBLIC_IP $PROXMOX_NAME" >> /etc/hosts
fi
ok "/etc/hosts: $PUBLIC_IP → $PROXMOX_NAME"

# ═════════════════════════════════════════════════════════════
# STAP 3 — Root wachtwoord instellen (voor Proxmox Web UI)
# ═════════════════════════════════════════════════════════════
echo ""
echo "🔑 Stap 3/7 — Set root password"
echo "root:$PROXMOX_PASSWORD" | chpasswd
ok "Root password set"

# ═════════════════════════════════════════════════════════════
# STAP 4 — Proxmox VE installeren
# ═════════════════════════════════════════════════════════════
echo ""
echo "📦 Stap 4/7 — Proxmox VE"
echo "   ⏱️  This can take 5-15 minutes..."

# We install proxmox-ve (meta-package with all dependencies including kernel + qemu)
# On OVH VPS the kernel installs fine but won't boot — that's OK, OVH uses its own kernel
# The dummy/cleanup step after this removes qemu/kvm/zfs to make it LXC-only
PVE_PKGS=(proxmox-ve)
if ! command -v pveversion &>/dev/null; then
  apt-get update 2>&1 | tail -5
  echo "grub-pc grub-pc/install_devices multiselect /dev/sda" | debconf-set-selections 2>/dev/null || true
  echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections 2>/dev/null || true
  echo "   ⏱️  Installing proxmox-ve (can take 5-15 minutes)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${PVE_PKGS[@]}" 2>&1 | tail -15 || {
    warn "proxmox-ve install failed, trying pve-manager + pve-container directly..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      pve-manager pve-cluster pve-container pve-xtermjs \
      proxmox-widget-toolkit libpve-common-perl libpve-http-server-perl 2>&1 | tail -10
  }
fi
# Verify pve-manager was actually installed
if ! dpkg -l pve-manager 2>/dev/null | grep -q '^ii'; then
  warn "pve-manager still not installed — trying fallback with dummy qemu-server..."
  apt-get install -y equivs 2>/dev/null || true
  dummy "qemu-server" "9.1.18-dummy" "Dummy for LXC-only setup" 2>/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y pve-manager pve-container 2>&1 | tail -10 || true
fi
PVE_VER=$(pveversion 2>/dev/null || dpkg -l pve-manager 2>/dev/null | awk '/^ii/{print $3}')
ok "Proxmox VE ${PVE_VER:-installed}"

# ═════════════════════════════════════════════════════════════
# STAP 5 — Onnodige packages verwijderen (LXC-only)
# ═════════════════════════════════════════════════════════════
echo ""
echo "🗑️  Stap 5/7 — Cleanup (LXC-only)"

# Temporarily disable pve-apt-hook (replaces with no-op) so dpkg stays happy
PVE_HOOK="/usr/share/proxmox-ve/pve-apt-hook"
if [ -f "$PVE_HOOK" ] && ! grep -q "VpsE" "$PVE_HOOK" 2>/dev/null; then
  cp "$PVE_HOOK" "${PVE_HOOK}.bak" 2>/dev/null || true
  cat > "$PVE_HOOK" <<-'NOOP'
#!/bin/bash
# Replaced by VpsE Proxmox Lite installer
exit 0
NOOP
  chmod 755 "$PVE_HOOK"
fi

# Also pre-load equivs-build for dummy creation
if ! command -v equivs-build &>/dev/null; then
  apt-get install -y -qq equivs 2>/dev/null
fi
dummy() {
  local name="$1" desc="$2"
  dpkg -l "$name" 2>/dev/null | grep -q "^ii" || return 0  # skip if not installed
  local d; d=$(mktemp -d)
  cat > "$d/control" <<-EOF
Section: misc
Priority: optional
Standards-Version: 4.7.0
Package: $name
Version: 9999.99.99-vpse
Maintainer: VpsE Proxmox Lite <root@localhost>
Provides: $name
Description: $desc
EOF
  (cd "$d" && equivs-build control >/dev/null 2>&1)
  dpkg -i "${d}/${name}_9999.99.99-vpse_all.deb" 2>/dev/null || true
  rm -rf "$d"
}

# Protect pve-manager from cascading removal
apt-mark hold pve-manager 2>/dev/null || true

# Remove packages only if they are installed (proxmox-ve fallback path)
for pkg in qemu-server pve-qemu-kvm spiceterm; do
  dummy "$pkg" "Dummy — LXC only"
done

dpkg --remove --force-depends \
  pve-qemu-kvm spiceterm \
  pve-edk2-firmware-legacy pve-edk2-firmware-ovmf \
  swtpm swtpm-tools swtpm-libs \
  pve-esxi-import-tools pve-nvidia-vgpu-helper \
  libspice-server1 virtiofsd \
  2>/dev/null || true

dpkg --remove --force-depends \
  ceph-common ceph-fuse libcephfs2 \
  2>/dev/null || true

if ! zpool list &>/dev/null 2>&1; then
  dpkg --remove --force-depends \
    zfsutils-linux zfs-zed libzfs7linux libzpool7linux \
    2>/dev/null || true
fi

# No perl stubs needed — we only install pve-manager, not qemu-server

# Safeguard: reinstall pve-manager if it was removed by cascading deps
if ! dpkg -l pve-manager 2>/dev/null | grep -q '^ii'; then
  warn "pve-manager was removed — reinstalling..."
  # First fix any broken deps from the force-removal
  apt --fix-broken install -y -qq 2>/dev/null || apt-get install -f -y 2>&1 | tail -3 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y pve-manager pve-container pve-cluster 2>&1 | tail -5 || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends pve-manager pve-container 2>&1 | tail -5
fi

# Remove hold from pve-manager
apt-mark unhold pve-manager 2>/dev/null || true

ok "LXC-only cleanup done"

# ─── qemu-utils installeren NA cleanup (apt conflict met pve-qemu-kvm vermijden)
dpkg -l qemu-utils 2>/dev/null | grep -q '^ii' || \
  apt-get install -y -qq qemu-utils 2>&1 | tail -2 || true

# ═════════════════════════════════════════════════════════════
# STAP 5 — Storage configuratie (rootdir toestaan voor LXC)
# ═════════════════════════════════════════════════════════════
echo ""
echo "💾 Stap — Storage config"
if grep -q 'content iso,vztmpl,backup' /etc/pve/storage.cfg 2>/dev/null; then
  sed -i 's/content iso,vztmpl,backup/content iso,vztmpl,backup,rootdir/' /etc/pve/storage.cfg
  ok "rootdir toegevoegd aan local storage"
else
  ok "Storage al correct geconfigureerd"
fi

# ═════════════════════════════════════════════════════════════
# STAP 6 — IP forwarding + NAT + DHCP
# ═════════════════════════════════════════════════════════════
echo ""
echo "🌐 Stap 6/7 — NAT + DHCP"

# IP forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-vpse.conf

# Bridge for containers (internal only — public IP stays on main interface)
if ! ip link show vmbr0 2>/dev/null | grep -q "UP"; then
  echo "   Creating vmbr0 bridge for containers (10.0.3.1/24)..."
  ip link add name vmbr0 type bridge 2>/dev/null
  ip link set vmbr0 up
  ip addr add 10.0.3.1/24 dev vmbr0
  ok "Bridge vmbr0 created (10.0.3.1/24 for containers)"
fi
if ! ip addr show vmbr0 2>/dev/null | grep -q "10.0.3.1"; then
  ip addr add 10.0.3.1/24 dev vmbr0 2>/dev/null || true
fi

# NAT masquerade
if ! iptables -t nat -C POSTROUTING -s 10.0.3.0/24 -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s 10.0.3.0/24 -j MASQUERADE
  iptables -A FORWARD -s 10.0.3.0/24 -j ACCEPT
  iptables -A FORWARD -d 10.0.3.0/24 -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

# Fix broken deps from dummy packages
apt --fix-broken install -y -qq 2>/dev/null || true

# iptables persistent
mkdir -p /etc/iptables
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections 2>/dev/null || true
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent 2>/dev/null || true
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

# DHCP (dnsmasq)
if ! command -v dnsmasq &>/dev/null; then
  apt-get install -y -qq dnsmasq 2>&1 | tail -2
fi

if [ ! -f /etc/dnsmasq.d/vpse.conf ]; then
  cat > /etc/dnsmasq.d/vpse.conf <<-DHCPEOF
interface=vmbr0
bind-interfaces
domain=vpse.local
dhcp-range=10.0.3.200,10.0.3.250,12h
dhcp-option=3,10.0.3.1
dhcp-option=6,10.0.3.1
port=53
no-resolv
server=1.1.1.1
server=8.8.8.8
no-dhcp-interface=lo
DHCPEOF
  systemctl enable dnsmasq 2>/dev/null || true
  systemctl restart dnsmasq 2>/dev/null || true
fi

ok "NAT + DHCP actief (10.0.3.0/24)"

# ═════════════════════════════════════════════════════════════
# STAP 7 — vpse CLI installeren
# ═════════════════════════════════════════════════════════════
echo ""
echo "🔧 Stap 7/7 — Install vpse CLI"

cat > /usr/local/bin/vpse <<-'VPSEOF'
#!/bin/bash
# VpsE — Proxmox VPS CLI: containers + port forwarding
set -euo pipefail

CONF="/etc/vpse/vpse.conf"; PORTS_DB="/etc/vpse/ports.txt"; DHCP_HOSTS="/etc/vpse/dhcp-hosts"
BRIDGE="vmbr0"; SUBNET="10.0.3.0/24"; STORAGE="local"
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
ok()   { echo -e " ${G}✅${N} $1"; }; warn() { echo -e " ${Y}⚠️${N} $1"; }; fail() { echo -e " ${R}❌${N} $1"; exit 1; }

get_ip() { local v="$1" i; i=$(pct config "$v" 2>/dev/null | grep -oP 'ip=\K[0-9.]+' | head -1); [ -n "$i" ] && [ "$i" != "dhcp" ] && echo "$i" && return 0; [ -f "$DHCP_HOSTS/$v.conf" ] && { i=$(grep -oP '10\.0\.3\.\d+' "$DHCP_HOSTS/$v.conf" 2>/dev/null); [ -n "$i" ] && echo "$i" && return 0; }; echo "10.0.3.$v"; }
valid_vmid() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 100 ] && [ "$1" -le 999 ]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
sv_ipt() { command -v netfilter-persistent &>/dev/null && netfilter-persistent save 2>/dev/null || true; }
dhcp_rld() { systemctl restart dnsmasq 2>/dev/null || true; }

ports_load() { [ -f "$PORTS_DB" ] && grep -v '^#' "$PORTS_DB" 2>/dev/null || true; }
ports_del() { local v="$1" e="$2"; [ -f "$PORTS_DB" ] && sed -i "/^$v:.*:$e:/d" "$PORTS_DB" 2>/dev/null || true; }
ports_delall() { local v="$1"; [ -f "$PORTS_DB" ] && sed -i "/^$v:/d" "$PORTS_DB" 2>/dev/null || true; }
ports_set() { local v="$1" e="$2" s="$3"; [ -f "$PORTS_DB" ] && sed -i "s/^\($v:.*:$e:\).*/\1$s/" "$PORTS_DB" 2>/dev/null || true; }
ports_add() { mkdir -p "$(dirname "$PORTS_DB")"; ports_del "$1" "$3"; echo "$1:$2:$3:active" >> "$PORTS_DB"; }

fw_add() { local I="$1" X="$2" i="$3"; iptables -t nat -C PREROUTING -i "$BRIDGE" -p tcp --dport "$X" -j DNAT --to-destination "$I:$i" 2>/dev/null && return 0; iptables -t nat -A PREROUTING -i "$BRIDGE" -p tcp --dport "$X" -j DNAT --to-destination "$I:$i"; iptables -C FORWARD -p tcp -d "$I" --dport "$i" -j ACCEPT 2>/dev/null || iptables -A FORWARD -p tcp -d "$I" --dport "$i" -j ACCEPT; sv_ipt; }
fw_rm() { local I="$1" X="$2" i="$3"; iptables -t nat -D PREROUTING -i "$BRIDGE" -p tcp --dport "$X" -j DNAT --to-destination "$I:$i" 2>/dev/null || true; iptables -D FORWARD -p tcp -d "$I" --dport "$i" -j ACCEPT 2>/dev/null || true; sv_ipt; }
fw_rmall() { local I="$1"; iptables-save | grep -v "to:$I" | iptables-restore 2>/dev/null || true; sv_ipt; }
dhcp_reg() { mkdir -p "$DHCP_HOSTS"; printf 'dhcp-host=%s,%s\n' "ct$1" "10.0.3.$1" > "$DHCP_HOSTS/$1.conf"; mkdir -p /etc/dnsmasq.d; printf 'conf-dir=%s,*.conf\n' "$DHCP_HOSTS" > /etc/dnsmasq.d/vpse-hosts.conf; dhcp_rld; }
dhcp_unreg() { rm -f "$DHCP_HOSTS/$1.conf" 2>/dev/null || true; dhcp_rld; }

cmd_ip() {
  local v="$1"; valid_vmid "$v" || fail "VMID 100-999"; pct config "$v" &>/dev/null && fail "Exists"
  echo "🔨 Container $v → 10.0.3.$v"
  local t; t=$(ls /var/lib/vz/template/cache/debian-*-standard* 2>/dev/null | head -1)
  [ -z "$t" ] && fail "Geen template in /var/lib/vz/template/cache/ — download er een met 'pveam download local debian-XX-standard'"
  pct create "$v" "$t" --hostname "ct$v" --storage "$STORAGE" --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" --unprivileged 1 --features keyctl=1,nesting=1 --cores 1 --memory 512 --swap 512 --rootfs "$STORAGE:4" --password vpse4pve --start 0
  dhcp_reg "$v"; pct start "$v"
  ok "$v created (10.0.3.$v) — pct enter $v (wachtwoord: vpse4pve)"
}

cmd_delete() {
  local v="$1"; valid_vmid "$v" || fail "VMID 100-999"; pct config "$v" &>/dev/null || fail "Not found"
  local I; I=$(get_ip "$v"); [ -n "$I" ] && fw_rmall "$I"; pct stop "$v" --skiplock 2>/dev/null || true; pct destroy "$v" 2>/dev/null; ports_delall "$v"; dhcp_unreg "$v"
  ok "$v deleted"
}

cmd_port() {
  local v="$1" i="$2" x="$3"; valid_vmid "$v" || fail "VMID 100-999"; pct config "$v" &>/dev/null || fail "Not found"
  valid_port "$i" || fail "Bad port"; [ -z "$x" ] && x="$i"; valid_port "$x" || fail "Bad port"
  local I; I=$(get_ip "$v"); [ -z "$I" ] && fail "No IP"
  local ex; ex=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "dpt:$x " | grep -oP 'to:\K[0-9.]+' | head -1)
  [ -n "$ex" ] && [ "$ex" != "$I" ] && fail "Port $x in use by $ex"
  fw_add "$I" "$x" "$i"; ports_add "$v" "$i" "$x"; ok "host:$x → ${I}:$i"
}

cmd_stop() { local v="$1" x="$2"; valid_vmid "$v" || fail; valid_port "$x" || fail
  local I i; I=$(get_ip "$v"); [ -z "$I" ] && fail; i=$(ports_load | grep "^$v:" | grep ":$x:" | cut -d: -f2 | head -1); [ -z "$i" ] && i="$x"
  fw_rm "$I" "$x" "$i"; ports_set "$v" "$x" "stopped"; warn "$x stopped"
}
cmd_start() { local v="$1" x="$2"; valid_vmid "$v" || fail; valid_port "$x" || fail
  local I i; I=$(get_ip "$v"); [ -z "$I" ] && fail; i=$(ports_load | grep "^$v:" | grep ":$x:" | cut -d: -f2 | head -1); [ -z "$i" ] && fail "No saved config"
  fw_add "$I" "$x" "$i"; ports_set "$v" "$x" "active"; ok "$x re-enabled"
}
cmd_delport() { local v="$1" x="$2"; valid_vmid "$v" || fail; valid_port "$x" || fail
  local I i; I=$(get_ip "$v"); [ -n "$I" ] && { i=$(ports_load | grep "^$v:" | grep ":$x:" | cut -d: -f2 | head -1); [ -z "$i" ] && i="$x"; fw_rm "$I" "$x" "$i"; }; ports_del "$v" "$x"; ok "$x removed"
}

cmd_list() {
  printf "  %-6s %-16s %-16s %-8s %s\n" "VMID" "NAME" "IP" "STATUS" "PORTS"
  echo "  ─────────────────────────────────────────────────────────────"
  pct list 2>/dev/null | tail -n +2 | while read -r v s r; do
    local n i p; n=$(pct config "$v" 2>/dev/null | grep hostname | awk '{print $2}'); i=$(get_ip "$v"); p=""
    while IFS=: read -r vi ie xe se; do [ "$vi" = "$v" ] && p="$p $xe→$ie$( [ "$se" = "stopped" ] && echo '⏸')"; done <<< "$(ports_load)"
    printf "  %-6s %-16s %-16s %-8s %s\n" "$v" "$n" "$i" "$s" "${p:- —}"
  done
  local f; f=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "dpt:")
  [ -n "$f" ] && { echo ""; echo "$f" | while read -r l; do echo "    host:$(echo "$l" | grep -oP 'dpt:\K[0-9]+') → $(echo "$l" | grep -oP 'to:\K[0-9.]+:[0-9]+')"; done; }
}

case "${1:-help}" in
  ip) cmd_ip "$2" ;;
  delete) cmd_delete "$2" ;;
  port) cmd_port "$2" "$3" "$4" ;;
  stop) cmd_stop "$2" "$3" ;;
  start) cmd_start "$2" "$3" ;;
  delport) cmd_delport "$2" "$3" ;;
  list) cmd_list ;;
  help|--help|-h)
    echo "VpsE — Proxmox VPS CLI"
    echo "  vpse ip <vmid>           → Container aanmaken (DHCP → 10.0.3.<vmid>)"
    echo "  vpse delete <vmid>       → Container + poorten verwijderen"
    echo "  vpse port <vmid> <int> <ext>  → Poort forwarden"
    echo "  vpse stop <vmid> <ext>   → Poort uitzetten (config blijft)"
    echo "  vpse start <vmid> <ext>  → Poort terug aanzetten"
    echo "  vpse delport <vmid> <ext> → Poort definitief verwijderen"
    echo "  vpse list                → Overzicht"
    echo "Examples:"
    echo "  vpse ip 100              # Container → 10.0.3.100"
    echo "  vpse port 100 80 80      # host:80 → container:80"
    echo "  vpse port 100 8069 8060  # host:8060 → container:8069"
    echo "  vpse delete 100          # Container verwijderen"
    ;;
  *) echo "Use: vpse help"; exit 1 ;;
esac
VPSEOF

chmod 755 /usr/local/bin/vpse
ok "vpse CLI geïnstalleerd"

# ═════════════════════════════════════════════════════════════
# STAP 7 — Services herstarten
# ═════════════════════════════════════════════════════════════
echo ""
echo "🔄 Restarting services"

systemctl restart pve-cluster pveproxy pvedaemon pvestatd 2>/dev/null || true

# Restore pve-apt-hook (was replaced with no-op during package removal)
[ -f "${PVE_HOOK}.bak" ] && cp "${PVE_HOOK}.bak" "$PVE_HOOK" 2>/dev/null || true

# ═════════════════════════════════════════════════════════════
# Verification — check critical components
# ═════════════════════════════════════════════════════════════
echo ""
echo "🔍 Verification"

TPLPATH="/usr/share/pve-manager/index.html.tpl"
if [ -f "$TPLPATH" ]; then
  ok "pve-manager template found: $TPLPATH"
else
  warn "Template $TPLPATH missing — pveproxy may not serve the Web UI"
  echo "   If the Web UI shows 'file error', reinstall pve-manager:"
  echo "   apt-get install --reinstall pve-manager"
fi

if systemctl is-active --quiet pveproxy 2>/dev/null; then
  ok "pveproxy is running"
else
  warn "pveproxy not running — try: systemctl restart pveproxy"
fi

echo ""
echo "╔══════════════════════════════════╗"
echo "║  VpsE Proxmox Lite — klaar! 🎉  ║"
echo "╚══════════════════════════════════╝"
echo ""
echo "  Web UI:  https://$PUBLIC_IP:8006"
echo ""
echo "  vpse ip 100              → Container aanmaken"
echo "  vpse port 100 80 80      → Poort forwarden"
echo "  vpse stop/start/delport  → Poort beheer"
echo "  vpse delete 100          → Container verwijderen"
echo "  vpse list                → Overzicht"
echo "  vpse help                → Alle commando's"
echo ""
