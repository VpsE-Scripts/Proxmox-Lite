Warning: Permanently added '141.95.112.122' (ED25519) to the list of known hosts.
#!/bin/bash
# VpsE — Proxmox VPS CLI: containers + port forwarding
set -uo pipefail

CONF="/etc/vpse/vpse.conf"
PORTS_DB="/etc/vpse/ports.txt"
DHCP_HOSTS="/etc/vpse/dhcp-hosts"
BRIDGE="vmbr0"
STORAGE="local"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
ok()   { echo -e " ${G}OK${N} $1"; }
warn() { echo -e " ${Y}!!${N} $1"; }
fail() { echo -e " ${R}XX${N} $1"; exit 1; }

# ─── Helpers ──────────────────────────────────────────────
get_ip() {
  local v="$1" i
  # Try pct exec to get actual IP from inside container
  i=$(pct exec "$v" -- ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
  [ -n "$i" ] && echo "$i" && return 0
  # Fallback: check DHCP hosts file
  [ -f "$DHCP_HOSTS/$v.conf" ] && {
    i=$(grep -aPo '10\.0\.3\.\d+' "$DHCP_HOSTS/$v.conf" 2>/dev/null)
    [ -n "$i" ] && echo "$i" && return 0
  }
  # Last resort: dnsmasq leases
  i=$(grep "$v" /var/lib/misc/dnsmasq.leases 2>/dev/null | awk '{print $3}' | head -1)
  [ -n "$i" ] && echo "$i" && return 0
  echo "10.0.3.$v"
}

valid_vmid() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 100 ] && [ "$1" -le 999 ]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
sv_ipt()   { command -v netfilter-persistent &>/dev/null && netfilter-persistent save 2>/dev/null || true; }
dhcp_rld() { systemctl restart dnsmasq 2>/dev/null || true; }

# Format: id:vmid:int_port:ext_port:status
# Example: 1:101:8069:8069:active

next_id() {
  local max=0
  while IFS=: read -r id rest; do
    [ -n "$id" ] && [ "$id" -gt "$max" ] 2>/dev/null && max=$id
  done < "$PORTS_DB"
  echo $((max + 1))
}

resolve_id() {
  local input="$1"
  # If input is a number and can be found as an ID in ports.txt, return it
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    if grep -q "^$input:" "$PORTS_DB" 2>/dev/null; then
      echo "$input"
      return 0
    fi
  fi
  return 1
}

ports_load()   { [ -f "$PORTS_DB" ] && cat "$PORTS_DB" 2>/dev/null || true; }

ports_del_id() {
  local id="$1"
  [ -f "$PORTS_DB" ] && sed -i "/^$id:/d" "$PORTS_DB" 2>/dev/null || true
}

ports_set_status() {
  local id="$1" s="$2"
  [ -f "$PORTS_DB" ] && sed -i "s/^\($id:.*:\).*/\1$s/" "$PORTS_DB" 2>/dev/null || true
}

ports_add() {
  mkdir -p "$(dirname "$PORTS_DB")"
  local id
  id=$(next_id)
  echo "$id:$1:$2:$3:active" >> "$PORTS_DB"
  echo "$id"
}

# ─── Firewall ─────────────────────────────────────────────
fw_add() {
  local I="$1" X="$2" i="$3"
  iptables -t nat -C PREROUTING -p tcp --dport "$X" -j DNAT --to-destination "$I:$i" 2>/dev/null && return 0
  iptables -t nat -A PREROUTING -p tcp --dport "$X" -j DNAT --to-destination "$I:$i"
  iptables -C FORWARD -p tcp -d "$I" --dport "$i" -j ACCEPT 2>/dev/null || iptables -A FORWARD -p tcp -d "$I" --dport "$i" -j ACCEPT
  sv_ipt
}

fw_rm() {
  local I="$1" X="$2" i="$3"
  iptables -t nat -D PREROUTING -p tcp --dport "$X" -j DNAT --to-destination "$I:$i" 2>/dev/null || true
  iptables -D FORWARD -p tcp -d "$I" --dport "$i" -j ACCEPT 2>/dev/null || true
  sv_ipt
}

fw_rmall() { local I="$1"; iptables-save | grep -v "to:$I" | iptables-restore 2>/dev/null || true; sv_ipt; }

# ─── DHCP ─────────────────────────────────────────────────
dhcp_reg() {
  mkdir -p "$DHCP_HOSTS"
  printf 'dhcp-host=%s,%s\n' "ct$1" "10.0.3.$1" > "$DHCP_HOSTS/$1.conf"
  mkdir -p /etc/dnsmasq.d
  printf 'conf-dir=%s,*.conf\n' "$DHCP_HOSTS" > /etc/dnsmasq.d/vpse-hosts.conf
  dhcp_rld
}
dhcp_unreg() { rm -f "$DHCP_HOSTS/$1.conf" 2>/dev/null || true; dhcp_rld; }

# ─── Commands ─────────────────────────────────────────────
cmd_ip() {
  local v="$1" i="$2" x="$3"
  valid_vmid "$v" || fail "VMID 100-999"
  pct config "$v" &>/dev/null && fail "Container $v exists"
  local t; t=$(ls /var/lib/vz/template/cache/debian-*-standard* 2>/dev/null | head -1)
  [ -z "$t" ] && fail "No Debian template found"
  pct create "$v" "$t" \
    --hostname "ct$v" --storage "$STORAGE" \
    --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" \
    --unprivileged 1 --features keyctl=1,nesting=1 \
    --cores 1 --memory 512 --swap 512 \
    --rootfs "$STORAGE:4" --password vpse4pve --start 1
  dhcp_reg "$v"
  ok "$v created (10.0.3.$v)"
  [ -n "$i" ] && [ -n "$x" ] && cmd_port "$v" "$i" "$x"
}

cmd_delete() {
  local v="$1"; valid_vmid "$v" || fail "VMID 100-999"
  local I; I=$(get_ip "$v")
  while IFS=: read -r id vmid rest; do
    if [ "$vmid" = "$v" ]; then
      local i x s
      IFS=: read -r id vmid i x s <<< "$id:$vmid:$rest"
      [ -n "$I" ] && fw_rm "$I" "$x" "$i"
      ports_del_id "$id"
      ok "Port ID $id ($x) removed"
    fi
  done < "$PORTS_DB"
  dhcp_unreg "$v"
  ok "All ports for container $v removed"
}

cmd_destroy() {
  local v="$1"; valid_vmid "$v" || fail "VMID 100-999"
  pct config "$v" &>/dev/null || fail "Not found"
  cmd_delete "$v"
  pct stop "$v" --skiplock 2>/dev/null || true
  pct destroy "$v" 2>/dev/null
  ok "Container $v destroyed"
}

cmd_port() {
  local v="$1" i="$2" x="$3"
  valid_vmid "$v" || fail "VMID 100-999"
  pct config "$v" &>/dev/null || fail "Not found"
  valid_port "$i" || fail "Bad internal port"
  [ -z "$x" ] && x="$i"
  valid_port "$x" || fail "Bad external port"
  local I; I=$(get_ip "$v"); [ -z "$I" ] && fail "No IP"
  local ex
  ex=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "dpt:$x " | grep -oP 'to:\K[0-9.]+' | head -1)
  [ -n "$ex" ] && [ "$ex" != "$I" ] && fail "Port $x already in use"
  fw_add "$I" "$x" "$i"
  local id; id=$(ports_add "$v" "$i" "$x")
  ok "ID $id — host:$x -> ${I}:$i"
}

# Commands that use vpseID (1, 2, 3...)
cmd_stop_id() {
  local id="$1"
  local line; line=$(grep "^$id:" "$PORTS_DB" 2>/dev/null) || fail "ID $id not found"
  local v i x s
  IFS=: read -r id v i x s <<< "$line"
  local I; I=$(get_ip "$v"); [ -z "$I" ] && fail "No IP for container $v"
  fw_rm "$I" "$x" "$i"
  ports_set_status "$id" "stopped"
  warn "ID $id ($x) stopped"
}

cmd_start_id() {
  local id="$1"
  local line; line=$(grep "^$id:" "$PORTS_DB" 2>/dev/null) || fail "ID $id not found"
  local v i x s
  IFS=: read -r id v i x s <<< "$line"
  [ "$s" != "stopped" ] && fail "ID $id is already active"
  local I; I=$(get_ip "$v"); [ -z "$I" ] && fail "No IP for container $v"
  fw_add "$I" "$x" "$i"
  ports_set_status "$id" "active"
  ok "ID $id ($x) enabled"
}

cmd_delport() {
  local id="$1"
  local line; line=$(grep "^$id:" "$PORTS_DB" 2>/dev/null) || fail "ID $id not found"
  local v i x s
  IFS=: read -r id v i x s <<< "$line"
  local I; I=$(get_ip "$v")
  [ -n "$I" ] && fw_rm "$I" "$x" "$i"
  ports_del_id "$id"
  ok "ID $id removed"
}

cmd_list() {
  local pub
  pub=$(curl -s --connect-timeout 3 https://ifconfig.me 2>/dev/null || echo "141.95.112.122")
  printf "  %-5s %-5s %-15s %-8s %-18s %s\n" "ID" "VMID" "Intern IP" "Int.Port" "Extern IP" "Ext.Port"
  echo "  ---------------------------------------------------------------------------"
  while IFS=: read -r id v i x s; do
    [ -z "$v" ] && continue
    [ "$s" = "stopped" ] && continue
    local ip; ip=$(get_ip "$v")
    printf "  %-5s %-5s %-15s %-8s %-18s %s\n" "$id" "$v" "$ip" "$i" "$pub" "$x"
  done < "$PORTS_DB"
}

# ─── Main ─────────────────────────────────────────────────
# Auto-detect: if arg is a number AND matches an ID in ports.txt, treat as ID
detect_cmd() {
  local sub="$1" arg="$2"
  case "$sub" in
    stop|start|delport)
      if [ -n "$arg" ] && grep -q "^$arg:" "$PORTS_DB" 2>/dev/null; then
        return 0  # It's an ID
      fi
      return 1  # Not an ID, may be old-style VMID
      ;;
  esac
  return 1
}

case "${1:-help}" in
  ip)      cmd_ip "$2" "$3" "$4" ;;
  delete)  cmd_delete "$2" ;;
  port)    cmd_port "$2" "$3" "$4" ;;
  stop)
    if [ -n "$2" ] && grep -q "^$2:" /etc/vpse/ports.txt 2>/dev/null; then cmd_stop_id "$2"
    else local v="$2" x="$3"; valid_vmid "$v" 2>/dev/null || fail; local l; l=$(grep ":$v:" /etc/vpse/ports.txt 2>/dev/null | grep ":$x:" | head -1); local id="${l%%:*}"; [ -n "$id" ] && cmd_stop_id "$id" || fail "No forward found for VMID $v port $x"; fi
    ;;
  start)
    if [ -n "$2" ] && grep -q "^$2:" /etc/vpse/ports.txt 2>/dev/null; then cmd_start_id "$2"
    else local v="$2" x="$3"; valid_vmid "$v" 2>/dev/null || fail; local l; l=$(grep ":$v:" /etc/vpse/ports.txt 2>/dev/null | grep ":$x:" | head -1); local id="${l%%:*}"; [ -n "$id" ] && cmd_start_id "$id" || fail "No forward found for VMID $v port $x"; fi
    ;;
  delport)
    if [ -n "$2" ] && grep -q "^$2:" /etc/vpse/ports.txt 2>/dev/null; then cmd_delport "$2"
    else local v="$2" x="$3"; valid_vmid "$v" 2>/dev/null || fail; local l; l=$(grep ":$v:" /etc/vpse/ports.txt 2>/dev/null | grep ":$x:" | head -1); local id="${l%%:*}"; [ -n "$id" ] && cmd_delport "$id" || fail "No forward found for VMID $v port $x"; fi
    ;;
  list)    cmd_list ;;
  help|--help|-h)
    echo "VpsE CLI — Proxmox port forwarding"
    echo "  vpse ip <vmid> [int_port ext_port]   Create container + optional forward"
    echo "  vpse port <vmid> <int> <ext>         New forward (gets ID)"
    echo "  vpse delete <vmid>                   Delete container + all its forwards"
    echo "  vpse list                            Show all active forwards"
    echo "  vpse stop <ID>                       Disable forward by ID"
    echo "  vpse start <ID>                      Enable forward by ID"
    echo "  vpse delport <ID>                    Remove forward by ID"
    echo "Example:"
    echo "  vpse port 101 8069 8069    → krijgt ID 1"
    echo "  vpse stop 1                → stopt ID 1"
    echo "  vpse start 1               → start ID 1"
    echo "  vpse delport 1             → verwijdert ID 1"
    echo "  vpse list                  → toont alle IDs"
    ;;
  *) echo "Use: vpse help"; exit 1 ;;
esac
