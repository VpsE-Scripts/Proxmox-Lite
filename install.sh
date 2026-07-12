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
[ "$EUID" -eq 0 ] || fail "Run as root"
DEBIAN_CODENAME=$(grep -oP 'VERSION_CODENAME=\K\w+' /etc/os-release 2>/dev/null || echo "")
[ "$DEBIAN_CODENAME" = "bookworm" ] || [ "$DEBIAN_CODENAME" = "trixie" ] || \
  fail "Alleen Debian 12 (bookworm) of 13 (trixie)"
ok "Debian $DEBIAN_CODENAME"

PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+')
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || true)
HOSTNAME=$(hostname)

# ═════════════════════════════════════════════════════════════
# STAP 1 — Proxmox repository
# ═════════════════════════════════════════════════════════════
echo ""
echo "📦 Stap 1/6 — Proxmox repository"

if [ ! -f /etc/apt/sources.list.d/pve.list ]; then
  echo "deb http://download.proxmox.com/debian/pve $DEBIAN_CODENAME pve-no-subscription" \
    > /etc/apt/sources.list.d/pve.list
  curl -fsSL --insecure https://download.proxmox.com/debian/proxmox-release-$DEBIAN_CODENAME.gpg \
    -o /etc/apt/trusted.gpg.d/proxmox.gpg
  apt-get update -qq
fi
ok "Repository gereed"

# ═════════════════════════════════════════════════════════════
# STAP 2 — /etc/hosts (pve-cluster vereist non-loopback hostname)
# ═════════════════════════════════════════════════════════════
echo ""
echo "🔧 Stap 2/6 — /etc/hosts"

sed -i '/127.0.1.1/d' /etc/hosts 2>/dev/null || true
if ! grep -q "$PUBLIC_IP" /etc/hosts 2>/dev/null; then
  echo "$PUBLIC_IP $HOSTNAME" >> /etc/hosts
fi
ok "/etc/hosts: $PUBLIC_IP → $HOSTNAME"

# ═════════════════════════════════════════════════════════════
# STAP 3 — Proxmox VE installeren
# ═════════════════════════════════════════════════════════════
echo ""
echo "📦 Stap 3/6 — Proxmox VE"

if ! command -v pveversion &>/dev/null; then
  echo "grub-pc grub-pc/install_devices multiselect /dev/sda" | debconf-set-selections 2>/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq proxmox-ve 2>&1 | tail -1
fi
ok "$(pveversion 2>/dev/null)"

# ═════════════════════════════════════════════════════════════
# STAP 4 — VM/ZFS/Ceph verwijderen (LXC-only)
# ═════════════════════════════════════════════════════════════
echo ""
echo "🗑️  Stap 4/6 — VM/ZFS/Ceph verwijderen"

if ! command -v equivs-build &>/dev/null; then
  apt-get install -y -qq equivs 2>/dev/null
fi

dummy() {
  local name="$1" ver="$2" desc="$3"
  dpkg -l "$name" 2>/dev/null | grep -q "^ii" && return 0
  local d; d=$(mktemp -d)
  cat > "$d/control" <<-EOF
Section: misc
Priority: optional
Standards-Version: 4.7.0
Package: $name
Version: $ver
Maintainer: VpsE Proxmox Lite <root@localhost>
Provides: $name
Description: $desc
EOF
  (cd "$d" && equivs-build control >/dev/null 2>&1)
  dpkg -i "${d}/${name}_${ver}_all.deb" 2>/dev/null || true
  rm -rf "$d"
}

dummy "qemu-server"  "9.1.18-dummy" "Dummy — LXC only"
dummy "pve-qemu-kvm" "11.0.0-dummy" "Dummy — LXC only"
dummy "spiceterm"    "3.4.2-dummy"  "Dummy — LXC only"
dummy "ceph-common"  "19.2.3-dummy" "Dummy — geen Ceph"
dummy "ceph-fuse"    "19.2.3-dummy" "Dummy — geen Ceph"

touch /please-remove-proxmox-ve 2>/dev/null || true

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

dpkg --purge ceph-common ceph-fuse 2>/dev/null || true
apt-get install -y -qq qemu-utils 2>/dev/null

# Perl stubs voor pveproxy
if [ ! -f /usr/share/perl5/PVE/QemuServer.pm ]; then
  apt-get download qemu-server 2>/dev/null || true
  mkdir -p /tmp/qemu-extract
  dpkg-deb -x qemu-server_*.deb /tmp/qemu-extract 2>/dev/null || true
  if [ -d /tmp/qemu-extract/usr/share/perl5/PVE ]; then
    cp -r /tmp/qemu-extract/usr/share/perl5/PVE/API2/Qemu \
      /tmp/qemu-extract/usr/share/perl5/PVE/Qemu* \
      /usr/share/perl5/PVE/ 2>/dev/null || true
  fi
  rm -rf /tmp/qemu-extract qemu-server_*.deb
fi

ok "LXC-only: VM/ZFS/Ceph verwijderd"

# ═════════════════════════════════════════════════════════════
# STAP 5 — IP forwarding + NAT + DHCP
# ═════════════════════════════════════════════════════════════
echo ""
echo "🌐 Stap 5/6 — NAT + DHCP"

# IP forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-vpse.conf

# Bridge gateway
if ! ip addr show vmbr0 2>/dev/null | grep -q "10.0.3.1"; then
  ip addr add 10.0.3.1/24 dev vmbr0 2>/dev/null || true
  if ! grep -q "10.0.3.1" /etc/network/interfaces 2>/dev/null; then
    echo "post-up ip addr add 10.0.3.1/24 dev vmbr0" >> /etc/network/interfaces
  fi
fi

# NAT masquerade
if ! iptables -t nat -C POSTROUTING -s 10.0.3.0/24 -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s 10.0.3.0/24 -j MASQUERADE
  iptables -A FORWARD -s 10.0.3.0/24 -j ACCEPT
  iptables -A FORWARD -d 10.0.3.0/24 -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

# iptables persistent
apt-get install -y -qq iptables-persistent 2>/dev/null || true
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

# DHCP (dnsmasq)
if ! command -v dnsmasq &>/dev/null; then
  apt-get install -y -qq dnsmasq 2>/dev/null
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
# STAP 6 — vpse CLI installeren
# ═════════════════════════════════════════════════════════════
echo ""
echo "🔧 Stap 6/7 — vpse CLI installeren"

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
echo "🔄 Stap 7/7 — Services herstarten"

systemctl restart pve-cluster pveproxy pvedaemon pvestatd 2>/dev/null || true

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
