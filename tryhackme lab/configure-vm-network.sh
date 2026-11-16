#!/usr/bin/env bash
#
# configure-vm-network.sh
#
# Network and firewall baseline for the Redline Forge / ForgeTrack
# Ubuntu 24.04 lab VM.
#
# Run inside the VM as root:
#   sudo bash configure-vm-network.sh
#   sudo bash configure-vm-network.sh --static 192.168.56.10/24 --gateway 192.168.56.1
#   sudo bash configure-vm-network.sh --verify
#
# What it does:
#   1. Detects the primary NIC (or uses --interface).
#   2. Writes /etc/netplan/01-lab.yaml with DHCP (default) or a static address.
#   3. Applies netplan and waits for an IPv4 address.
#   4. Configures UFW: deny inbound by default, allow 22/tcp and 80/tcp.
#   5. Verifies listeners and warns if Gunicorn/PostgreSQL are publicly bound.
#
# The existing /etc/netplan configuration is backed up under
# /var/backups/redline-forge/network/<timestamp>/ before it is replaced.
#
# If the NIC name changes after an OVA import, re-run this script (or pass
# --interface with the new name) so the netplan file matches the interface.
#
# WARNING: this changes network configuration. Keep console access available.
# Use it only on the disposable lab VM.
#
# Tested on Ubuntu Server 24.04 LTS.

set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
LOG_FILE=${LOG_FILE:-/var/log/redline-forge-network.log}
BACKUP_ROOT=${BACKUP_ROOT:-/var/backups/redline-forge/network}

IFACE=""
MODE="dhcp"                 # dhcp | static
STATIC_CIDR=""
GATEWAY=""
DNS_LIST=""
DNS_YAML=""
ALLOW_HTTPS=0
EXTRA_PORTS=()

NETPLAN_ENABLE=1
UFW_ENABLE=1
KEEP_EXISTING=0
DISABLE_CLOUD_INIT=0
DRY_RUN=0
VERIFY_ONLY=0
STRICT=0

SSH_PORT=22
HTTP_PORT=80
IPV4=""
FAILURES=0

usage() {
  cat <<'EOF'
Configure networking and firewall ports for the ForgeTrack lab VM.

Usage:
  sudo bash configure-vm-network.sh [options]

Network:
  --dhcp                     Use DHCP on the primary interface (default).
  --static CIDR              Use a static IPv4 address, e.g. 192.168.56.10/24.
  --gateway IP               Default gateway for --static.
  --dns "IP[,IP...]"         DNS servers, e.g. "1.1.1.1,9.9.9.9".
  --interface IFACE          Interface to configure (default: auto-detect).
  --keep-existing-netplan    Write 99-lab.yaml instead of replacing all
                             existing netplan files. Advanced use only.
  --disable-cloud-init       Stop cloud-init from managing network config.
  --no-netplan               Leave netplan alone; only configure the firewall.

Firewall:
  --no-ufw                   Do not change UFW.
  --https                    Also allow 443/tcp.
  --allow PORT[/proto]       Allow an extra port (repeatable), e.g.
                             --allow 443/tcp --allow 51820/udp.

Safety and checks:
  --dry-run                  Print actions without changing anything.
  --verify                   Only inspect the current state; make no changes.
  --strict                   Exit non-zero if verification finds an issue.
  -h, --help                 Show this help.

Examples:
  sudo bash configure-vm-network.sh
  sudo bash configure-vm-network.sh --static 192.168.56.10/24 --gateway 192.168.56.1 --dns 1.1.1.1
  sudo bash configure-vm-network.sh --verify --strict

After configuring, access the lab at:
  http://<VM_IP>/           (port 80)
  ssh <user>@<VM_IP>        (port 22)
EOF
}

log()  { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  WARNING: %s\n' "$*" >&2; }
die()  { trap - ERR; printf '\nERROR: %s\n' "$*" >&2; exit 1; }

run() {
  if [[ ${DRY_RUN} -eq 1 ]]; then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

require_cmd() {
  local cmd=$1 package=${2:-}
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "Missing command '$cmd'.${package:+ Install it with: apt-get install -y $package}"
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dhcp)                   MODE="dhcp"; shift ;;
    --static)                 [[ $# -ge 2 ]] || die "--static requires a CIDR value"; MODE="static"; STATIC_CIDR=$2; shift 2 ;;
    --gateway)                [[ $# -ge 2 ]] || die "--gateway requires an IP value"; GATEWAY=$2; shift 2 ;;
    --dns)                    [[ $# -ge 2 ]] || die "--dns requires one or more IP values"; DNS_LIST=$2; shift 2 ;;
    --interface|-i)           [[ $# -ge 2 ]] || die "--interface requires an interface name"; IFACE=$2; shift 2 ;;
    --keep-existing-netplan)  KEEP_EXISTING=1; shift ;;
    --disable-cloud-init)     DISABLE_CLOUD_INIT=1; shift ;;
    --no-netplan)             NETPLAN_ENABLE=0; shift ;;
    --no-ufw)                 UFW_ENABLE=0; shift ;;
    --https)                  ALLOW_HTTPS=1; shift ;;
    --allow)                  [[ $# -ge 2 ]] || die "--allow requires a port"; EXTRA_PORTS+=("$2"); shift 2 ;;
    --dry-run)                DRY_RUN=1; shift ;;
    --verify|--verify-only)   VERIFY_ONLY=1; shift ;;
    --strict)                 STRICT=1; shift ;;
    -h|--help)                usage; exit 0 ;;
    *)                        printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf 'Run as root: sudo bash %s\n' "$0" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Logging and error reporting
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE=/tmp/redline-forge-network.log
if ! touch "$LOG_FILE" 2>/dev/null; then
  LOG_FILE=/tmp/redline-forge-network.log
  touch "$LOG_FILE"
fi
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'die "Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

log "Starting ${SCRIPT_NAME}"
info "Log: ${LOG_FILE}"

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------
validate_ipv4() {
  local ip=$1 o
  local -a octets
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$ip"
  for o in "${octets[@]}"; do
    if (( 10#$o < 0 || 10#$o > 255 )); then
      return 1
    fi
  done
  return 0
}

validate_cidr() {
  local cidr=$1 ip prefix
  [[ $cidr == */* ]] || return 1
  ip=${cidr%/*}
  prefix=${cidr#*/}
  [[ $prefix =~ ^[0-9]{1,2}$ ]] || return 1
  if (( 10#$prefix < 1 || 10#$prefix > 32 )); then
    return 1
  fi
  validate_ipv4 "$ip"
}

validate_port() {
  local value=$1 number
  [[ $value =~ ^[0-9]{1,5}(/(tcp|udp))?$ ]] || return 1
  number=${value%%/*}
  (( 10#$number >= 1 && 10#$number <= 65535 ))
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
require_cmd ip iproute2
require_cmd ss iproute2

if [[ ${NETPLAN_ENABLE} -eq 1 && ${VERIFY_ONLY} -eq 0 ]]; then
  require_cmd netplan netplan.io
fi
if [[ ${UFW_ENABLE} -eq 1 && ${VERIFY_ONLY} -eq 0 ]]; then
  require_cmd ufw ufw
fi

if [[ ${MODE} == "static" ]]; then
  [[ -n ${STATIC_CIDR} ]] || die "--static requires a CIDR address, e.g. 192.168.56.10/24"
  validate_cidr "$STATIC_CIDR" || die "Invalid --static value: ${STATIC_CIDR}"
  if [[ -n ${GATEWAY} ]]; then
    validate_ipv4 "$GATEWAY" || die "Invalid --gateway value: ${GATEWAY}"
  fi
fi

if [[ -n ${DNS_LIST} ]]; then
  local_dns=()
  IFS=', ' read -r -a local_dns <<< "$DNS_LIST"
  for d in "${local_dns[@]}"; do
    [[ -n $d ]] || continue
    validate_ipv4 "$d" || die "Invalid DNS server: $d"
    if [[ -z ${DNS_YAML} ]]; then
      DNS_YAML=$d
    else
      DNS_YAML+=", $d"
    fi
  done
fi

if ((${#EXTRA_PORTS[@]} > 0)); then
  for p in "${EXTRA_PORTS[@]}"; do
    [[ -n $p ]] || die "--allow requires a port, e.g. 443/tcp"
    validate_port "$p" || die "Invalid --allow value: $p"
  done
fi

# ---------------------------------------------------------------------------
# Interface detection
# ---------------------------------------------------------------------------
detect_interface() {
  local iface=""
  iface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
  if [[ -z ${iface} ]]; then
    iface=$(ip -br link show up 2>/dev/null \
      | awk '$1 != "lo" && $1 !~ /^(docker|veth|br-|virbr|tun|tap|wg)/ {print $1; exit}')
  fi
  printf '%s\n' "$iface"
}

if [[ -z ${IFACE} ]]; then
  IFACE=$(detect_interface)
fi
[[ -n ${IFACE} ]] || die "Could not detect a network interface; pass --interface IFACE."
ip link show "$IFACE" >/dev/null 2>&1 || die "Interface not found: ${IFACE}"
[[ ${IFACE} != "lo" ]] || die "Refusing to configure the loopback interface."
if [[ ${IFACE} =~ ^(docker|veth|br-|virbr|tun|tap|wg) ]]; then
  warn "Interface '${IFACE}' looks virtual; use --interface if this is not the VM NIC."
fi

if [[ -z ${IPV4} ]]; then
  IPV4=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}')
fi

log "Target interface: ${IFACE}"
if [[ -n ${IPV4} ]]; then
  info "Current IPv4: ${IPV4}"
else
  info "Current IPv4: none"
fi

if [[ ${VERIFY_ONLY} -eq 1 ]]; then
  log "Verification-only mode; no changes will be made."
fi

# ---------------------------------------------------------------------------
# Back up existing netplan configuration
# ---------------------------------------------------------------------------
BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
if [[ ${NETPLAN_ENABLE} -eq 1 && ${VERIFY_ONLY} -eq 0 ]]; then
  if [[ ${DRY_RUN} -eq 1 ]]; then
    info "[dry-run] would back up /etc/netplan to ${BACKUP_DIR}"
  else
    mkdir -p "${BACKUP_DIR}/netplan"
    if compgen -G "/etc/netplan/*.yaml" >/dev/null 2>&1; then
      cp -a /etc/netplan/. "${BACKUP_DIR}/netplan/"
    fi
    log "Backed up netplan configuration to ${BACKUP_DIR}"
  fi
fi

# ---------------------------------------------------------------------------
# Netplan configuration
# ---------------------------------------------------------------------------
if [[ ${KEEP_EXISTING} -eq 1 ]]; then
  NETPLAN_FILE=/etc/netplan/99-lab.yaml
else
  NETPLAN_FILE=/etc/netplan/01-lab.yaml
fi

generate_netplan() {
  local out=$1
  {
    echo "# Managed by configure-vm-network.sh - Redline Forge lab VM"
    echo "network:"
    echo "  version: 2"
    echo "  ethernets:"
    echo "    ${IFACE}:"
    if [[ ${MODE} == "dhcp" ]]; then
      echo "      dhcp4: true"
    else
      echo "      dhcp4: false"
    fi
    echo "      dhcp6: false"
    echo "      optional: true"
    if [[ ${MODE} == "static" ]]; then
      echo "      addresses:"
      echo "        - ${STATIC_CIDR}"
      if [[ -n ${GATEWAY} ]]; then
        echo "      routes:"
        echo "        - to: default"
        echo "          via: ${GATEWAY}"
      fi
    fi
    if [[ -n ${DNS_YAML} ]]; then
      echo "      nameservers:"
      echo "        addresses: [${DNS_YAML}]"
      if [[ ${MODE} == "dhcp" ]]; then
        echo "      dhcp4-overrides:"
        echo "        use-dns: false"
      fi
    fi
  } > "$out"
}

restore_netplan() {
  if [[ ${DRY_RUN} -eq 1 ]]; then
    return 0
  fi
  rm -f "$NETPLAN_FILE"
  if [[ -d "${BACKUP_DIR}/netplan" ]]; then
    cp -a "${BACKUP_DIR}/netplan/." /etc/netplan/ 2>/dev/null || true
  fi
  netplan apply >/dev/null 2>&1 || true
}

if [[ ${NETPLAN_ENABLE} -eq 1 && ${VERIFY_ONLY} -eq 0 ]]; then
  log "Configuring netplan (${MODE})"

  if [[ ${DISABLE_CLOUD_INIT} -eq 1 ]]; then
    if command -v cloud-init >/dev/null 2>&1 || [[ -d /etc/cloud ]]; then
      run install -d -m 755 /etc/cloud/cloud.cfg.d
      if [[ ${DRY_RUN} -eq 1 ]]; then
        info "[dry-run] would write /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
      else
        cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
# Managed by configure-vm-network.sh
network: {config: disabled}
EOF
        log "Disabled cloud-init network configuration"
      fi
    else
      info "cloud-init is not installed; nothing to disable."
    fi
  fi

  if [[ ${KEEP_EXISTING} -eq 0 ]]; then
    shopt -s nullglob
    for f in /etc/netplan/*.yaml; do
      [[ "$f" == "$NETPLAN_FILE" ]] && continue
      if [[ ${DRY_RUN} -eq 1 ]]; then
        info "[dry-run] would archive ${f}"
      else
        mv "$f" "${BACKUP_DIR}/netplan/"
      fi
    done
    shopt -u nullglob
  fi

  if [[ ${DRY_RUN} -eq 1 ]]; then
    info "[dry-run] would ensure /etc/netplan exists"
  else
    install -d -m 755 /etc/netplan
  fi

  tmp=$(mktemp)
  generate_netplan "$tmp"

  if [[ ${DRY_RUN} -eq 1 ]]; then
    info "[dry-run] would install the following as ${NETPLAN_FILE}:"
    sed 's/^/    /' "$tmp"
    rm -f "$tmp"
  else
    install -m 600 -o root -g root "$tmp" "$NETPLAN_FILE"
    rm -f "$tmp"

    warn "Applying netplan may briefly interrupt network access."
    log "Validating netplan configuration"
    if ! netplan generate; then
      warn "netplan generate failed; restoring the previous configuration"
      restore_netplan
      die "Invalid netplan configuration; previous configuration restored."
    fi

    log "Applying netplan configuration"
    if ! netplan apply; then
      warn "netplan apply failed; restoring the previous configuration"
      restore_netplan
      die "netplan apply failed; previous configuration restored."
    fi

    log "Waiting for an IPv4 address on ${IFACE}"
    for _ in $(seq 1 30); do
      IPV4=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}')
      [[ -n ${IPV4} ]] && break
      sleep 1
    done

    if [[ -z ${IPV4} ]]; then
      warn "No IPv4 address on ${IFACE} after 30 seconds."
      warn "Check the DHCP server, or verify the static address and gateway."
    else
      info "Address: ${IPV4}"
    fi

    if ip -4 route show default | grep -q .; then
      info "Default route: $(ip -4 route show default | head -n1)"
    else
      warn "No IPv4 default route is present."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
if [[ ${UFW_ENABLE} -eq 1 && ${VERIFY_ONLY} -eq 0 ]]; then
  log "Configuring UFW"

  run ufw --force default deny incoming
  run ufw --force default allow outgoing
  run ufw allow "${SSH_PORT}/tcp" comment 'SSH admin'
  run ufw allow "${HTTP_PORT}/tcp" comment 'ForgeTrack HTTP'

  if [[ ${ALLOW_HTTPS} -eq 1 ]]; then
    run ufw allow 443/tcp comment 'HTTPS'
  fi

  if ((${#EXTRA_PORTS[@]} > 0)); then
    for p in "${EXTRA_PORTS[@]}"; do
      run ufw allow "$p" comment 'Lab extra port'
    done
  fi

  run ufw --force enable
fi

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
listener_addresses() {
  ss -H -ltn 2>/dev/null | awk '{print $4}' || true
}

is_listening() {
  local port=$1
  listener_addresses | grep -Eq "[:.]${port}$"
}

is_public_bind() {
  local port=$1
  listener_addresses | grep -Eq "^(0\.0\.0\.0|\[::\]|\*|:::)[:.]?${port}$"
}

verify_state() {
  log "Verifying listeners and firewall"

  local port code
  for port in "$SSH_PORT" "$HTTP_PORT"; do
    if is_listening "$port"; then
      info "TCP :${port} is listening"
    else
      warn "TCP :${port} is NOT listening"
      FAILURES=$((FAILURES + 1))
    fi
  done

  if [[ ${ALLOW_HTTPS} -eq 1 ]]; then
    if is_listening 443; then
      info "TCP :443 is listening"
    else
      warn "TCP :443 is NOT listening"
      FAILURES=$((FAILURES + 1))
    fi
  fi

  if is_public_bind 8080; then
    warn "Gunicorn :8080 is publicly bound; it should be 127.0.0.1:8080."
    FAILURES=$((FAILURES + 1))
  else
    info "Gunicorn :8080 is not publicly bound"
  fi

  if is_public_bind 5432; then
    warn "PostgreSQL :5432 is publicly bound; it should be 127.0.0.1:5432."
    FAILURES=$((FAILURES + 1))
  else
    info "PostgreSQL :5432 is not publicly bound"
  fi

  if command -v ufw >/dev/null 2>&1; then
    echo
    ufw status verbose || true
    if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
      warn "UFW is not active."
      FAILURES=$((FAILURES + 1))
    fi
  fi

  if command -v curl >/dev/null 2>&1; then
    code=$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' \
      --max-time 5 http://127.0.0.1/ 2>/dev/null || true)
    if [[ ${code} == "200" ]]; then
      info "http://127.0.0.1/ -> 200"
    else
      warn "http://127.0.0.1/ -> ${code:-no response} (app may not be installed or running)"
    fi
  fi

  if systemctl is-active --quiet docker 2>/dev/null; then
    warn "Docker is running. Docker-published ports can bypass UFW; do not use Docker on the delivered VM."
  fi
}

verify_state

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ -z ${IPV4} ]]; then
  IPV4=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}')
fi

log "Summary"
info "Interface:  ${IFACE}"
info "Mode:       ${MODE}"
info "IPv4:       ${IPV4:-none}"
info "HTTP:       http://<VM_IP>/ (port ${HTTP_PORT})"
info "SSH:        ssh <user>@<VM_IP> (port ${SSH_PORT})"
info "Log:        ${LOG_FILE}"

if [[ ${DRY_RUN} -eq 0 && ${VERIFY_ONLY} -eq 0 ]]; then
  if [[ -n ${BACKUP_DIR} && -d ${BACKUP_DIR} ]]; then
    info "Backup:     ${BACKUP_DIR}"
  fi
fi

cat <<'EOF'

Host-side access (run on the host, not inside the VM):
  VirtualBox NAT forwarding (VM powered off):
    VBoxManage modifyvm "<VM_NAME>" --natpf1 "ssh,tcp,,2222,,22"
    VBoxManage modifyvm "<VM_NAME>" --natpf1 "http,tcp,,8080,,80"
    Then open http://localhost:8080

  Bridged / host-only / TryHackMe:
    Use the VM address directly: http://<VM_IP>/
EOF

if [[ ${STRICT} -eq 1 && ${FAILURES} -gt 0 ]]; then
  die "Verification found ${FAILURES} issue(s)."
fi

log "Done."