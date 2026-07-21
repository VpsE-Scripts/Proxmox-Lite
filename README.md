# VpsE Proxmox

**Proxmox VE installer + bridge + NAT + DHCP + port forwarding CLI.**

Designed for single-IP VPS where you want to run LXC containers behind NAT.

## Install

Run on a **fresh Debian 12 or 13 VPS**:

```bash
curl -sL https://raw.githubusercontent.com/VpsE-Scripts/Proxmox-Lite/master/install.sh | bash
```

> ⏱️ **Step 3 (Proxmox VE)** can take 5-15 minutes. The installer continues automatically.

After completion you'll have:
- Proxmox Web UI at `https://<your-vps-ip>:8006`
- **`vpse`** CLI tool for port forwarding
- vmbr0 bridge with NAT + DHCP
- dnsmasq serving DHCP on `10.0.3.200-250`

## vpse CLI

Run on the Proxmox host (SSH or console) via `sudo vpse`:

| Command | Description |
|---|---|
| `vpse mk 100 8069 8069` | Create forward (host:8069 → container 100:8069, gets ID) |
| `vpse list` | Show all active forwards |
| `vpse stop 1` | Disable forward ID 1 |
| `vpse start 1` | Re-enable forward ID 1 |
| `vpse delete 1` | Remove forward ID 1 |
| `vpse rm 100` | Remove all forwards for container 100 |

**VMID** = container number → `mk <vmid>` / `rm <vmid>`
**ID** = forward number → `stop <ID>` / `start <ID>` / `delete <ID>`

## What it does

- Adds Proxmox VE repository and installs `proxmox-ve` (complete)
- Creates `vmbr0` bridge (10.0.3.1/24) — persistent in `/etc/network/interfaces`
- Configures NAT masquerade + iptables-persistent
- Installs dnsmasq for DHCP (port 0, DHCP only)
- Installs `vpse` CLI for port forwarding
