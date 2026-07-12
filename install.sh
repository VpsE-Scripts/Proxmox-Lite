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
  curl -fsSL https://download.proxmox.com/debian/proxmox-release-$DEBIAN_CODENAME.gpg \
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
# STAP 6 — Services herstarten
# ═════════════════════════════════════════════════════════════
echo ""
echo "🔄 Stap 6/6 — Services herstarten"

systemctl restart pve-cluster pveproxy pvedaemon pvestatd 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════╗"
echo "║  VpsE Proxmox Lite — klaar! 🎉  ║"
echo "╚══════════════════════════════════╝"
echo ""
echo "  Web UI:  https://$PUBLIC_IP:8006"
echo "  SSH:     ssh root@$PUBLIC_IP"
echo ""
echo "  Container aanmaken met DHCP IP:"
echo "    # Zoek de beschikbare template in /var/lib/vz/template/cache/"
echo "    ls /var/lib/vz/template/cache/debian-*-standard*"
echo "    pct create 100 /var/lib/vz/template/cache/debian-XX-standard_*.tar.zst \\"
echo "      --hostname ct100 --storage local \\"
echo "      --net0 name=eth0,bridge=vmbr0,ip=dhcp \\"
echo "      --unprivileged 1 --rootfs local:4"
echo ""
echo "  Vast IP via DHCP (10.0.3.100):"
echo "    echo 'dhcp-host=ct100,10.0.3.100' > /etc/vpse/dhcp-hosts/100.conf"
echo "    systemctl restart dnsmasq"
echo ""
echo "  Port forwarden:"
echo "    iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 80 \\"
echo "      -j DNAT --to-destination 10.0.3.100:80"
echo "    iptables -A FORWARD -p tcp -d 10.0.3.100 --dport 80 -j ACCEPT"
echo "    netfilter-persistent save"
echo ""
