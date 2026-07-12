# VpsE Proxmox Lite

**Proxmox VE, stripped for LXC-only on a single-IP VPS — with NAT and DHCP out of the box.**

## What is this?

A one-shot installer that turns a plain Debian 12 VPS into a lightweight Proxmox VE — without the heavy VM, ZFS, or Ceph components. Just LXC containers with a NAT network and DHCP server, ready in minutes.

Perfect for VPS plans from OVHcloud, Hetzner, Netcup, or any provider where you get a single public IP.

## What you get

| Component | Status |
|---|---|
| Proxmox VE | ✅ Web UI, API, LXC containers |
| QEMU/KVM VMs | ❌ Removed |
| ZFS storage | ❌ Removed |
| Ceph storage | ❌ Removed |
| NAT networking | ✅ `10.0.3.0/24` subnet with masquerade |
| DHCP server | ✅ dnsmasq (pool `10.0.3.200`–`10.0.3.250`) |
| Port forwarding | ✅ Via iptables DNAT |

## Quick start

Run this on a **fresh Debian 12 VPS** as root:

```bash
curl -sL https://raw.githubusercontent.com/pixels2bits/vpse-proxmox-lite/main/install.sh | bash
```

That's it. After a few minutes you'll have:

- Proxmox Web UI at `https://<your-vps-ip>:8006`
- NAT + DHCP ready on `vmbr0` (subnet `10.0.3.0/24`)
- All VM/ZFS/Ceph packages stripped out

## Creating your first container

### With DHCP (automatic IP)

```bash
pct create 100 /var/lib/vz/template/cache/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname ct100 --storage local \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 1 --rootfs local:4

pct start 100
pct enter 100
```

The container gets IP `10.0.3.200`+ from the DHCP pool.

### With a fixed IP (via DHCP reservation)

Write the hostname and IP to a dnsmasq config file, then restart:

```bash
mkdir -p /etc/vpse/dhcp-hosts
echo 'dhcp-host=ct100,10.0.3.100' > /etc/vpse/dhcp-hosts/100.conf
echo 'conf-dir=/etc/vpse/dhcp-hosts,*.conf' > /etc/dnsmasq.d/vpse-hosts.conf
systemctl restart dnsmasq
```

Then create the container with `ip=dhcp` as above — dnsmasq will assign `10.0.3.100`.

### With a static IP (no DHCP)

```bash
pct create 100 /var/lib/vz/template/cache/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname ct100 --storage local \
  --net0 name=eth0,bridge=vmbr0,ip=10.0.3.100/24,gw=10.0.3.1 \
  --unprivileged 1 --rootfs local:4

pct start 100
```

## Port forwarding

Forward a public port on the VPS to a port inside a container:

```bash
# Forward host:80 → 10.0.3.100:80
iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 80 \
  -j DNAT --to-destination 10.0.3.100:80
iptables -A FORWARD -p tcp -d 10.0.3.100 --dport 80 -j ACCEPT
netfilter-persistent save
```

To list active forwards:

```bash
iptables -t nat -L PREROUTING -n | grep dpt:
```

To remove a forward:

```bash
iptables -t nat -D PREROUTING -i vmbr0 -p tcp --dport 80 \
  -j DNAT --to-destination 10.0.3.100:80
iptables -D FORWARD -p tcp -d 10.0.3.100 --dport 80 -j ACCEPT
netfilter-persistent save
```

## What the installer does

1. Adds the Proxmox VE repository
2. Fixes `/etc/hosts` (required for `pve-cluster`)
3. Installs Proxmox VE
4. Removes VM/ZFS/Ceph packages — replaces them with dummy packages via `equivs`
5. Copies Perl stub modules so `pveproxy` keeps working
6. Enables IP forwarding and NAT masquerade for `10.0.3.0/24`
7. Installs dnsmasq as a DHCP server on `vmbr0`
8. Restarts all Proxmox services

## Requirements

- **OS:** Debian 12 (Bookworm)
- **RAM:** 2 GB minimum (4 GB recommended for LXC workloads)
- **Disk:** 20 GB minimum
- **Arch:** x86_64 / amd64

## Notes for OVHcloud VPS

If your VPS is from OVHcloud, the installer handles the `grub-pc` post-install issue automatically. After installation, LXC containers will have internet access via NAT (masquerade) — **no additional proxy configuration needed for standard workloads**.

## License

MIT
