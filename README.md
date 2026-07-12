# VpsE Proxmox Lite

**Proxmox VE, stripped for LXC-only on a single-IP VPS — with NAT and DHCP out of the box.**

## Install

Run this on a **fresh Debian 12 or 13 VPS** as your user (debian, admin, etc.):

```bash
curl -sL https://raw.githubusercontent.com/VpsE-Scripts/Proxmox-Lite/master/install.sh | bash
```

> The installer auto-detects if you're not root and uses `sudo`.

> ⏱️ **Step 4 (Proxmox VE)** can take 5-15 minutes depending on your VPS. Be patient, the installer will continue automatically.

That's it. After a few minutes you'll have:

- Proxmox Web UI at `https://<your-vps-ip>:8006`
- The **`vpse`** CLI tool ready to use

## Proxmox Web UI

| Item | Value |
|---|---|
| URL | `https://<your-vps-ip>:8006` |
| Username | `root` |
| Password | `VpsE` |

## First container (via Web UI)

1. Open `https://<your-vps-ip>:8006` in your browser
2. Log in with **root** / **VpsE**
3. **Download a template:** `Datacenter → your-node → local (storage) → Templates → search "debian" → Download`
4. **Create a container:** `Datacenter → your-node → right-click → Create CT`
   - General: set VMID (e.g. 100), hostname, password
   - Template: select the downloaded Debian template
   - Network: set **IPv4 = DHCP**
   - Resources: default is fine
5. Start the container

## vpse CLI

Create containers and manage ports from the command line:

| Command | Description |
|---|---|
| `vpse ip 100` | Create container (DHCP → `10.0.3.100`) |
| `vpse delete 100` | Remove container + all ports |
| `vpse port 100 80 80` | Forward host:80 → container:80 |
| `vpse stop 100 80` | Disable port (config saved) |
| `vpse start 100 80` | Re-enable port |
| `vpse delport 100 80` | Permanently remove port |
| `vpse list` | Show all containers + ports |

### Examples

```bash
# Create container with fixed IP via DHCP
vpse ip 100

# Forward ports
vpse port 100 80 80
vpse port 100 443 443
vpse port 100 3000 3000

# Overview
vpse list

# Disable a port temporarily
vpse stop 100 80

# Re-enable it
vpse start 100 80

# Remove container + all ports
vpse delete 100
```

> Ports are saved in `/etc/vpse/ports.txt` and survive reboots automatically.
> Container password for `vpse ip` is `vpse4pve`.
