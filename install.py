1|#!/usr/bin/env python3
2|"""
3|VpsE Proxmox Lite — Python Installer
4|Van kale Debian 12/13 → Proxmox (LXC-only) + NAT + DHCP + vpse CLI
5|Zero external dependencies — stdlib only.
6|"""
7|
8|import os, sys, subprocess, shutil, tempfile, textwrap, re, json
9|from pathlib import Path
10|from typing import List, Optional
11|
12|# ─── Constants ──────────────────────────────────────────────────────
13|PROXMOX_REPO = "http://download.proxmox.com/debian/pve"
14|ENTERPRISE_REPO = "https://enterprise.proxmox.com/debian/pve"
15|GPG_URL = "https://download.proxmox.com/debian/proxmox-release-{codename}.gpg"
16|# ─── Logging ────────────────────────────────────────────────────────
17|class Log:
18|    @staticmethod
19|    def ok(msg):   print(f" \033[32m✅\033[0m {msg}")
20|    @staticmethod
21|    def warn(msg): print(f" \033[33m⚠️\033[0m {msg}")
22|    @staticmethod
23|    def fail(msg): print(f" \033[31m❌\033[0m {msg}")
24|    @staticmethod
25|    def info(msg): print(f"   {msg}")
26|    @staticmethod
27|    def step(n, total, title):
28|        print(f"\n\033[36m[{n}/{total}]\033[0m {title}")
29|
30|# ─── Helpers ────────────────────────────────────────────────────────
31|def run(cmd: List[str], check=False, timeout=300, **kw) -> subprocess.CompletedProcess:
32|    """Run a command and return the result."""
33|    try:
34|        return subprocess.run(cmd, capture_output=True, text=True,
35|                              timeout=timeout, check=check, **kw)
36|    except subprocess.CalledProcessError as e:
37|        return subprocess.CompletedProcess(cmd, e.returncode, e.stdout, e.stderr)
38|    except FileNotFoundError:
39|        return subprocess.CompletedProcess(cmd, -1, "", f"Command not found: {cmd[0]}")
40|
41|def apt_install(*packages: str, opts: Optional[List[str]] = None) -> bool:
42|    """Install packages with DEBIAN_FRONTEND=noninteractive."""
43|    env = os.environ.copy()
44|    env["DEBIAN_FRONTEND"] = "noninteractive"
45|    cmd = ["apt-get", "install", "-y"] + (opts or []) + list(packages)
46|    r = run(cmd, env=env)
47|    if r.returncode != 0:
48|        Log.warn(f"apt install {' '.join(packages)} failed: {r.stderr[-200:]}")
49|        return False
50|    return True
51|
52|def debconf_set(selection: str):
53|    run(["debconf-set-selections"], input=selection, timeout=10)
54|
55|def dpkg_is_installed(pkg: str) -> bool:
56|    r = run(["dpkg", "-l", pkg], timeout=10)
57|    return r.returncode == 0 and any(
58|        l.startswith("ii") for l in r.stdout.splitlines()
59|    )
60|
86|
87|def hostname() -> str:
88|    return run(["hostname"], timeout=5).stdout.strip()
89|
90|def public_ip() -> str:
91|    r = run(["ip", "-4", "route", "get", "1.1.1.1"], timeout=10)
92|    m = re.search(r'src (\S+)', r.stdout)
93|    if m:
94|        return m.group(1)
95|    r = run(["curl", "-s", "--connect-timeout", "5", "https://ifconfig.me"], timeout=10)
96|    return r.stdout.strip()
97|
98|# ─── Installer class ────────────────────────────────────────────────
99|class ProxmoxLiteInstaller:
100|    def __init__(self):
101|        self.codename = ""
102|        self.ip = ""
103|        self.node_name = os.environ.get("PROXMOX_NAME") or hostname() or "pve"
104|        self.pve_password = os.environ.get("PROXMOX_PASSWORD") or "VpsE"
105|        self.total_steps = 11
106|
107|    def check_prerequisites(self):
108|        """Stap 1 — Check: root, Debian, netwerk"""
109|        Log.step(1, self.total_steps, "Prerequisites")
110|        if os.geteuid() != 0:
111|            # Try sudo
112|            r = run(["sudo", "-n", "true"], timeout=10)
113|            if r.returncode == 0:
114|                os.execvp("sudo", ["sudo", "python3"] + sys.argv)
115|            Log.fail("Must run as root")
116|            sys.exit(1)
117|        # Debian version
118|        osrel = Path("/etc/os-release").read_text() if Path("/etc/os-release").exists() else ""
119|        m = re.search(r'VERSION_CODENAME=(\w+)', osrel)
120|        if not m or m.group(1) not in ("bookworm", "trixie"):
121|            Log.fail("Only Debian 12 (bookworm) or 13 (trixie) supported")
122|            sys.exit(1)
123|        self.codename = m.group(1)
124|        self.ip = public_ip()
125|        if not self.ip:
126|            Log.fail("Could not determine public IP")
127|            sys.exit(1)
128|        Log.ok(f"Debian {self.codename}, IP: {self.ip}, node: {self.node_name}")
129|
130|    def setup_repo(self):
131|        """Stap 2 — Proxmox repository"""
132|        Log.step(2, self.total_steps, "Proxmox repository")
133|        # Add no-subscription repo
134|        Path("/etc/apt/sources.list.d/pve.list").write_text(
135|            f"deb {PROXMOX_REPO} {self.codename} pve-no-subscription\n"
136|        )
137|        # Disable enterprise repos
138|        for f in ["/etc/apt/sources.list.d/pve-enterprise.list",
139|                   "/etc/apt/sources.list.d/pve-enterprise.sources"]:
140|            p = Path(f)
141|            if p.exists():
142|                p.rename(p.with_suffix(p.suffix + ".disabled"))
143|        # GPG key
144|        gpg_path = "/etc/apt/trusted.gpg.d/proxmox.gpg"
145|        if not Path(gpg_path).exists():
146|            r = run(["curl", "-fsSL", "--insecure", GPG_URL.format(codename=self.codename),
147|                     "-o", gpg_path], timeout=30)
148|            if r.returncode != 0:
149|                r = run(["curl", "-fsSL", "--insecure", GPG_URL.format(codename=self.codename),
150|                         "-o", gpg_path], timeout=30)
151|        # apt update
152|        r = run(["apt-get", "update"], timeout=120)
153|        if r.returncode != 0:
154|            Log.warn("apt update had issues (enterprise repo disabled)")
155|        Log.ok("Repository configured")
156|
157|    def configure_hosts(self):
158|        """Stap 3 — /etc/hosts + hostname"""
159|        Log.step(3, self.total_steps, "Host configuration")
160|        run(["hostnamectl", "set-hostname", self.node_name], timeout=10)
161|        hosts = Path("/etc/hosts").read_text()
162|        # Remove 127.0.1.1 line
163|        hosts = re.sub(r'^127\.0\.1\.1\s.*\n?', '', hosts, flags=re.MULTILINE)
164|        # Add public IP → hostname if not present
165|        if self.ip not in hosts:
166|            hosts += f"\n{self.ip} {self.node_name}\n"
167|            Path("/etc/hosts").write_text(hosts)
168|        Log.ok(f"hosts: {self.ip} → {self.node_name}")
169|
170|    def set_root_password(self):
171|        """Stap 4 — Root wachtwoord voor Web UI"""
172|        Log.step(4, self.total_steps, "Root password")
173|        r = run(["chpasswd"], input=f"root:{self.pve_password}", timeout=10)
174|        if r.returncode == 0:
175|            Log.ok("Root password set")
176|        else:
177|            Log.warn("Could not set root password")
178|
179|    def install_proxmox(self):
180|        """Stap 5 — proxmox-ve installeren"""
181|        Log.step(5, self.total_steps, "Installing Proxmox VE")
182|        Log.info("This can take 5-15 minutes...")
183|        if dpkg_is_installed("pve-manager") and dpkg_is_installed("proxmox-ve"):
184|            Log.ok("Already installed")
185|            return
186|        debconf_set("grub-pc grub-pc/install_devices multiselect /dev/sda\n")
187|        debconf_set("postfix postfix/main_mailer_type select No configuration\n")
188|        ok = apt_install("proxmox-ve")
189|        if not ok or not dpkg_is_installed("pve-manager"):
195|                        opts=["--no-install-recommends"])
196|        ver = run(["pveversion"], timeout=5).stdout.strip()
197|        Log.ok(ver or "Proxmox VE installed")
198|
281|        if Path("/etc/pve/corosync.conf").exists():
282|            Log.ok("Cluster already configured")
283|            return
    def init_cluster(self):
        """Step 6 — Initialize corosync cluster (single-node)"""
        Log.step(6, self.total_steps, "Cluster initialization")
        if Path("/etc/pve/corosync.conf").exists():
            Log.ok("Cluster already configured")
            return
        cluster_name = f"vps-{self.node_name}"
        r = run(["pvecm", "create", cluster_name], timeout=30)
        if r.returncode == 0:
            Log.ok(f"Cluster '{cluster_name}' created")
        else:
            Log.warn(f"Cluster creation failed: {r.stderr[:200]}")
            run(["systemctl", "restart", "corosync", "pve-cluster"], timeout=30)
        run(["systemctl", "restart", "pvestatd"], timeout=30)
312|        else:
313|            Log.warn("storage.cfg not found (will be created on first use)")
314|
315|    def download_template(self):
316|        """Step 7b — Download Debian LXC template"""
317|        Log.step(7.5, self.total_steps, "Download LXC template")
318|        cache_dir = Path("/var/lib/vz/template/cache")
319|        cache_dir.mkdir(parents=True, exist_ok=True)
320|        # Check if any debian template already exists
321|        existing = list(cache_dir.glob("debian-*-standard*"))
322|        if existing:
323|            Log.ok(f"Template already exists: {existing[0].name}")
324|            return
325|        # Update template list
326|        run(["pveam", "update"], timeout=60)
327|        # Find the latest Debian template matching our codename
328|        r = run(["pveam", "available"], timeout=30)
329|        target = f"debian-{self.codename}-standard"
330|        for line in r.stdout.splitlines():
331|            if target in line and "amd64" in line:
332|                template = line.split()[-1].strip()
333|                Log.info(f"Downloading {template}...")
334|                r2 = run(["pveam", "download", "local", template], timeout=300)
335|                if r2.returncode == 0:
336|                    Log.ok(f"Template downloaded: {template}")
337|                else:
338|                    Log.warn(f"Template download failed: {r2.stderr[:200]}")
339|                return
340|        Log.warn(f"No template found for {target}")
341|
342|    def setup_network(self):
343|        """Stap 8 — vmbr0 bridge + NAT + DHCP"""
344|        Log.step(8, self.total_steps, "Network: bridge + NAT + DHCP")
345|
346|        # IP forwarding
347|        run(["sysctl", "-w", "net.ipv4.ip_forward=1"], timeout=10)
348|        Path("/etc/sysctl.d/99-vpse.conf").write_text("net.ipv4.ip_forward=1\n")
349|
350|        # vmbr0 bridge
351|        r = run(["ip", "link", "show", "vmbr0"], timeout=10)
352|        if b"UP" not in r.stdout.encode() if hasattr(r.stdout, 'encode') else "UP" not in r.stdout:
353|            Log.info("Creating vmbr0 bridge (10.0.3.1/24)...")
354|            run(["ip", "link", "add", "name", "vmbr0", "type", "bridge"], timeout=10)
355|            run(["ip", "link", "set", "vmbr0", "up"], timeout=10)
356|            run(["ip", "addr", "add", "10.0.3.1/24", "dev", "vmbr0"], timeout=10)
357|            # Register with Proxmox network config for Web UI DHCP support
358|            run(["pvesh", "create", f"/nodes/{self.node_name}/network",
359|                 "--type", "bridge", "--iface", "vmbr0",
360|                 "--address", "10.0.3.1", "--netmask", "255.255.255.0",
361|                 "--autostart", "1"], timeout=30)
362|            Log.ok("Bridge vmbr0 created (Proxmox registered)")
363|        else:
364|            # Ensure IP is set
365|            if "10.0.3.1" not in run(["ip", "addr", "show", "vmbr0"], timeout=10).stdout:
366|                run(["ip", "addr", "add", "10.0.3.1/24", "dev", "vmbr0"], timeout=10)
367|            # Still register with Proxmox if not already registered
368|            r2 = run(["pvesh", "get", f"/nodes/{self.node_name}/network"], timeout=15)
369|            if "vmbr0" not in r2.stdout:
370|                run(["pvesh", "create", f"/nodes/{self.node_name}/network",
371|                     "--type", "bridge", "--iface", "vmbr0",
372|                     "--address", "10.0.3.1", "--netmask", "255.255.255.0",
373|                     "--autostart", "1"], timeout=30)
374|
375|        # NAT masquerade
376|        sub = "10.0.3.0/24"
377|        r = run(["iptables", "-t", "nat", "-C", "POSTROUTING", "-s", sub,
378|                 "-j", "MASQUERADE"], timeout=10)
379|        if r.returncode != 0:
380|            run(["iptables", "-t", "nat", "-A", "POSTROUTING", "-s", sub,
381|                 "-j", "MASQUERADE"], timeout=10)
382|            run(["iptables", "-A", "FORWARD", "-s", sub, "-j", "ACCEPT"], timeout=10)
383|            run(["iptables", "-A", "FORWARD", "-d", sub,
384|                 "-m", "state", "--state", "RELATED,ESTABLISHED",
385|                 "-j", "ACCEPT"], timeout=10)
386|
387|        # iptables-persistent
388|        debconf_set("iptables-persistent iptables-persistent/autosave_v4 boolean true\n")
389|        debconf_set("iptables-persistent iptables-persistent/autosave_v6 boolean true\n")
390|        Path("/etc/iptables").mkdir(exist_ok=True)
391|        env = {**os.environ, "DEBIAN_FRONTEND": "noninteractive"}
392|        run(["apt-get", "install", "-y", "iptables-persistent"], timeout=120, env=env)
393|        run(["netfilter-persistent", "save"], timeout=30)
394|
395|        # dnsmasq DHCP
396|        if not shutil.which("dnsmasq"):
397|            run(["apt-get", "install", "-y", "dnsmasq"], timeout=120, env=env)
398|
399|        dns_conf = Path("/etc/dnsmasq.d/vpse.conf")
400|        if not dns_conf.exists():
401|            dns_conf.parent.mkdir(parents=True, exist_ok=True)
402|            dns_conf.write_text(textwrap.dedent("""\
403|                interface=vmbr0
404|                bind-interfaces
405|                domain=vpse.local
406|                dhcp-range=10.0.3.200,10.0.3.250,12h
407|                dhcp-option=3,10.0.3.1
408|                dhcp-option=6,10.0.3.1
409|                port=53
410|                no-resolv
411|                server=1.1.1.1
412|                server=8.8.8.8
413|                no-dhcp-interface=lo
414|            """))
415|            run(["systemctl", "enable", "dnsmasq"], timeout=30)
416|            run(["systemctl", "restart", "dnsmasq"], timeout=30)
417|
418|        # Fix any remaining broken deps
419|        run(["apt", "--fix-broken", "install", "-y"], timeout=60)
420|        Log.ok("NAT + DHCP active (10.0.3.0/24)")
421|
422|    def install_vpse_cli(self):
423|        """Stap 9 — vpse CLI installeren"""
424|        Log.step(9, self.total_steps, "Install vpse CLI")
425|        vpse_path = Path("/usr/local/bin/vpse")
426|        vpse_script = (Path(__file__).parent / "vpse.sh").read_text()
427|        vpse_path.write_text(vpse_script)
428|        vpse_path.chmod(0o755)
429|        Log.ok("vpse CLI installed")
430|
431|    def restart_services(self):
432|        """Stap 10 — Services herstarten"""
433|        Log.step(10, self.total_steps, "Restart services")
434|        for svc in ["pve-cluster", "pveproxy", "pvedaemon", "pvestatd"]:
435|            run(["systemctl", "restart", svc], timeout=30)
436|        Log.ok("Services restarted")
437|
438|    def verify(self):
439|        """Stap 11 — Verificatie"""
440|        Log.step(11, self.total_steps, "Verification")
441|
442|        tpl = Path("/usr/share/pve-manager/index.html.tpl")
443|        if tpl.exists():
444|            Log.ok("pve-manager template found")
445|        else:
446|            Log.warn("Template missing — Web UI may not work")
447|
448|        r = run(["systemctl", "is-active", "pveproxy"], timeout=10)
449|        if r.returncode == 0:
450|            Log.ok("pveproxy is running")
451|        else:
452|            Log.warn("pveproxy not running — try: systemctl restart pveproxy")
453|
454|        r = run(["systemctl", "is-active", "dnsmasq"], timeout=10)
455|        if r.returncode == 0:
456|            Log.ok("dnsmasq (DHCP) is running")
457|        else:
458|            Log.warn("dnsmasq not running")
459|
460|        if shutil.which("pct"):
461|            Log.ok("pct (LXC) available")
462|        else:
463|            Log.warn("pct not found — pve-container may not be installed")
464|
465|    def run(self):
466|        """Run all steps."""
467|        print("╔══════════════════════════════════╗")
468|        print("║   VpsE Proxmox Lite Installer   ║")
469|        print("╚══════════════════════════════════╝")
470|        print(f"   Node: {self.node_name}, Debian: {self.codename}, IP: {self.ip}")
471|
472|        steps = [
473|            self.check_prerequisites,
474|            self.setup_repo,
475|            self.configure_hosts,
476|            self.set_root_password,
477|            self.install_proxmox,
479|            self.init_cluster,
480|            self.configure_storage,
481|            self.download_template,
482|            self.setup_network,
483|            self.install_vpse_cli,
484|            self.restart_services,
485|            self.verify,
486|        ]
487|        for step_fn in steps:
488|            try:
489|                step_fn()
490|            except Exception as e:
491|                Log.fail(f"Step failed: {e}")
492|                sys.exit(1)
493|
494|        print()
495|        print("╔══════════════════════════════════╗")
496|        print("║  VpsE Proxmox Lite — Done! 🎉  ║")
497|        print("╚══════════════════════════════════╝")
498|        print()
499|        print(f"  Web UI:  https://{self.ip}:8006  (root/{self.pve_password})")
500|        print()
501|