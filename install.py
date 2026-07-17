#!/usr/bin/env python3
"""
VpsE Proxmox Lite — Python Installer
Van kale Debian 12/13 → Proxmox (LXC-only) + NAT + DHCP + vpse CLI
Zero external dependencies — stdlib only.
"""

import os, sys, subprocess, shutil, tempfile, textwrap, re, json
from pathlib import Path
from typing import List, Optional

# ─── Constants ──────────────────────────────────────────────────────
PROXMOX_REPO = "http://download.proxmox.com/debian/pve"
ENTERPRISE_REPO = "https://enterprise.proxmox.com/debian/pve"
GPG_URL = "https://download.proxmox.com/debian/proxmox-release-{codename}.gpg"
DUMMY_VER = "9999.99.99-vpse"

PVE_PKGS_TO_PURGE = [
    "qemu-server", "pve-qemu-kvm", "spiceterm",
    "ceph-common", "ceph-fuse", "libcephfs2", "librados2",
    "librbd1", "librgw2", "python3-cephfs", "python3-ceph-common",
    "pve-nvidia-vgpu-helper", "pve-esxi-import-tools",
    "pve-edk2-firmware-legacy", "pve-edk2-firmware-ovmf",
    "swtpm", "swtpm-tools", "swtpm-libs", "libspice-server1", "virtiofsd",
    "zfsutils-linux", "zfs-zed", "libzfs7linux", "libzpool7linux",
    "libnvpair3linux", "libuutil3linux",
    "pve-ha-manager",
]

PVE_DUMMIES = PVE_PKGS_TO_PURGE + ["proxmox-ve"]

# ─── Logging ────────────────────────────────────────────────────────
class Log:
    @staticmethod
    def ok(msg):   print(f" \033[32m✅\033[0m {msg}")
    @staticmethod
    def warn(msg): print(f" \033[33m⚠️\033[0m {msg}")
    @staticmethod
    def fail(msg): print(f" \033[31m❌\033[0m {msg}")
    @staticmethod
    def info(msg): print(f"   {msg}")
    @staticmethod
    def step(n, total, title):
        print(f"\n\033[36m[{n}/{total}]\033[0m {title}")

# ─── Helpers ────────────────────────────────────────────────────────
def run(cmd: List[str], check=False, timeout=300, **kw) -> subprocess.CompletedProcess:
    """Run a command and return the result."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout, check=check, **kw)
    except subprocess.CalledProcessError as e:
        return subprocess.CompletedProcess(cmd, e.returncode, e.stdout, e.stderr)
    except FileNotFoundError:
        return subprocess.CompletedProcess(cmd, -1, "", f"Command not found: {cmd[0]}")

def apt_install(*packages: str, opts: Optional[List[str]] = None) -> bool:
    """Install packages with DEBIAN_FRONTEND=noninteractive."""
    env = os.environ.copy()
    env["DEBIAN_FRONTEND"] = "noninteractive"
    cmd = ["apt-get", "install", "-y"] + (opts or []) + list(packages)
    r = run(cmd, env=env)
    if r.returncode != 0:
        Log.warn(f"apt install {' '.join(packages)} failed: {r.stderr[-200:]}")
        return False
    return True

def debconf_set(selection: str):
    run(["debconf-set-selections"], input=selection, timeout=10)

def dpkg_is_installed(pkg: str) -> bool:
    r = run(["dpkg", "-l", pkg], timeout=10)
    return r.returncode == 0 and any(
        l.startswith("ii") for l in r.stdout.splitlines()
    )

def make_dummy(pkg: str) -> bool:
    """Create and install a dummy .deb for a package using dpkg-deb."""
    if not dpkg_is_installed(pkg):
        return True  # not installed → no dummy needed
    with tempfile.TemporaryDirectory() as tmp:
        debdir = Path(tmp) / "pkg"
        (debdir / "DEBIAN").mkdir(parents=True)
        control = textwrap.dedent(f"""\
            Package: {pkg}
            Version: {DUMMY_VER}
            Architecture: all
            Maintainer: VpsE Proxmox Lite <root@localhost>
            Description: Dummy — LXC only (replaces {pkg})
        """)
        (debdir / "DEBIAN" / "control").write_text(control)
        deb_path = Path(tmp) / f"{pkg}.deb"
        r1 = run(["dpkg-deb", "-b", str(debdir), str(deb_path)], timeout=30)
        if r1.returncode != 0:
            Log.warn(f"Failed to build dummy for {pkg}")
            return False
        r2 = run(["dpkg", "-i", str(deb_path)], timeout=30)
        if r2.returncode != 0:
            Log.warn(f"Failed to install dummy for {pkg}: {r2.stderr[:200]}")
            return False
    return True

def hostname() -> str:
    return run(["hostname"], timeout=5).stdout.strip()

def public_ip() -> str:
    r = run(["ip", "-4", "route", "get", "1.1.1.1"], timeout=10)
    m = re.search(r'src (\S+)', r.stdout)
    if m:
        return m.group(1)
    r = run(["curl", "-s", "--connect-timeout", "5", "https://ifconfig.me"], timeout=10)
    return r.stdout.strip()

# ─── Installer class ────────────────────────────────────────────────
class ProxmoxLiteInstaller:
    def __init__(self):
        self.codename = ""
        self.ip = ""
        self.node_name = os.environ.get("PROXMOX_NAME") or hostname() or "pve"
        self.pve_password = os.environ.get("PROXMOX_PASSWORD") or "VpsE"
        self.total_steps = 11

    def check_prerequisites(self):
        """Stap 1 — Check: root, Debian, netwerk"""
        Log.step(1, self.total_steps, "Prerequisites")
        if os.geteuid() != 0:
            # Try sudo
            r = run(["sudo", "-n", "true"], timeout=10)
            if r.returncode == 0:
                os.execvp("sudo", ["sudo", "python3"] + sys.argv)
            Log.fail("Must run as root")
            sys.exit(1)
        # Debian version
        osrel = Path("/etc/os-release").read_text() if Path("/etc/os-release").exists() else ""
        m = re.search(r'VERSION_CODENAME=(\w+)', osrel)
        if not m or m.group(1) not in ("bookworm", "trixie"):
            Log.fail("Only Debian 12 (bookworm) or 13 (trixie) supported")
            sys.exit(1)
        self.codename = m.group(1)
        self.ip = public_ip()
        if not self.ip:
            Log.fail("Could not determine public IP")
            sys.exit(1)
        Log.ok(f"Debian {self.codename}, IP: {self.ip}, node: {self.node_name}")

    def setup_repo(self):
        """Stap 2 — Proxmox repository"""
        Log.step(2, self.total_steps, "Proxmox repository")
        # Add no-subscription repo
        Path("/etc/apt/sources.list.d/pve.list").write_text(
            f"deb {PROXMOX_REPO} {self.codename} pve-no-subscription\n"
        )
        # Disable enterprise repos
        for f in ["/etc/apt/sources.list.d/pve-enterprise.list",
                   "/etc/apt/sources.list.d/pve-enterprise.sources"]:
            p = Path(f)
            if p.exists():
                p.rename(p.with_suffix(p.suffix + ".disabled"))
        # GPG key
        gpg_path = "/etc/apt/trusted.gpg.d/proxmox.gpg"
        if not Path(gpg_path).exists():
            r = run(["curl", "-fsSL", "--insecure", GPG_URL.format(codename=self.codename),
                     "-o", gpg_path], timeout=30)
            if r.returncode != 0:
                r = run(["curl", "-fsSL", "--insecure", GPG_URL.format(codename=self.codename),
                         "-o", gpg_path], timeout=30)
        # apt update
        r = run(["apt-get", "update"], timeout=120)
        if r.returncode != 0:
            Log.warn("apt update had issues (enterprise repo disabled)")
        Log.ok("Repository configured")

    def configure_hosts(self):
        """Stap 3 — /etc/hosts + hostname"""
        Log.step(3, self.total_steps, "Host configuration")
        run(["hostnamectl", "set-hostname", self.node_name], timeout=10)
        hosts = Path("/etc/hosts").read_text()
        # Remove 127.0.1.1 line
        hosts = re.sub(r'^127\.0\.1\.1\s.*\n?', '', hosts, flags=re.MULTILINE)
        # Add public IP → hostname if not present
        if self.ip not in hosts:
            hosts += f"\n{self.ip} {self.node_name}\n"
            Path("/etc/hosts").write_text(hosts)
        Log.ok(f"hosts: {self.ip} → {self.node_name}")

    def set_root_password(self):
        """Stap 4 — Root wachtwoord voor Web UI"""
        Log.step(4, self.total_steps, "Root password")
        r = run(["chpasswd"], input=f"root:{self.pve_password}", timeout=10)
        if r.returncode == 0:
            Log.ok("Root password set")
        else:
            Log.warn("Could not set root password")

    def install_proxmox(self):
        """Stap 5 — proxmox-ve installeren"""
        Log.step(5, self.total_steps, "Installing Proxmox VE")
        Log.info("This can take 5-15 minutes...")
        if dpkg_is_installed("pve-manager") and dpkg_is_installed("proxmox-ve"):
            Log.ok("Already installed")
            return
        debconf_set("grub-pc grub-pc/install_devices multiselect /dev/sda\n")
        debconf_set("postfix postfix/main_mailer_type select No configuration\n")
        ok = apt_install("proxmox-ve")
        if not ok or not dpkg_is_installed("pve-manager"):
            Log.warn("proxmox-ve install had issues, trying individual packages...")
            # Create dummies first to satisfy deps
            for p in ["qemu-server", "pve-qemu-kvm", "spiceterm"]:
                make_dummy(p)
            apt_install("pve-manager", "pve-container", "pve-cluster",
                        opts=["--no-install-recommends"])
        ver = run(["pveversion"], timeout=5).stdout.strip()
        Log.ok(ver or "Proxmox VE installed")

    def lxc_cleanup(self):
        """Stap 6 — LXC-only: vervang qemu/ceph/zfs met dummies"""
        Log.step(6, self.total_steps, "LXC-only cleanup")

        if not dpkg_is_installed("pve-manager"):
            Log.warn("pve-manager not installed, reinstalling first...")
            apt_install("pve-manager", "pve-cluster", "pve-container",
                        opts=["--no-install-recommends"])

        # Disable pve-apt-hook (replaces with no-op)
        hook = Path("/usr/share/proxmox-ve/pve-apt-hook")
        if hook.exists():
            hook_bak = Path("/usr/share/proxmox-ve/pve-apt-hook.bak")
            if not hook_bak.exists():
                shutil.copy2(str(hook), str(hook_bak))
            hook.write_text("#!/bin/bash\nexit 0\n")
            hook.chmod(0o755)
        else:
            hook_bak = None

        # Protect pve-manager
        run(["apt-mark", "hold", "pve-manager"], timeout=10)

        # Create dummies for ALL packages we want to replace
        Log.info(f"Creating dummies for {len(PVE_DUMMIES)} packages...")
        for pkg in PVE_DUMMIES:
            make_dummy(pkg)

        # Force-purge the real packages
        Log.info("Removing real packages (QEMU, Ceph, ZFS)...")
        for chunk in [PVE_PKGS_TO_PURGE[i:i+5] for i in range(0, len(PVE_PKGS_TO_PURGE), 5)]:
            run(["dpkg", "--purge", "--force-depends"] + chunk, timeout=60)

        # Fix broken deps
        run(["apt", "--fix-broken", "install", "-y"], timeout=120)
        run(["dpkg", "--configure", "-a"], timeout=60)

        # Unhold pve-manager
        run(["apt-mark", "unhold", "pve-manager"], timeout=10)

        # Install qemu-utils (now safe — no conflict)
        apt_install("qemu-utils")

        # Verify pve-manager survived
        if not dpkg_is_installed("pve-manager"):
            Log.warn("pve-manager was removed — reinstalling...")
            apt_install("pve-manager", "pve-cluster", "pve-container",
                        opts=["--no-install-recommends"])
            if not dpkg_is_installed("pve-manager"):
                Log.fail("pve-manager could not be reinstalled!")
                sys.exit(1)

        # Restore pve-apt-hook
        if hook_bak and hook_bak.exists():
            shutil.copy2(str(hook_bak), str(hook))

        Log.ok("LXC-only cleanup done")

    def configure_storage(self):
        """Stap 7 — Storage configuratie (rootdir toestaan voor LXC)"""
        Log.step(7, self.total_steps, "Storage configuration")
        storage_cfg = Path("/etc/pve/storage.cfg")
        if storage_cfg.exists():
            content = storage_cfg.read_text()
            if "rootdir" not in content and "content iso,vztmpl,backup" in content:
                content = content.replace("content iso,vztmpl,backup",
                                          "content iso,vztmpl,backup,rootdir")
                storage_cfg.write_text(content)
                Log.ok("rootdir added to local storage")
            else:
                Log.ok("Storage already configured correctly")
        else:
            Log.warn("storage.cfg not found (will be created on first use)")

    def setup_network(self):
        """Stap 8 — vmbr0 bridge + NAT + DHCP"""
        Log.step(8, self.total_steps, "Network: bridge + NAT + DHCP")

        # IP forwarding
        run(["sysctl", "-w", "net.ipv4.ip_forward=1"], timeout=10)
        Path("/etc/sysctl.d/99-vpse.conf").write_text("net.ipv4.ip_forward=1\n")

        # vmbr0 bridge
        r = run(["ip", "link", "show", "vmbr0"], timeout=10)
        if b"UP" not in r.stdout.encode() if hasattr(r.stdout, 'encode') else "UP" not in r.stdout:
            Log.info("Creating vmbr0 bridge (10.0.3.1/24)...")
            run(["ip", "link", "add", "name", "vmbr0", "type", "bridge"], timeout=10)
            run(["ip", "link", "set", "vmbr0", "up"], timeout=10)
            run(["ip", "addr", "add", "10.0.3.1/24", "dev", "vmbr0"], timeout=10)
            Log.ok("Bridge vmbr0 created")
        else:
            # Ensure IP is set
            if "10.0.3.1" not in run(["ip", "addr", "show", "vmbr0"], timeout=10).stdout:
                run(["ip", "addr", "add", "10.0.3.1/24", "dev", "vmbr0"], timeout=10)

        # NAT masquerade
        sub = "10.0.3.0/24"
        r = run(["iptables", "-t", "nat", "-C", "POSTROUTING", "-s", sub,
                 "-j", "MASQUERADE"], timeout=10)
        if r.returncode != 0:
            run(["iptables", "-t", "nat", "-A", "POSTROUTING", "-s", sub,
                 "-j", "MASQUERADE"], timeout=10)
            run(["iptables", "-A", "FORWARD", "-s", sub, "-j", "ACCEPT"], timeout=10)
            run(["iptables", "-A", "FORWARD", "-d", sub,
                 "-m", "state", "--state", "RELATED,ESTABLISHED",
                 "-j", "ACCEPT"], timeout=10)

        # iptables-persistent
        debconf_set("iptables-persistent iptables-persistent/autosave_v4 boolean true\n")
        debconf_set("iptables-persistent iptables-persistent/autosave_v6 boolean true\n")
        Path("/etc/iptables").mkdir(exist_ok=True)
        apt_install("iptables-persistent")
        run(["netfilter-persistent", "save"], timeout=30)

        # dnsmasq DHCP
        if not shutil.which("dnsmasq"):
            apt_install("dnsmasq")

        dns_conf = Path("/etc/dnsmasq.d/vpse.conf")
        if not dns_conf.exists():
            dns_conf.write_text(textwrap.dedent("""\
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
            """))
            run(["systemctl", "enable", "dnsmasq"], timeout=30)
            run(["systemctl", "restart", "dnsmasq"], timeout=30)

        # Fix any remaining broken deps
        run(["apt", "--fix-broken", "install", "-y"], timeout=60)
        Log.ok("NAT + DHCP active (10.0.3.0/24)")

    def install_vpse_cli(self):
        """Stap 9 — vpse CLI installeren"""
        Log.step(9, self.total_steps, "Install vpse CLI")
        vpse_path = Path("/usr/local/bin/vpse")
        vpse_script = textwrap.dedent("""\
        #!/bin/bash
        # VpsE — Proxmox VPS CLI: containers + port forwarding
        set -euo pipefail

        CONF="/etc/vpse/vpse.conf"; PORTS_DB="/etc/vpse/ports.txt"; DHCP_HOSTS="/etc/vpse/dhcp-hosts"
        BRIDGE="vmbr0"; SUBNET="10.0.3.0/24"; STORAGE="local"
        R='\\033[0;31m'; G='\\033[0;32m'; Y='\\033[1;33m'; C='\\033[0;36m'; N='\\033[0m'
        ok()   { echo -e " ${G}✅${N} $1"; }; warn() { echo -e " ${Y}⚠️${N} $1"; }; fail() { echo -e " ${R}❌${N} $1"; exit 1; }

        get_ip() { local v="$1" i; i=$(pct config "$v" 2>/dev/null | grep -oP 'ip=\\K[0-9.]+' | head -1); [ -n "$i" ] && [ "$i" != "dhcp" ] && echo "$i" && return 0; [ -f "$DHCP_HOSTS/$v.conf" ] && { i=$(grep -oP '10\\.0\\.3\\.\\d+' "$DHCP_HOSTS/$v.conf" 2>/dev/null); [ -n "$i" ] && echo "$i" && return 0; }; echo "10.0.3.$v"; }
        valid_vmid() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 100 ] && [ "$1" -le 999 ]; }
        valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
        sv_ipt() { command -v netfilter-persistent &>/dev/null && netfilter-persistent save 2>/dev/null || true; }
        dhcp_rld() { systemctl restart dnsmasq 2>/dev/null || true; }

        ports_load() { [ -f "$PORTS_DB" ] && grep -v '^#' "$PORTS_DB" 2>/dev/null || true; }
        ports_del() { local v="$1" e="$2"; [ -f "$PORTS_DB" ] && sed -i "/^$v:.*:$e:/d" "$PORTS_DB" 2>/dev/null || true; }
        ports_delall() { local v="$1"; [ -f "$PORTS_DB" ] && sed -i "/^$v:/d" "$PORTS_DB" 2>/dev/null || true; }
        ports_set() { local v="$1" e="$2" s="$3"; [ -f "$PORTS_DB" ] && sed -i "s/^\\($v:.*:$e:\\).*/\\1$s/" "$PORTS_DB" 2>/dev/null || true; }
        ports_add() { mkdir -p "$(dirname "$PORTS_DB")"; ports_del "$1" "$3"; echo "$1:$2:$3:active" >> "$PORTS_DB"; }

        fw_add() { local I="$1" X="$2" i="$3"; iptables -t nat -C PREROUTING -i "$BRIDGE" -p tcp --dport "$X" -j DNAT --to-destination "$I:$i" 2>/dev/null && return 0; iptables -t nat -A PREROUTING -i "$BRIDGE" -p tcp --dport "$X" -j DNAT --to-destination "$I:$i"; iptables -C FORWARD -p tcp -d "$I" --dport "$i" -j ACCEPT 2>/dev/null || iptables -A FORWARD -p tcp -d "$I" --dport "$i" -j ACCEPT; sv_ipt; }
        fw_rm() { local I="$1" X="$2" i="$3"; iptables -t nat -D PREROUTING -i "$BRIDGE" -p tcp --dport "$X" -j DNAT --to-destination "$I:$i" 2>/dev/null || true; iptables -D FORWARD -p tcp -d "$I" --dport "$i" -j ACCEPT 2>/dev/null || true; sv_ipt; }
        fw_rmall() { local I="$1"; iptables-save | grep -v "to:$I" | iptables-restore 2>/dev/null || true; sv_ipt; }
        dhcp_reg() { mkdir -p "$DHCP_HOSTS"; printf 'dhcp-host=%s,%s\\n' "ct$1" "10.0.3.$1" > "$DHCP_HOSTS/$1.conf"; mkdir -p /etc/dnsmasq.d; printf 'conf-dir=%s,*.conf\\n' "$DHCP_HOSTS" > /etc/dnsmasq.d/vpse-hosts.conf; dhcp_rld; }
        dhcp_unreg() { rm -f "$DHCP_HOSTS/$1.conf" 2>/dev/null || true; dhcp_rld; }

        cmd_ip() {
          local v="$1"; valid_vmid "$v" || fail "VMID 100-999"; pct config "$v" &>/dev/null && fail "Exists"
          echo "🔨 Container $v → 10.0.3.$v"
          local t; t=$(ls /var/lib/vz/template/cache/debian-*-standard* 2>/dev/null | head -1)
          [ -z "$t" ] && fail "No template in /var/lib/vz/template/cache/ — download with: pveam download local debian-XX-standard"
          pct create "$v" "$t" --hostname "ct$v" --storage "$STORAGE" --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" --unprivileged 1 --features keyctl=1,nesting=1 --cores 1 --memory 512 --swap 512 --rootfs "$STORAGE:4" --password vpse4pve --start 0
          dhcp_reg "$v"; pct start "$v"
          ok "$v created (10.0.3.$v) — pct enter $v (password: vpse4pve)"
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
          local ex; ex=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "dpt:$x " | grep -oP 'to:\\K[0-9.]+' | head -1)
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
          printf "  %-6s %-16s %-16s %-8s %s\\n" "VMID" "NAME" "IP" "STATUS" "PORTS"
          echo "  ─────────────────────────────────────────────────────────────"
          pct list 2>/dev/null | tail -n +2 | while read -r v s r; do
            local n i p; n=$(pct config "$v" 2>/dev/null | grep hostname | awk '{print $2}'); i=$(get_ip "$v"); p=""
            while IFS=: read -r vi ie xe se; do [ "$vi" = "$v" ] && p="$p $xe→$ie$( [ "$se" = "stopped" ] && echo '⏸')"; done <<< "$(ports_load)"
            printf "  %-6s %-16s %-16s %-8s %s\\n" "$v" "$n" "$i" "$s" "${p:- —}"
          done
          local f; f=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "dpt:")
          [ -n "$f" ] && { echo ""; echo "$f" | while read -r l; do echo "    host:$(echo "$l" | grep -oP 'dpt:\\K[0-9]+') → $(echo "$l" | grep -oP 'to:\\K[0-9.]+:[0-9]+')"; done; }
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
            echo "VpsE — Proxmox VPS CLI"; echo "  vpse ip <vmid>           → Create container (DHCP → 10.0.3.<vmid>)"
            echo "  vpse delete <vmid>       → Delete container + ports"; echo "  vpse port <vmid> <int> <ext>  → Port forward"
            echo "  vpse stop <vmid> <ext>   → Stop port (keep config)"; echo "  vpse start <vmid> <ext>  → Re-enable port"
            echo "  vpse delport <vmid> <ext> → Remove port permanently"; echo "  vpse list                → Overview"
            echo "Examples:"; echo "  vpse ip 100"; echo "  vpse port 100 80 80"; echo "  vpse delete 100";;
          *) echo "Use: vpse help"; exit 1 ;;
        esac
        """)
        vpse_path.write_text(vpse_script)
        vpse_path.chmod(0o755)
        Log.ok("vpse CLI installed")

    def restart_services(self):
        """Stap 10 — Services herstarten"""
        Log.step(10, self.total_steps, "Restart services")
        for svc in ["pve-cluster", "pveproxy", "pvedaemon", "pvestatd"]:
            run(["systemctl", "restart", svc], timeout=30)
        Log.ok("Services restarted")

    def verify(self):
        """Stap 11 — Verificatie"""
        Log.step(11, self.total_steps, "Verification")

        tpl = Path("/usr/share/pve-manager/index.html.tpl")
        if tpl.exists():
            Log.ok("pve-manager template found")
        else:
            Log.warn("Template missing — Web UI may not work")

        r = run(["systemctl", "is-active", "pveproxy"], timeout=10)
        if r.returncode == 0:
            Log.ok("pveproxy is running")
        else:
            Log.warn("pveproxy not running — try: systemctl restart pveproxy")

        r = run(["systemctl", "is-active", "dnsmasq"], timeout=10)
        if r.returncode == 0:
            Log.ok("dnsmasq (DHCP) is running")
        else:
            Log.warn("dnsmasq not running")

        if shutil.which("pct"):
            Log.ok("pct (LXC) available")
        else:
            Log.warn("pct not found — pve-container may not be installed")

    def run(self):
        """Run all steps."""
        print("╔══════════════════════════════════╗")
        print("║   VpsE Proxmox Lite Installer   ║")
        print("╚══════════════════════════════════╝")
        print(f"   Node: {self.node_name}, Debian: {self.codename}, IP: {self.ip}")

        steps = [
            self.check_prerequisites,
            self.setup_repo,
            self.configure_hosts,
            self.set_root_password,
            self.install_proxmox,
            self.lxc_cleanup,
            self.configure_storage,
            self.setup_network,
            self.install_vpse_cli,
            self.restart_services,
            self.verify,
        ]
        for step_fn in steps:
            try:
                step_fn()
            except Exception as e:
                Log.fail(f"Step failed: {e}")
                sys.exit(1)

        print()
        print("╔══════════════════════════════════╗")
        print("║  VpsE Proxmox Lite — Done! 🎉  ║")
        print("╚══════════════════════════════════╝")
        print()
        print(f"  Web UI:  https://{self.ip}:8006  (root/{self.pve_password})")
        print()
        print("  vpse ip 100              → Create container")
        print("  vpse port 100 80 80      → Port forward")
        print("  vpse delete 100          → Delete container")
        print("  vpse list                → Overview")
        print()


if __name__ == "__main__":
    installer = ProxmoxLiteInstaller()
    installer.run()
