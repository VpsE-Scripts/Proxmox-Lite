#!/bin/bash
# VpsE CLI — port forwarding only
set -uo pipefail

CONF="/etc/vpse/vpse.conf"
PORTS_DB="/etc/vpse/ports.txt"
DHCP_HOSTS="/etc/vpse/dhcp-hosts"
BRIDGE="vmbr0"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
ok()   { echo -e " ${G}OK${N} $1"; }
warn() { echo -e " ${Y}!!${N} $1"; }
fail() { echo -e " ${R}XX${N} $1"; exit 1; }

get_ip() {
  local v="$1" i
  # Check dnsmasq leases first (most reliable)
  i=$(grep " $v " /var/lib/misc/dnsmasq.leases 2>/dev/null | awk '{print $3}' | head -1)
  [ -n "$i" ] && echo "$i" && return 0
  i=$(grep "ct$v " /var/lib/misc/dnsmasq.leases 2>/dev/null | awk '{print $3}' | head -1)
  [ -n "$i" ] && echo "$i" && return 0
  # Try pct exec
  i=$(pct exec "$v" -- ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
  [ -n "$i" ] && echo "$i" && return 0
  # Check DHCP hosts file
  [ -f "$DHCP_HOSTS/$v.conf" ] && { i=$(grep -aPo '10\.0\.3\.\d+' "$DHCP_HOSTS/$v.conf" 2>/dev/null); [ -n "$i" ] && echo "$i" && return 0; }
  # No fallback — fail instead of using wrong IP
  fail "Could not determine IP for container $v (check dnsmasq leases)"
}

valid_vmid() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 100 ] && [ "$1" -le 999 ]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
sv_ipt()   { command -v netfilter-persistent &>/dev/null && netfilter-persistent save 2>/dev/null || true; }

next_id() {
  local max=0
  while IFS=: read -r id rest; do [ -n "$id" ] && [ "$id" -gt "$max" ] 2>/dev/null && max=$id; done < "$PORTS_DB"
  echo $((max + 1))
}
ports_load()   { [ -f "$PORTS_DB" ] && cat "$PORTS_DB" 2>/dev/null || true; }
ports_del_id() { local id="$1"; [ -f "$PORTS_DB" ] && sed -i "/^$id:/d" "$PORTS_DB" 2>/dev/null || true; }
ports_set_status() { local id="$1" s="$2"; [ -f "$PORTS_DB" ] && sed -i "s/^\($id:.*:\).*/\1$s/" "$PORTS_DB" 2>/dev/null || true; }
ports_add() { mkdir -p "$(dirname "$PORTS_DB")"; local id; id=$(next_id); echo "$id:$1:$2:$3:active" >> "$PORTS_DB"; echo "$id"; }

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

cmd_mk() {
  local v="$1" i="$2" x="$3"
  valid_vmid "$v" || fail "VMID 100-999"
  pct config "$v" &>/dev/null || fail "Container $v not found"
  valid_port "$i" || fail "Bad internal port"
  [ -z "$x" ] && x="$i"
  valid_port "$x" || fail "Bad external port"
  local I; I=$(get_ip "$v"); [ -z "$I" ] && fail "No IP for container $v"
  local ex; ex=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "dpt:$x " | grep -oP 'to:\K[0-9.]+' | head -1)
  [ -n "$ex" ] && [ "$ex" != "$I" ] && fail "Port $x already in use"
  fw_add "$I" "$x" "$i"
  local id; id=$(ports_add "$v" "$i" "$x")
  ok "ID $id — host:$x -> ${I}:$i"
}

cmd_stop() {
  local id="$1"
  local line; line=$(grep "^$id:" "$PORTS_DB" 2>/dev/null) || fail "ID $id not found"
  local v i x s; IFS=: read -r id v i x s <<< "$line"
  local I; I=$(get_ip "$v"); [ -z "$I" ] && fail "No IP for container $v"
  fw_rm "$I" "$x" "$i"; ports_set_status "$id" "stopped"
  warn "ID $id ($x) stopped"
}

cmd_start() {
  local id="$1"
  local line; line=$(grep "^$id:" "$PORTS_DB" 2>/dev/null) || fail "ID $id not found"
  local v i x s; IFS=: read -r id v i x s <<< "$line"
  [ "$s" != "stopped" ] && fail "ID $id is already active"
  local I; I=$(get_ip "$v"); [ -z "$I" ] && fail "No IP for container $v"
  fw_add "$I" "$x" "$i"; ports_set_status "$id" "active"
  ok "ID $id ($x) enabled"
}

cmd_delete() {
  local id="$1"
  local line; line=$(grep "^$id:" "$PORTS_DB" 2>/dev/null) || fail "ID $id not found"
  local v i x s; IFS=: read -r id v i x s <<< "$line"
  local I; I=$(get_ip "$v")
  [ -n "$I" ] && fw_rm "$I" "$x" "$i"
  ports_del_id "$id"
  ok "ID $id removed"
}

cmd_rm() {
  local v="$1"; valid_vmid "$v" || fail "VMID 100-999"
  local I; I=$(get_ip "$v")
  while IFS=: read -r id vmid i x s; do
    [ "$vmid" = "$v" ] && { fw_rm "$I" "$x" "$i"; ports_del_id "$id"; ok "Port ID $id ($x) removed"; }
  done < "$PORTS_DB"
  ok "All ports for container $v removed"
}

cmd_list() {
  local pub; pub=$(curl -s --connect-timeout 3 https://ifconfig.me 2>/dev/null || echo "141.95.112.122")
  printf "  %-5s %-5s %-15s %-8s %-18s %s\n" "ID" "VMID" "Intern IP" "Int.Port" "Extern IP" "Ext.Port"
  echo "  ---------------------------------------------------------------------------"
  while IFS=: read -r id v i x s; do
    [ -z "$v" ] && continue; [ "$s" = "stopped" ] && continue
    local ip; ip=$(get_ip "$v")
    printf "  %-5s %-5s %-15s %-8s %-18s %s\n" "$id" "$v" "$ip" "$i" "$pub" "$x"
  done < "$PORTS_DB"
}

case "${1:-help}" in
  mk)      cmd_mk "$2" "$3" "$4" ;;
  list)    cmd_list ;;
  stop)    cmd_stop "$2" ;;
  start)   cmd_start "$2" ;;
  delete)  cmd_delete "$2" ;;
  rm)      cmd_rm "$2" ;;
  help|--help|-h)
    echo "VpsE CLI — port forwarding"
    echo "  vpse mk <vmid> <int> <ext>       Create forward (gets ID)"
    echo "  vpse list                        Show all forwards"
    echo "  vpse stop <ID>                   Disable forward"
    echo "  vpse start <ID>                  Enable forward"
    echo "  vpse delete <ID>                 Remove forward"
    echo "  vpse rm <vmid>                   Remove all forwards for a container"
    echo ""
    echo "Examples:"
    echo "  vpse mk 100 8069 8069    → ID 1"
    echo "  vpse stop 1              → stop ID 1"
    echo "  vpse delete 1            → remove ID 1"
    echo "  vpse rm 100              → remove all forwards for container 100"
    echo "  vpse list"
    ;;
  *) echo "Use: vpse help"; exit 1 ;;
esac