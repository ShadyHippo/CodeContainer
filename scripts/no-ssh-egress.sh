#!/usr/bin/env bash
# Block outbound SSH from the CodeContainer's Docker network.
#
# Docker/Compose cannot express egress filtering, so this has to live on the
# host. Two chains are needed:
#
#   DOCKER-USER  (FORWARD) -> container to any other machine on the LAN
#   INPUT                  -> container to the UnRaid host itself
#
# Usage (as root):
#     ./scripts/no-ssh-egress.sh apply
#     ./scripts/no-ssh-egress.sh status
#     ./scripts/no-ssh-egress.sh remove
#
# To survive an UnRaid reboot, add the apply line to /boot/config/go.
set -euo pipefail

PROJECT="${PROJECT:-codecontainer}"
NETWORK="${NETWORK:-${PROJECT}_default}"
PORTS=(22 2222)
STATEFILE="${STATEFILE:-/run/codecontainer-egress.src}"

die() { echo "no-ssh-egress: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0 ${1:-apply})"
command -v iptables >/dev/null 2>&1 || die "iptables not found"
command -v docker >/dev/null 2>&1 || die "docker not found"

discover_subnet() {
  docker network inspect "$NETWORK" \
    --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null |
    grep -v '^$' | head -n1
}

resolve_subnet() {
  if [ -n "${SUBNET:-}" ]; then echo "$SUBNET"; return 0; fi
  local s
  s="$(discover_subnet || true)"
  if [ -n "$s" ]; then echo "$s"; return 0; fi
  if [ -r "$STATEFILE" ]; then cat "$STATEFILE"; return 0; fi
  die "could not determine the subnet for '$NETWORK'. Is the stack up? (or pass SUBNET=...)"
}

tx() { # chain action
  local chain="$1" action="$2" src="$3" port
  iptables -L "$chain" -n >/dev/null 2>&1 || die "chain '$chain' does not exist"
  for port in "${PORTS[@]}"; do
    case "$action" in
      apply)
        if iptables -C "$chain" -s "$src" -p tcp --dport "$port" -j REJECT 2>/dev/null; then
          echo "  [=] $chain already blocks $src -> tcp/$port"
        else
          iptables -I "$chain" 1 -s "$src" -p tcp --dport "$port" -j REJECT
          echo "  [+] $chain blocks $src -> tcp/$port"
        fi
        ;;
      remove)
        while iptables -C "$chain" -s "$src" -p tcp --dport "$port" -j REJECT 2>/dev/null; do
          iptables -D "$chain" -s "$src" -p tcp --dport "$port" -j REJECT
          echo "  [-] $chain unblocked $src -> tcp/$port"
        done
        ;;
      status)
        if iptables -C "$chain" -s "$src" -p tcp --dport "$port" -j REJECT 2>/dev/null; then
          echo "  [x] $chain BLOCKS    $src -> tcp/$port"
        else
          echo "  [ ] $chain allows    $src -> tcp/$port"
        fi
        ;;
    esac
  done
}

SRC="$(resolve_subnet)"
echo "no-ssh-egress: network=$NETWORK subnet=$SRC ports=${PORTS[*]}"

case "${1:-status}" in
  apply)
    tx DOCKER-USER apply "$SRC"
    tx INPUT apply "$SRC"
    echo "$SRC" >"$STATEFILE"
    echo "saved subnet to $STATEFILE"
    echo "NOTE: re-run 'apply' after a 'docker compose down/up' (the subnet may change)."
    ;;
  remove)
    tx DOCKER-USER remove "$SRC"
    tx INPUT remove "$SRC"
    rm -f "$STATEFILE"
    ;;
  status)
    tx DOCKER-USER status "$SRC"
    tx INPUT status "$SRC"
    ;;
  *)
    die "usage: $0 {apply|remove|status}"
    ;;
esac
