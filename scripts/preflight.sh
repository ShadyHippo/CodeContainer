#!/usr/bin/env bash
# Preflight checks before deploying CodeContainer on the host.
#
#   ./scripts/preflight.sh
#
# Every check maps to a failure mode that is annoying to diagnose after the
# fact, on a box that also holds things you care about.
set -uo pipefail

cd "$(dirname "$0")/.." 2>/dev/null || true

fails=0
warns=0
ok() { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() {
  printf '  \033[33mwarn\033[0m  %s\n' "$*"
  warns=$((warns + 1))
}
bad() {
  printf '  \033[31mFAIL\033[0m  %s\n' "$*"
  fails=$((fails + 1))
}

echo "CodeContainer preflight"
echo

# --- tooling -----------------------------------------------------------------
command -v docker >/dev/null 2>&1 && ok "docker present" || bad "docker not found"
if docker compose version >/dev/null 2>&1; then
  ok "docker compose v2 present"
else
  bad "docker compose v2 not found ('docker-compose' v1 will not work)"
fi

# --- config ------------------------------------------------------------------
HAVE_COMPOSE=0
if [ -f compose.yaml ]; then
  ok "compose.yaml present"
  docker compose config >/dev/null 2>&1 && HAVE_COMPOSE=1
else
  bad "compose.yaml missing -- run: make init  (or: cp compose.example.yaml compose.yaml)"
fi

# --- host bind mounts --------------------------------------------------------
# /workspace holds your projects and /tmp holds build scratch. On UnRaid "/" is
# a RAM disk, and Docker will CREATE a missing bind source there -- so a 40GB
# build could silently eat RAM. Those two are hard failures. Other binds (like
# ./secrets) are tiny and only need to exist.
ROOTFS="$(df -P / 2>/dev/null | awk 'NR==2{print $1}')"

check_mount() { # src target strict
  local src="$1" tgt="$2" strict="$3" fs avail
  if [ ! -e "$src" ]; then
    if [ "$strict" = "1" ]; then
      bad "$src  ($tgt)  -- does not exist"
      printf '        Docker would create it on the ROOT fs%s -- UnRaid root is a RAM disk\n' \
        "${ROOTFS:+ ($ROOTFS)}"
    else
      warn "$src  ($tgt)  -- does not exist"
    fi
    return
  fi
  fs="$(df -P "$src" 2>/dev/null | awk 'NR==2{print $1}')"
  avail="$(df -Ph "$src" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ "$strict" = "1" ] && [ -n "$ROOTFS" ] && [ "$fs" = "$ROOTFS" ]; then
    bad "$src  ($tgt)  is on the ROOT filesystem ($fs)"
    printf '        UnRaid root is a RAM disk -- move it onto a pool\n'
  else
    ok "$src  ($tgt)  fs=$fs free=$avail"
  fi
}

if [ "$HAVE_COMPOSE" = "1" ]; then
  while IFS='|' read -r src tgt; do
    [ -n "$tgt" ] || continue
    case "$src" in /*) ;; *) continue ;; esac # skip named volumes
    case "$tgt" in
      /tmp | /workspace) check_mount "$src" "$tgt" 1 ;;
      *) check_mount "$src" "$tgt" 0 ;;
    esac
  done < <(docker compose config 2>/dev/null | awk '/source:/{s=$2} /target:/{print s"|"$2}')
fi

# --- ports -------------------------------------------------------------------
listeners() {
  if command -v ss >/dev/null 2>&1; then
    ss -Hltn 2>/dev/null | awk '{print $4}'
  else
    netstat -ltn 2>/dev/null | awk 'NR>2{print $4}'
  fi
}

BUSY="$(listeners)"
for port in 3773 4096 30000; do
  if printf '%s\n' "$BUSY" | grep -qE "[:.]${port}\$"; then
    bad "tcp/$port is already in use on this host"
  else
    ok "tcp/$port free"
  fi
done

# --- bind address ------------------------------------------------------------
BINDIP=""
[ "$HAVE_COMPOSE" = "1" ] &&
  BINDIP="$(docker compose config 2>/dev/null | awk '/host_ip:/{print $2; exit}')"

if [ -z "$BINDIP" ]; then
  warn "could not read the bind IP from compose.yaml"
elif [ "$BINDIP" = "127.0.0.1" ]; then
  warn "bind IP is 127.0.0.1 -- host-only, NOT reachable over Tailscale"
elif command -v ip >/dev/null 2>&1 && ip -o addr 2>/dev/null | grep -qw "$BINDIP"; then
  ok "bind IP $BINDIP is present on this host"
else
  bad "bind IP $BINDIP is NOT on any interface -- 'docker compose up' will fail"
  printf '        (Tailscale up? find it with: tailscale ip -4)\n'
fi

# --- docker storage headroom -------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
  if [ -n "$root" ]; then
    avail="$(df -Ph "$root" 2>/dev/null | awk 'NR==2{print $4}')"
    ok "docker root: $root (free=$avail)"
  fi
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) FAILED -- fix these before deploying."
  exit 1
fi
echo "preflight passed ($warns warning(s))."
