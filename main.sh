#!/usr/bin/env bash

# ===============================
# HONEYGAIN NETWORK MANAGER (tun2socks, per-instance namespace isolation)
# ===============================

set -euo pipefail

ulimit -n 1048576 2>/dev/null || ulimit -n 65535 2>/dev/null || true

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

# Fix CRLF if needed
for f in "$BASE_DIR"/*.sh; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null || true
done

chmod +x "$BASE_DIR/app/honeygain_file/honeygain" 2>/dev/null || true

HONEYGAIN_SCRIPT="$BASE_DIR/direct_honeygain.sh"
HONEYGAIN_ACCOUNTS_FILE="$BASE_DIR/honeygain_password.txt"
INSTALL_SCRIPT="$BASE_DIR/install_tun2socks.sh"
PROPERTIES_FILE="$BASE_DIR/properties.conf"

PIDS=()
EXITING=0
HONEYGAIN_ACCOUNTS=()

declare -A NS_INDEX=(
  [honeyns]=7
)

CREATED_NETNS=()
CREATED_SUBNETS=()

HOST_IF="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
[ -n "$HOST_IF" ] || HOST_IF="eth0"

load_properties() {
  if [[ -f "$PROPERTIES_FILE" ]]; then
    echo "Loading config from $(basename "$PROPERTIES_FILE")"
    set -a
    # shellcheck disable=SC1090
    source "$PROPERTIES_FILE"
    set +a
  else
    echo "No properties.conf found at $PROPERTIES_FILE, using script defaults."
  fi
}

kernel_tune() {
  echo "Applying conservative kernel tuning for high-scale (safe defaults)..."

  sudo modprobe nf_conntrack 2>/dev/null || true
  ulimit -n 2097152 || true
  sudo sysctl -w fs.file-max=1000000 >/dev/null || true
  sudo sysctl -w fs.nr_open=2000000 >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_fin_timeout=30 >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_max_tw_buckets=200000 >/dev/null || true
  sudo sysctl -w net.netfilter.nf_conntrack_max=262144 >/dev/null || true
  sudo sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=600 >/dev/null || true
  sudo sysctl -w net.core.somaxconn=65535 >/dev/null || true
  sudo sysctl -w net.core.netdev_max_backlog=262144 >/dev/null || true
  sudo sysctl -w net.core.rmem_max=67108864 >/dev/null || true
  sudo sysctl -w net.core.wmem_max=67108864 >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 33554432" >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 33554432" >/dev/null || true
  sudo sysctl -w vm.max_map_count=262144 >/dev/null || true
  sudo sysctl -w vm.swappiness=10 >/dev/null || true
  sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
  sudo sysctl -w fs.inotify.max_user_instances=1048576 >/dev/null 2>&1 || true
  sudo sysctl -w fs.inotify.max_user_watches=1048576 >/dev/null 2>&1 || true
  sudo sysctl -w fs.inotify.max_queued_events=1048576 >/dev/null 2>&1 || true
  sudo modprobe tcp_bbr 2>/dev/null || true
  sudo sysctl -w net.core.default_qdisc=fq >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null || true

  echo "Kernel tuning applied (conservative)."
}

create_netns_with_veth() {
  local ns="$1"
  local veth_prefix="${2:-veth}"
  local idx="${3:-0}"

  if [ "$idx" -eq 0 ]; then
    idx="${NS_INDEX[$ns]:-0}"
    if [ -z "$idx" ] || [ "$idx" -eq 0 ]; then
      idx=10
      while ip netns list | grep -qw "ns${idx}"; do
        idx=$((idx+1))
      done
    fi
  fi

  if ip netns list | awk '{print $1}' | grep -qw "$ns"; then
    echo "Netns $ns already exists, skipping creation."
    return 0
  fi

  echo "Creating netns $ns with veth prefix ${veth_prefix} idx ${idx}..."
  sudo ip netns add "$ns"
  CREATED_NETNS+=("$ns")

  local host_if="${veth_prefix}h${idx}"
  local ns_if="${veth_prefix}n${idx}"
  local host_ip="10.200.${idx}.1/24"
  local ns_ip="10.200.${idx}.2/24"
  local subnet="10.200.${idx}.0/24"

  sudo ip link add "$host_if" type veth peer name "$ns_if"
  sudo ip link set "$ns_if" netns "$ns"
  sudo ip addr add "$host_ip" dev "$host_if" || true
  sudo ip link set "$host_if" up
  sudo ip netns exec "$ns" ip addr add "$ns_ip" dev "$ns_if"
  sudo ip netns exec "$ns" ip link set "$ns_if" up
  sudo ip netns exec "$ns" ip link set lo up
  sudo ip netns exec "$ns" ip route add default via "10.200.${idx}.1" || true

  sudo mkdir -p "/etc/netns/$ns"
  echo "nameserver 1.1.1.1" | sudo tee /etc/netns/"$ns"/resolv.conf >/dev/null
  echo "nameserver 8.8.8.8" | sudo tee -a /etc/netns/"$ns"/resolv.conf >/dev/null

  sudo iptables -t nat -A POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE
  CREATED_SUBNETS+=("$subnet")
  echo "Netns $ns created: host dev $host_if ($host_ip) <-> ns dev $ns_if ($ns_ip)."
}

cleanup() {
  [[ "$EXITING" == "1" ]] && return
  EXITING=1
  echo -e "\nStopping all running services..."

  for pid in "${PIDS[@]:-}"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done

  echo "Running aggressive process fallback cleanup..."
  sudo pkill -f direct_honeygain.sh || true
  sudo pkill -f tun2socks || true
  sudo pkill -f honeygain || true

  wait 2>/dev/null || true

  for subnet in "${CREATED_SUBNETS[@]:-}"; do
    sudo iptables -t nat -D POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE 2>/dev/null || true
  done

  for ns in "${CREATED_NETNS[@]:-}"; do
    sudo ip netns delete "$ns" 2>/dev/null || true
    sudo rm -rf /etc/netns/"$ns" 2>/dev/null || true
  done
  echo "All services and network namespaces stopped/removed."
  exit 0
}
trap cleanup INT TERM

install_dependencies() {
  sudo apt update && sudo apt install -y curl wget unzip iproute2 iptables uuid-runtime jq net-tools git socat
}

load_honeygain_accounts() {
  HONEYGAIN_ACCOUNTS=()
  if [[ -f "$HONEYGAIN_ACCOUNTS_FILE" ]]; then
    while IFS='|' read -r email password; do
      [[ -n "${email:-}" && -n "${password:-}" ]] || continue
      HONEYGAIN_ACCOUNTS+=("$email|$password")
    done < "$HONEYGAIN_ACCOUNTS_FILE"
  fi
}

save_honeygain_accounts() {
  : > "$HONEYGAIN_ACCOUNTS_FILE"
  chmod 600 "$HONEYGAIN_ACCOUNTS_FILE"
  local account
  for account in "${HONEYGAIN_ACCOUNTS[@]}"; do
    printf '%s\n' "$account" >> "$HONEYGAIN_ACCOUNTS_FILE"
  done
}

collect_honeygain_accounts() {
  local mode="$1"
  local count=1
  local email password

  if [[ "$mode" == "multiple" ]]; then
    while true; do
      read -rp "How many Honeygain accounts do you want to add? " count
      [[ "$count" =~ ^[1-9][0-9]*$ ]] && break
      echo "Please enter a valid number greater than 0."
    done
  fi

  for ((i=1; i<=count; i++)); do
    echo "Honeygain account $i"
    while true; do
      read -rp "Email: " email
      [[ -n "$email" ]] && break
      echo "Email cannot be empty."
    done
    while true; do
      read -rsp "Password: " password
      echo
      [[ -n "$password" ]] && break
      echo "Password cannot be empty."
    done
    HONEYGAIN_ACCOUNTS+=("$email|$password")
  done
}

setup_honeygain_accounts() {
  load_honeygain_accounts

  if (( ${#HONEYGAIN_ACCOUNTS[@]} > 0 )); then
    echo "Found ${#HONEYGAIN_ACCOUNTS[@]} saved Honeygain account(s) in $(basename "$HONEYGAIN_ACCOUNTS_FILE")."
    read -rp "Do you want to use the saved Honeygain accounts? [Y/n]: " reuse_choice
    reuse_choice="${reuse_choice:-Y}"
    if [[ ! "$reuse_choice" =~ ^[Yy]$ ]]; then
      HONEYGAIN_ACCOUNTS=()
    else
      read -rp "Do you want to add more Honeygain accounts before starting? [y/N]: " add_more_choice
      if [[ "$add_more_choice" =~ ^[Yy]$ ]]; then
        collect_honeygain_accounts multiple
      fi
    fi
  fi

  if (( ${#HONEYGAIN_ACCOUNTS[@]} == 0 )); then
    echo "Honeygain setup:"
    echo "1) Single account"
    echo "2) Multiple accounts"
    local setup_choice
    while true; do
      read -rp "Select option [1-2]: " setup_choice
      case "$setup_choice" in
        1) collect_honeygain_accounts single; break ;;
        2) collect_honeygain_accounts multiple; break ;;
        *) echo "Invalid option. Please choose 1 or 2." ;;
      esac
    done
  fi

  if (( ${#HONEYGAIN_ACCOUNTS[@]} == 0 )); then
    echo "No Honeygain accounts configured."
    return 1
  fi

  save_honeygain_accounts
  echo "Saved ${#HONEYGAIN_ACCOUNTS[@]} Honeygain account(s) to $(basename "$HONEYGAIN_ACCOUNTS_FILE")."
}

run_honeygain() {
  local mode="${1:-bg}"
  if [[ ! -x "$HONEYGAIN_SCRIPT" ]]; then
    echo "direct_honeygain.sh not found or not executable at $HONEYGAIN_SCRIPT"
    return
  fi
  if [[ ! -x "$BASE_DIR/app/honeygain_file/honeygain" ]]; then
    echo "Honeygain binary not found or not executable at $BASE_DIR/app/honeygain_file/honeygain"
    return
  fi

  setup_honeygain_accounts || return
  create_netns_with_veth "honeyns" "honey" "${NS_INDEX[honeyns]}"
  echo "Starting Honeygain..."
  if [[ "$mode" == "fg" ]]; then
    trap 'echo "Returning to main menu..."' INT
    sudo -E BASE_NS=honeyns \
         VETH_PREFIX=honey \
         WORKDIR=/tmp/honeygain_multi \
         HONEYGAIN_ACCOUNTS_FILE="$HONEYGAIN_ACCOUNTS_FILE" \
         bash "$HONEYGAIN_SCRIPT" proxies.txt || true
    trap cleanup INT TERM
  else
    sudo -E BASE_NS=honeyns \
         VETH_PREFIX=honey \
         WORKDIR=/tmp/honeygain_multi \
         HONEYGAIN_ACCOUNTS_FILE="$HONEYGAIN_ACCOUNTS_FILE" \
         bash "$HONEYGAIN_SCRIPT" proxies.txt &
    PIDS+=($!)
  fi
}

menu() {
  echo -e "\n====== HONEYGAIN NETWORK MANAGER ======"
  echo "1) Install tun2socks"
  echo "2) Install Dependencies"
  echo "H) Run Honeygain"
  echo "0) Exit"
  echo "========================================"
}

kernel_tune
load_properties

while true; do
  menu
  read -rp "Select option: " opt || cleanup
  case "$opt" in
    1) sudo bash "$INSTALL_SCRIPT" ;;
    2) install_dependencies ;;
    H|h) run_honeygain "fg" ;;
    0) cleanup ;;
    *) echo "Invalid option." ;;
  esac
done
