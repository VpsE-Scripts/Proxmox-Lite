#!/usr/bin/env python3
"""
VpsE Proxmox Lite — Python Installer
Van kale Debian 12/13 → Proxmox VE (compleet) + bridge + NAT + DHCP + vpse CLI
Zero external dependencies — stdlib only.
"""

import os, sys, subprocess, shutil, re
from pathlib import Path
from typing import List, Optional

# ─── Constants ──────────────────────────────────────────────────────
PROXMOX_REPO = "http://download.proxmox.com/debian/pve"
GPG_URL = "https://download.proxmox.com/debian/proxmox-release-{codename}.gpg"

# ─── Logging ────────────────────────────────────────────────────────
class Log:
    @staticmethod
    def ok(msg):   print(f" \033[32m✅\033[0m {msg}")
    @staticmethod
    def warn(msg): print(f" \033[33m⚠️\033[0m {msg}")
    @staticmethod
    def fail(msg): print(f" \033[31m❌\033[0m {msg}"); sys.exit(1)
    @staticmethod
    def info(msg): print(f"   {msg}")
    @staticmethod
    def step(n, total, title): print(f"\n\033[36m[{n}/{total}]\033[0m {title}")

# ─── Helpers ────────────────────────────────────────────────────────
def run(cmd: List[str], check=False, timeout=300, **kw) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=check, **kw)
    except subprocess.CalledProcessError as e:
        return subprocess.CompletedProcess(cmd, e.returncode, e.stdout, e.stderr)
    except FileNotFoundError:
        return subprocess.CompletedProcess(cmd, -1, "", f"Command not found: {cmd[0]}")

def debconf_set(selection: str):
    run(["debconf-set-selections"], input=selection, timeout=10)

def dpkg_is_installed(pkg: str) -> bool:
    r = run(["dpkg", "-l", pkg], timeout=10)
    return r.returncode == 0 and any(l.startswith("ii") for l in r.stdout.splitlines())

def hostname() -> str:
    return run(["hostname"], timeout=5).stdout.strip()

def public_ip() -> str:
    r = run(["ip", "-4", "route", "get", "1.1.1.1"], timeout=10)
    m = re.search(r'src (\S+)', r.stdout)
    if m: return m.group(1)
    r = run(["curl", "-s", "--connect-timeout", "5", "https://ifconfig.me"], timeout=10)
    return r.stdout.strip()

# ─── Installer ──────────────────────────────────────────────────────
class ProxmoxLiteInstaller:
    def __init__(self):
        self.codename = ""
        self.ip = ""
        self.node_name = os.environ.get("PROXMOX_NAME") or hostname() or "pve"
        self.cluster_name = os.environ.get("PROXMOX_CLUSTER") or f"vps-{self.node_name}"
        self.pve_password = os.environ.get("PROXMOX_PASSWORD") or "VpsE"
        self.total_steps = 9

    def check_prerequisites(self):
        Log.step(1, self.total_steps, "Prerequisites")
        if os.geteuid() != 0:
            r = run(["sudo", "-n", "true"], timeout=10)
            if r.returncode == 0: os.execvp("sudo", ["sudo", "python3"] + sys.argv)
            Log.fail("Run as root")
        osrel = Path("/etc/os-release").read_text() if Path("/etc/os-release").exists() else ""
        m = re.search(r'VERSION_CODENAME=(\w+)', osrel)
        if not m: Log.fail("Only Debian 12 (bookworm) or 13 (trixie) supported")
        self.codename = m.group(1)
        self.ip = public_ip()
        if not self.ip: Log.fail("Could not determine public IP")
        Log.ok(f"Debian {self.codename}, IP: {self.ip}, node: {self.node_name}")

    def setup_repo(self):
        Log.step(2, self.total_steps, "Proxmox repository")
        Path("/etc/apt/sources.list.d/pve.list").write_text(
            f"deb {PROXMOX_REPO} {self.codename} pve-no-subscription\n")
        for f in ["/etc/apt/sources.list.d/pve-enterprise.list",
                   "/etc/apt/sources.list.d/pve-enterprise.sources"]:
            p = Path(f)
            if p.exists(): p.rename(p.with_suffix(p.suffix + ".disabled"))
        gpg_path = "/etc/apt/trusted.gpg.d/proxmox.gpg"
        if not Path(gpg_path).exists():
            run(["curl", "-fsSL", "--insecure", GPG_URL.format(codename=self.codename), "-o", gpg_path], timeout=30)
        run(["apt-get", "update"], timeout=120)
        Log.ok("Repository configured")

    def configure_hosts(self):
        Log.step(3, self.total_steps, "Host configuration")
        run(["hostnamectl", "set-hostname", self.node_name], timeout=10)
        hosts = Path("/etc/hosts").read_text()
        hosts = re.sub(r'^127\.0\.1\.1\s.*\n?', '', hosts, flags=re.MULTILINE)
        if self.ip not in hosts:
            hosts += f"\n{self.ip} {self.node_name}\n"
            Path("/etc/hosts").write_text(hosts)
        Log.ok(f"hosts: {self.ip} → {self.node_name}")

    def set_root_password(self):
        Log.step(4, self.total_steps, "Root password")
        r = run(["chpasswd"], input=f"root:{self.pve_password}", timeout=10)
        Log.ok("Root password set" if r.returncode == 0 else "warn:Could not set")

    def install_proxmox(self):
        Log.step(5, self.total_steps, "Installing Proxmox VE")
        Log.info("This can take 5-15 minutes...")
        if dpkg_is_installed("pve-manager"):
            Log.ok("Already installed"); return
        debconf_set("grub-pc grub-pc/install_devices multiselect /dev/sda\n")
        debconf_set("postfix postfix/main_mailer_type select No configuration\n")
        apt_install("proxmox-ve")
        ver = run(["pveversion"], timeout=5).stdout.strip()
        Log.ok(ver or "Proxmox VE installed")

    def init_cluster(self):
        Log.step(6, self.total_steps, "Cluster initialization")
        if Path("/etc/pve/corosync.conf").exists():
            Log.ok("Cluster already configured"); return
        r = run(["pvecm", "create", self.cluster_name], timeout=30)
        if r.returncode == 0:
            Log.ok(f"Cluster '{self.cluster_name}' created")
        else:
            Log.warn(f"Cluster creation failed: {r.stderr[:200]}")
            run(["systemctl", "restart", "corosync", "pve-cluster"], timeout=30)
        run(["systemctl", "restart", "pvestatd"], timeout=30)

    def configure_storage(self):
        Log.step(7, self.total_steps, "Storage configuration")
        storage_cfg = Path("/etc/pve/storage.cfg")
        if not storage_cfg.exists():
            storage_cfg.write_text("""dir: local
        path /var/lib/vz
        content iso,vztmpl,backup,rootdir
""")
            Log.ok("storage.cfg created")
        else:
            # Remove maxfiles (not supported in PVE 9.x)
            content = storage_cfg.read_text()
            if "maxfiles" in content:
                content = re.sub(r'\s*maxfiles\s+\d+\s*\n?', '', content)
                storage_cfg.write_text(content)
                Log.ok("maxfiles removed from storage.cfg")
            else:
                Log.ok("storage.cfg exists")

    def setup_network(self):
        Log.step(7, self.total_steps, "Network: bridge + NAT + DHCP")
        run(["sysctl", "-w", "net.ipv4.ip_forward=1"], timeout=10)
        Path("/etc/sysctl.d/99-vpse.conf").write_text("net.ipv4.ip_forward=1\n")
        # vmbr0 bridge via Proxmox API
        r = run(["pvesh", "get", f"/nodes/{self.node_name}/network"], timeout=15)
        if "vmbr0" not in r.stdout:
            Log.info("Creating vmbr0 bridge (10.0.3.1/24)...")
            run(["pvesh", "create", f"/nodes/{self.node_name}/network",
                 "--type", "bridge", "--iface", "vmbr0",
                 "--address", "10.0.3.1", "--netmask", "255.255.255.0",
                 "--autostart", "1"], timeout=30)
            run(["ip", "link", "set", "vmbr0", "up"], timeout=10)
            Log.ok("Bridge vmbr0 created")
        # NAT
        sub = "10.0.3.0/24"
        r = run(["iptables", "-t", "nat", "-C", "POSTROUTING", "-s", sub, "-j", "MASQUERADE"], timeout=10)
        if r.returncode != 0:
            run(["iptables", "-t", "nat", "-A", "POSTROUTING", "-s", sub, "-j", "MASQUERADE"], timeout=10)
            run(["iptables", "-A", "FORWARD", "-s", sub, "-j", "ACCEPT"], timeout=10)
            run(["iptables", "-A", "FORWARD", "-d", sub, "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT"], timeout=10)
        # iptables-persistent
        debconf_set("iptables-persistent iptables-persistent/autosave_v4 boolean true\n")
        debconf_set("iptables-persistent iptables-persistent/autosave_v6 boolean true\n")
        Path("/etc/iptables").mkdir(exist_ok=True)
        env = {**os.environ, "DEBIAN_FRONTEND": "noninteractive"}
        run(["apt-get", "install", "-y", "iptables-persistent"], timeout=120, env=env)
        run(["netfilter-persistent", "save"], timeout=30)
        # dnsmasq DHCP
        if not shutil.which("dnsmasq"):
            run(["apt-get", "install", "-y", "dnsmasq"], timeout=120, env=env)
        dns_conf = Path("/etc/dnsmasq.d/vpse.conf")
        if not dns_conf.exists():
            dns_conf.parent.mkdir(parents=True, exist_ok=True)
            dns_conf.write_text("""interface=vmbr0
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
""")
            run(["systemctl", "enable", "dnsmasq"], timeout=30)
            run(["systemctl", "restart", "dnsmasq"], timeout=30)
        run(["apt", "--fix-broken", "install", "-y"], timeout=60)
        Log.ok("NAT + DHCP active (10.0.3.0/24)")

    def install_vpse_cli(self):
        Log.step(9, self.total_steps, "Install vpse CLI")
        vpse_path = Path("/usr/local/bin/vpse")
        vpse_script = Path(__file__).parent / "vpse.sh"
        if vpse_script.exists():
            vpse_path.write_text(vpse_script.read_text())
            vpse_path.chmod(0o755)
            Log.ok("vpse CLI installed")
        else:
            Log.warn("vpse.sh not found alongside installer")

    def restart_services(self):
        Log.step(10, self.total_steps, "Restart services")
        for svc in ["pve-cluster", "pveproxy", "pvedaemon", "pvestatd"]:
            run(["systemctl", "restart", svc], timeout=30)
        Log.ok("Services restarted")

    def verify(self):
        Log.step(10, self.total_steps, "Verification")
        if Path("/usr/share/pve-manager/index.html.tpl").exists():
            Log.ok("pve-manager template found")
        else: Log.warn("Template missing — Web UI may not work")
        r = run(["systemctl", "is-active", "pveproxy"], timeout=10)
        Log.ok("pveproxy is running" if r.returncode == 0 else "pveproxy not running")
        r = run(["systemctl", "is-active", "dnsmasq"], timeout=10)
        Log.ok("dnsmasq (DHCP) is running" if r.returncode == 0 else "dnsmasq not running")
        if shutil.which("pct"): Log.ok("pct (LXC) available")
        else: Log.warn("pct not found")

    def run(self):
        print("╔══════════════════════════════════╗")
        print("║   VpsE Proxmox Lite Installer   ║")
        print("╚══════════════════════════════════╝")
        print(f"   Node: {self.node_name}, Debian: {self.codename}, IP: {self.ip}")
        steps = [self.check_prerequisites, self.setup_repo, self.configure_hosts,
                 self.set_root_password, self.install_proxmox, self.init_cluster,
                 self.setup_network, self.configure_storage, self.install_vpse_cli,
                 self.restart_services, self.verify]
        for step_fn in steps:
            try: step_fn()
            except Exception as e:
                Log.fail(f"Step failed: {e}")
                sys.exit(1)
        print("\n╔══════════════════════════════════╗")
        print("║  VpsE Proxmox Lite — Done! 🎉  ║")
        print("╚══════════════════════════════════╝")
        print(f"\n  Web UI:  https://{self.ip}:8006  (root/{self.pve_password})")
        print("\n  vpse mk 100 8069 8069    → Port forward")
        print("  vpse list                → Overview")
        print()

def apt_install(*packages: str):
    env = os.environ.copy(); env["DEBIAN_FRONTEND"] = "noninteractive"
    cmd = ["apt-get", "install", "-y"] + list(packages)
    r = run(cmd, env=env)
    if r.returncode != 0:
        Log.warn(f"apt install {' '.join(packages)} failed")

if __name__ == "__main__":
    installer = ProxmoxLiteInstaller()
    installer.run()
