#!/usr/bin/env bash
set -euo pipefail

CONF_FILE="/etc/sysctl.d/99-custom-tcp.conf"
BACKUP_DIR="/root/sysctl-backups"
REPORT_FILE="/root/vps-tcp-autotune-report.txt"

PING_COUNT=5
DRY_RUN=0
FORWARDING_MODE="auto"   # auto, on, off
TPROXY_MODE="off"        # off, on
FORCE_BUFFER=""
FORCE_CONGESTION=""

TARGETS=(
  "www.189.cn"  # China Telecom
  "baidu.com"
  "taobao.com"
  "163.com"
)

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --forward              Force enable IPv4/IPv6 forwarding
  --no-forward           Force disable IPv4/IPv6 forwarding
  --auto-forward         Auto-detect forwarding need, default
  --tproxy               Enable TProxy-friendly extras: route_localnet=1 and rp_filter=0
  --target HOST          Add custom mainland China ping target, domain or IP
  --count N              Ping count per target, default: 5
  --buffer BYTES         Force TCP buffer max, e.g. 33554432, 67108864, 134217728
  --congestion NAME      Force congestion control, e.g. bbr, cubic
  --dry-run              Print generated config only, do not write or apply
  -h, --help             Show this help

Examples:
  bash $0
  bash $0 --forward
  bash $0 --no-forward
  bash $0 --tproxy --forward
  bash $0 --buffer 67108864
  bash $0 --target baidu.com --target 163.com --count 8
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forward)
      FORWARDING_MODE="on"
      shift
      ;;
    --no-forward)
      FORWARDING_MODE="off"
      shift
      ;;
    --auto-forward)
      FORWARDING_MODE="auto"
      shift
      ;;
    --tproxy)
      TPROXY_MODE="on"
      shift
      ;;
    --target)
      TARGETS+=("$2")
      shift 2
      ;;
    --count)
      PING_COUNT="$2"
      shift 2
      ;;
    --buffer)
      FORCE_BUFFER="$2"
      shift 2
      ;;
    --congestion)
      FORCE_CONGESTION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Please run as root."
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

read_file_or_empty() {
  local file="$1"
  if [[ -r "$file" ]]; then
    cat "$file" 2>/dev/null || true
  fi
}

get_kernel_version() {
  uname -r
}

get_os_info() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "${PRETTY_NAME:-unknown}"
  else
    echo "unknown"
  fi
}

get_mem_mb() {
  awk '/MemTotal/ {printf "%d\n", $2 / 1024}' /proc/meminfo
}

get_cpu_count() {
  nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "1"
}

get_virt_type() {
  if command_exists systemd-detect-virt; then
    systemd-detect-virt 2>/dev/null || echo "none"
  else
    if grep -qa docker /proc/1/cgroup 2>/dev/null; then
      echo "docker"
    elif grep -qa lxc /proc/1/cgroup 2>/dev/null; then
      echo "lxc"
    elif [[ -d /proc/vz && ! -d /proc/bc ]]; then
      echo "openvz"
    else
      echo "unknown"
    fi
  fi
}

is_container_like() {
  local virt="$1"
  case "$virt" in
    docker|lxc|podman|container|openvz)
      echo "1"
      ;;
    *)
      if grep -qaE 'docker|lxc|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
        echo "1"
      else
        echo "0"
      fi
      ;;
  esac
}

get_default_iface_v4() {
  ip route get 1.1.1.1 2>/dev/null | awk '
    {
      for (i=1; i<=NF; i++) {
        if ($i == "dev") {
          print $(i+1)
          exit
        }
      }
    }
  '
}

get_default_gw_v4() {
  ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'
}

has_ipv6_default_route() {
  if ip -6 route show default 2>/dev/null | grep -q '^default'; then
    echo "1"
  else
    echo "0"
  fi
}

get_default_iface_v6() {
  ip -6 route show default 2>/dev/null | awk '/default/ {
    for (i=1; i<=NF; i++) {
      if ($i == "dev") {
        print $(i+1)
        exit
      }
    }
  }'
}

get_iface_speed_mbps() {
  local iface="$1"
  local speed=""

  if [[ -n "$iface" && -r "/sys/class/net/$iface/speed" ]]; then
    speed="$(cat "/sys/class/net/$iface/speed" 2>/dev/null || true)"
    if [[ "$speed" =~ ^[0-9]+$ && "$speed" -gt 0 ]]; then
      echo "$speed"
      return
    fi
  fi

  if command_exists ethtool && [[ -n "$iface" ]]; then
    speed="$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed:/ {print $2}' | head -n1)"
    case "$speed" in
      *Gb/s)
        echo "$speed" | sed 's/Gb\/s//' | awk '{printf "%d\n", $1 * 1000}'
        return
        ;;
      *Mb/s)
        echo "$speed" | sed 's/Mb\/s//' | awk '{printf "%d\n", $1}'
        return
        ;;
    esac
  fi

  echo "0"
}

get_mtu() {
  local iface="$1"
  if [[ -n "$iface" && -r "/sys/class/net/$iface/mtu" ]]; then
    cat "/sys/class/net/$iface/mtu"
  else
    echo "0"
  fi
}

has_tun_device() {
  if [[ -c /dev/net/tun ]]; then
    echo "1"
  else
    echo "0"
  fi
}

has_tproxy_modules_or_rules() {
  local hit=0

  if lsmod 2>/dev/null | grep -Eq 'xt_TPROXY|nf_tproxy|nft_tproxy'; then
    hit=1
  fi

  if command_exists iptables && iptables-save 2>/dev/null | grep -qi 'TPROXY'; then
    hit=1
  fi

  if command_exists nft && nft list ruleset 2>/dev/null | grep -qi 'tproxy'; then
    hit=1
  fi

  echo "$hit"
}

detect_proxy_like_processes() {
  local names="xray|v2ray|sing-box|hysteria|tuic|trojan|naive|brook|wireguard|wg-quick|tailscale|zerotier|openvpn"
  if ps -eo comm,args 2>/dev/null | grep -Eiq "$names"; then
    echo "1"
  else
    echo "0"
  fi
}

detect_listening_ports_summary() {
  if command_exists ss; then
    ss -lntup 2>/dev/null | awk 'NR>1 {print}' | head -n 30
  else
    echo "ss not found"
  fi
}

ping_avg_ms() {
  local target="$1"
  local output avg

  if ! output="$(ping -c "$PING_COUNT" -W 2 "$target" 2>/dev/null)"; then
    return 1
  fi

  avg="$(echo "$output" | awk -F'/' '/rtt|round-trip/ {print $5}')"

  if [[ -z "$avg" ]]; then
    return 1
  fi

  printf "%.0f\n" "$avg"
}

pick_best_latency() {
  local best_target=""
  local best_ms=""
  local ms

  for target in "${TARGETS[@]}"; do
    echo "Pinging $target ..." >&2
    if ms="$(ping_avg_ms "$target")"; then
      echo "  $target avg: ${ms} ms" >&2
      if [[ -z "$best_ms" || "$ms" -lt "$best_ms" ]]; then
        best_ms="$ms"
        best_target="$target"
      fi
    else
      echo "  $target failed" >&2
    fi
  done

  if [[ -z "$best_ms" ]]; then
    echo "0 unknown"
  else
    echo "$best_ms $best_target"
  fi
}

choose_buffer_bytes() {
  local latency_ms="$1"
  local mem_mb="$2"
  local speed_mbps="$3"
  local mtu="$4"
  local virt="$5"

  if [[ -n "$FORCE_BUFFER" ]]; then
    echo "$FORCE_BUFFER"
    return
  fi

  # OpenVZ / container-like environments often have stricter kernel limits.
  case "$virt" in
    openvz|docker|lxc|podman|container)
      if [[ "$mem_mb" -lt 1024 ]]; then
        echo "16777216"   # 16MB
      else
        echo "33554432"   # 32MB
      fi
      return
      ;;
  esac

  # Tiny VPS: avoid exaggerated socket buffers.
  if [[ "$mem_mb" -lt 768 ]]; then
    echo "16777216"       # 16MB
    return
  fi

  # 100 Mbps or lower: giant buffers usually add little.
  if [[ "$speed_mbps" -gt 0 && "$speed_mbps" -le 100 ]]; then
    if [[ "$latency_ms" -gt 180 && "$mem_mb" -ge 1024 ]]; then
      echo "33554432"     # 32MB
    else
      echo "16777216"     # 16MB
    fi
    return
  fi

  # Unknown latency: safe default.
  if [[ "$latency_ms" -le 0 ]]; then
    if [[ "$mem_mb" -ge 1024 ]]; then
      echo "33554432"     # 32MB
    else
      echo "16777216"     # 16MB
    fi
    return
  fi

  # Low RTT, mostly Asia-Pacific.
  if [[ "$latency_ms" -le 80 ]]; then
    if [[ "$mem_mb" -ge 1024 ]]; then
      echo "33554432"     # 32MB
    else
      echo "16777216"     # 16MB
    fi
    return
  fi

  # Medium RTT.
  if [[ "$latency_ms" -le 180 ]]; then
    if [[ "$mem_mb" -ge 1024 ]]; then
      echo "67108864"     # 64MB
    else
      echo "33554432"     # 32MB
    fi
    return
  fi

  # High RTT, Europe/US or detoured routes.
  if [[ "$mem_mb" -ge 2048 && "$speed_mbps" -ge 1000 ]]; then
    echo "134217728"      # 128MB
  else
    echo "67108864"       # 64MB
  fi
}

choose_tcp_rmem_mid() {
  local latency_ms="$1"

  if [[ "$latency_ms" -gt 180 ]]; then
    echo "131072"
  else
    echo "87380"
  fi
}

choose_somaxconn() {
  local mem_mb="$1"
  local cpu_count="$2"

  if [[ "$mem_mb" -ge 2048 && "$cpu_count" -ge 2 ]]; then
    echo "8192"
  else
    echo "4096"
  fi
}

choose_syn_backlog() {
  local mem_mb="$1"
  local cpu_count="$2"

  if [[ "$mem_mb" -ge 2048 && "$cpu_count" -ge 2 ]]; then
    echo "8192"
  else
    echo "4096"
  fi
}

choose_file_max() {
  local mem_mb="$1"

  if [[ "$mem_mb" -ge 4096 ]]; then
    echo "6815744"
  elif [[ "$mem_mb" -ge 1024 ]]; then
    echo "2097152"
  else
    echo "1048576"
  fi
}

choose_swappiness() {
  local mem_mb="$1"

  if [[ "$mem_mb" -lt 768 ]]; then
    echo "20"
  else
    echo "10"
  fi
}

choose_forwarding() {
  local mode="$1"
  local has_tun="$2"
  local proxy_like="$3"
  local tproxy_like="$4"

  case "$mode" in
    on)
      echo "1"
      ;;
    off)
      echo "0"
      ;;
    auto)
      # Auto mode is intentionally conservative:
      # enable only when there is a clear sign of VPN/proxy/router use.
      if [[ "$has_tun" -eq 1 || "$proxy_like" -eq 1 || "$tproxy_like" -eq 1 ]]; then
        echo "1"
      else
        echo "0"
      fi
      ;;
  esac
}

choose_congestion() {
  if [[ -n "$FORCE_CONGESTION" ]]; then
    echo "$FORCE_CONGESTION"
    return
  fi

  if [[ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
      echo "bbr"
      return
    fi
  fi

  if modprobe tcp_bbr 2>/dev/null; then
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
      echo "bbr"
      return
    fi
  fi

  cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "cubic"
}

choose_qdisc() {
  local container_like="$1"

  if [[ "$container_like" -eq 1 ]]; then
    # Some containers cannot set fq; still write fq only if current namespace accepts it.
    if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
      echo "fq"
    else
      current="$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo fq_codel)"
      echo "$current"
    fi
  else
    echo "fq"
  fi
}

generate_config() {
  local file_max="$1"
  local somaxconn="$2"
  local syn_backlog="$3"
  local qdisc="$4"
  local congestion="$5"
  local buffer_bytes="$6"
  local tcp_rmem_mid="$7"
  local swappiness="$8"
  local forwarding="$9"
  local tproxy_mode="${10}"
  local has_ipv6="${11}"

  cat <<EOF
# Generated by vps-tcp-autotune.sh
# Safe TCP tuning for mainland China -> overseas VPS access
# Re-run this script after changing VPS region, provider, kernel, or main workload.

fs.file-max = ${file_max}

net.core.somaxconn = ${somaxconn}
net.ipv4.tcp_max_syn_backlog = ${syn_backlog}

net.core.default_qdisc = ${qdisc}
net.ipv4.tcp_congestion_control = ${congestion}

net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_moderate_rcvbuf = 1

net.core.rmem_max = ${buffer_bytes}
net.core.wmem_max = ${buffer_bytes}

net.ipv4.tcp_rmem = 4096 ${tcp_rmem_mid} ${buffer_bytes}
net.ipv4.tcp_wmem = 4096 65536 ${buffer_bytes}

net.ipv4.ip_local_port_range = 1024 65535

net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_mtu_probing = 1

vm.swappiness = ${swappiness}
EOF

  if [[ "$forwarding" -eq 1 ]]; then
    cat <<EOF

# Forwarding enabled by auto-detection or CLI option.
net.ipv4.ip_forward = 1
EOF
    if [[ "$has_ipv6" -eq 1 ]]; then
      cat <<EOF
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF
    fi
  else
    cat <<EOF

# Forwarding disabled. Use --forward if this VPS is a proxy/VPN/router node.
net.ipv4.ip_forward = 0
EOF
    if [[ "$has_ipv6" -eq 1 ]]; then
      cat <<EOF
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0
EOF
    fi
  fi

  if [[ "$tproxy_mode" == "on" ]]; then
    cat <<EOF

# TProxy mode enabled by --tproxy.
# Only use this when you know your transparent proxy rules require it.
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.default.route_localnet = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
  fi
}

write_report() {
  local report="$1"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    printf "%s\n" "$report" > "$REPORT_FILE"
  fi
}

main() {
  need_root

  if ! command_exists ping; then
    echo "ping command not found."
    exit 1
  fi

  if ! command_exists ip; then
    echo "ip command not found."
    exit 1
  fi

  kernel_version="$(get_kernel_version)"
  os_info="$(get_os_info)"
  mem_mb="$(get_mem_mb)"
  cpu_count="$(get_cpu_count)"
  virt_type="$(get_virt_type)"
  container_like="$(is_container_like "$virt_type")"

  iface_v4="$(get_default_iface_v4)"
  gw_v4="$(get_default_gw_v4)"
  iface_v6="$(get_default_iface_v6)"
  has_ipv6="$(has_ipv6_default_route)"

  speed_mbps="$(get_iface_speed_mbps "$iface_v4")"
  mtu="$(get_mtu "$iface_v4")"

  has_tun="$(has_tun_device)"
  tproxy_like="$(has_tproxy_modules_or_rules)"
  proxy_like="$(detect_proxy_like_processes)"

  read -r latency_ms best_target < <(pick_best_latency)

  file_max="$(choose_file_max "$mem_mb")"
  somaxconn="$(choose_somaxconn "$mem_mb" "$cpu_count")"
  syn_backlog="$(choose_syn_backlog "$mem_mb" "$cpu_count")"
  congestion="$(choose_congestion)"
  qdisc="$(choose_qdisc "$container_like")"
  buffer_bytes="$(choose_buffer_bytes "$latency_ms" "$mem_mb" "$speed_mbps" "$mtu" "$virt_type")"
  tcp_rmem_mid="$(choose_tcp_rmem_mid "$latency_ms")"
  swappiness="$(choose_swappiness "$mem_mb")"
  forwarding="$(choose_forwarding "$FORWARDING_MODE" "$has_tun" "$proxy_like" "$tproxy_like")"

  config="$(generate_config \
    "$file_max" \
    "$somaxconn" \
    "$syn_backlog" \
    "$qdisc" \
    "$congestion" \
    "$buffer_bytes" \
    "$tcp_rmem_mid" \
    "$swappiness" \
    "$forwarding" \
    "$TPROXY_MODE" \
    "$has_ipv6"
  )"

  report="$(cat <<EOF
Detected information:
  OS                  : ${os_info}
  Kernel              : ${kernel_version}
  Virtualization      : ${virt_type}
  Container-like      : ${container_like}
  CPU cores           : ${cpu_count}
  Memory              : ${mem_mb} MB

Network:
  IPv4 default iface  : ${iface_v4:-unknown}
  IPv4 gateway        : ${gw_v4:-unknown}
  IPv6 default route  : ${has_ipv6}
  IPv6 default iface  : ${iface_v6:-unknown}
  Interface speed     : ${speed_mbps} Mbps, 0 means unknown
  Interface MTU       : ${mtu}

China latency test:
  Best ping target    : ${best_target:-unknown}
  Best avg latency    : ${latency_ms} ms
  Ping count          : ${PING_COUNT}

Workload hints:
  TUN device exists   : ${has_tun}
  Proxy-like process  : ${proxy_like}
  TProxy-like rules   : ${tproxy_like}
  Forwarding mode     : ${FORWARDING_MODE}
  TProxy mode         : ${TPROXY_MODE}

Chosen parameters:
  fs.file-max         : ${file_max}
  somaxconn           : ${somaxconn}
  tcp_max_syn_backlog : ${syn_backlog}
  qdisc               : ${qdisc}
  congestion control  : ${congestion}
  tcp buffer max      : ${buffer_bytes}
  tcp_rmem middle     : ${tcp_rmem_mid}
  swappiness          : ${swappiness}
  forwarding          : ${forwarding}

Listening ports, first 30 lines:
$(detect_listening_ports_summary)
EOF
)"

  echo
  echo "$report"
  echo

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Generated config:"
    echo
    echo "$config"
    exit 0
  fi

  mkdir -p "$BACKUP_DIR"

  if [[ -f "$CONF_FILE" ]]; then
    cp "$CONF_FILE" "$BACKUP_DIR/99-custom-tcp.conf.bak.$(date +%F-%H%M%S)"
  fi

  printf "%s\n" "$config" > "$CONF_FILE"
  write_report "$report"

  echo "Written config to $CONF_FILE"
  echo "Written report to $REPORT_FILE"
  echo "Applying sysctl settings..."

  if ! sysctl --system; then
    echo
    echo "sysctl --system failed."
    echo "Your provider/kernel may not support one or more parameters."
    echo "Backup directory: $BACKUP_DIR"
    exit 1
  fi

  echo
  echo "Applied. Current values:"
  sysctl net.ipv4.tcp_congestion_control || true
  sysctl net.core.default_qdisc || true
  sysctl net.ipv4.tcp_mtu_probing || true
  sysctl net.core.rmem_max || true
  sysctl net.core.wmem_max || true
  sysctl net.ipv4.tcp_rmem || true
  sysctl net.ipv4.tcp_wmem || true
  sysctl net.ipv4.ip_forward || true
  sysctl net.ipv6.conf.all.forwarding 2>/dev/null || true

  echo
  echo "Done."
}

main "$@"
