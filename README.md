# VpsE Proxmox Lite

**Proxmox VE installer — complete install + bridge + NAT + DHCP + port forwarding CLI.**

Designed for single-IP VPS (OVH, Hetzner, etc.) where you want to run LXC containers behind NAT.

## Install

Run on a **fresh Debian 12 or 13 VPS**:

```bash
curl -sL https://raw.githubusercontent.com/VpsE-Scripts/Proxmox-Lite/master/install.sh | PROXMOX_NAME=vpse PROXMOX_CLUSTER=vpse PROXMOX_PASSWORD=VpsE bash
```

> ⏱️ **Step 5 (Proxmox VE)** can take 5-15 minutes. The installer continues automatically.
 
Change `PROXMOX_NAME`,`PROXMOX_CLUSTER`and`PROXMOX_PASSWORD` to set a custom node and datacenter name.

| Variable | Default | Description |
|---|---|---|
| `PROXMOX_NAME` | Current hostname | Proxmox node name |
| `PROXMOX_CLUSTER` | `vps-{node}` | Cluster/datacenter name |
| `PROXMOX_PASSWORD` | `VpsE` | Web UI root password |

After completion you'll have:

- Proxmox Web UI at `https://<your-vps-ip>:8006`
- **`vpse`** CLI tool for port forwarding
- vmbr0 bridge with NAT + DHCP (containers get IPs automatically)
- dnsmasq serving DHCP on `10.0.3.200-250`

## Proxmox Web UI

| Item | Value |
|---|---|
| URL | `https://<your-vps-ip>:8006` |
| Username | `root` |
| Password | `VpsE` |

## vpse CLI

Port forwarding management. Works with iptables DNAT — persistent across reboots.

| Command | Description |
|---|---|
| `vpse mk 100 8069 8069` | Create forward (host:8069 → container 100:8069, gets ID) |
| `vpse list` | Show all active forwards |
| `vpse stop 1` | Disable forward ID 1 (config kept) |
| `vpse start 1` | Re-enable forward ID 1 |
| `vpse delete 1` | Remove forward ID 1 permanently |
| `vpse rm 100` | Remove all forwards for container 100 |

**VMID** = container number → `mk <vmid>` / `rm <vmid>`
**ID** = forward number → `stop <ID>` / `start <ID>` / `delete <ID>`

### Examples

```bash
# Forward port
vpse mk 100 8069 8069        # → ID 1 (host:8069 → container 100:8069)
vpse mk 101 80 8080          # → ID 2 (host:8080 → container 101:80)

# Overview
vpse list

# Disable/enable
vpse stop 1
vpse start 1

# Remove
vpse delete 2

# Remove all forwards for a container
vpse rm 100
```

> Ports are saved in `/etc/vpse/ports.txt` and survive reboots.
> The installer also configures `iptables-persistent` so NAT rules persist.

## What gets installed

- **Proxmox VE** — complete installation (no packages removed)
- **vmbr0 bridge** — `10.0.3.1/24` for containers
- **NAT masquerade** — containers reach internet via host IP
- **dnsmasq** — DHCP server for containers
- **iptables-persistent** — NAT rules survive reboot
- **vpse CLI** — port forwarding management
- **corosync cluster** — single-node, so Web UI shows node online

All Proxmox components are kept: QEMU/KVM, Ceph libraries, ZFS — they consume no resources unless used.
