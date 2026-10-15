#!/usr/bin/env bash
set -euo pipefail

T3_HOST="${T3_HOST:-0.0.0.0}"
T3_PORT="${T3_PORT:-3773}"
T3CODE_HOME="${T3CODE_HOME:-/root/.t3code}"
OPENCODE_HOST="${OPENCODE_HOST:-0.0.0.0}"
OPENCODE_PORT="${OPENCODE_PORT:-4096}"
ENABLE_OPENCODE_SERVER="${ENABLE_OPENCODE_SERVER:-1}"
AUTO_PAIR="${AUTO_PAIR:-1}"
PAIR_TTL="${PAIR_TTL:-3650d}"       # T3 has no "never"; 10 years is the practical
PAIR_LABEL="${PAIR_LABEL:-boot}"    # equivalent, and it is overridable.
MISE_AUTO_INSTALL="${MISE_AUTO_INSTALL:-1}"
MISE_INSTALL_TIMEOUT="${MISE_INSTALL_TIMEOUT:-900}"
PROJECTS_DIR="${PROJECTS_DIR:-/root/Projects}"

# The one host path the container may touch. Everything else is container-local.
export T3CODE_HOME PROJECTS_DIR
mkdir -p "$PROJECTS_DIR" "$T3CODE_HOME" "${GOPATH:-/root/go}" "${CARGO_HOME:-/usr/local/cargo}"

# --- scratch hygiene ----------------------------------------------------------
# /tmp is expected to be a bind mount to a host scratch dir (compose.yaml) so
# that scratch never lands in UnRaid's Docker storage. Wipe it on start so it
# cannot accumulate. Guarded: if the bind is missing or points somewhere
# unexpected we do nothing, rather than risk deleting real data.
SCRATCH="${SCRATCH_DIR:-/tmp}"

# Returns 0 if the scratch dir is safe to wipe; otherwise prints the reason.
scratch_refusal_reason() {
  case "$SCRATCH" in
    /)
      echo "refusing to wipe the container root"
      return 1
      ;;
    /root/Projects | /root/Projects/*)
      echo "refusing to wipe the projects mount"
      return 1
      ;;
    /root)
      # Projects now live under HOME, so a stray SCRATCH_DIR=/root must never
      # walk into them (or into ~/.config, which holds credentials).
      echo "refusing to wipe the home directory"
      return 1
      ;;
  esac
  mountpoint -q "$SCRATCH" || {
    echo "${SCRATCH} is not a mountpoint (bind mount missing?)"
    return 1
  }
  return 0
}

wipe_scratch() {
  find "$SCRATCH" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
}

if [ "${SCRATCH_WIPE_ON_START:-1}" = "1" ]; then
  if reason="$(scratch_refusal_reason)"; then
    wipe_scratch
    echo "[entrypoint] cleared scratch at ${SCRATCH}"
  else
    echo "[entrypoint] scratch wipe skipped: ${reason}"
  fi
fi

# If the caller passed a command, run it instead of the default services.
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

# --- seed the "where am I" rules into every agent's config --------------------
# Seeded only when missing, so the user's own edits are never clobbered.
seed_rules() {
  local src=/etc/codecontainer/AGENTS.md
  [ -f "$src" ] || return 0
  local dst
  for dst in \
    "/root/.config/opencode/AGENTS.md" \
    "/root/.codex/AGENTS.md" \
    "/root/.claude/CLAUDE.md"
  do
    mkdir -p "$(dirname "$dst")"
    if [ ! -f "$dst" ]; then
      cp "$src" "$dst"
      echo "[entrypoint] seeded agent rules -> $dst"
    fi
  done
}
seed_rules

# --- pairing link -------------------------------------------------------------
# T3's own startup URL contains the CONTAINER's address, which nothing outside
# the host can reach, and its token dies 5 minutes after boot.
#
# Pairings persist in the state volume, so a device pairs ONCE and stays paired
# across restarts and rebuilds. Minting a link on every boot would churn
# credentials and - worse - make it look like re-pairing is needed. So a link is
# only minted when nothing is paired yet.
print_pairing() {
  [ "$AUTO_PAIR" = "1" ] || return 0

  if [ -z "${PUBLIC_HOST:-}" ]; then
    echo "[entrypoint] PUBLIC_HOST not set - skipping pairing link"
    return 0
  fi

  # wait for the server to answer before asking it anything
  local i
  for i in $(seq 1 90); do
    (exec 3<>"/dev/tcp/127.0.0.1/${T3_PORT}") 2>/dev/null && break
    sleep 1
  done

  local sessions
  sessions="$(t3 auth session list --json 2>/dev/null |
    python3 -c 'import sys, json
try:
    print(len(json.load(sys.stdin)))
except Exception:
    print(0)' 2>/dev/null || echo 0)"

  if [ "${sessions:-0}" -gt 0 ]; then
    echo "[entrypoint] ${sessions} device(s) already paired - no new link needed"
    echo "[entrypoint] to add another device:  docker compose exec code pair"
    return 0
  fi

  # Nothing paired yet. Drop UNUSED links minted by earlier boots so only one is
  # ever valid. Consumed tokens are not "active", so paired devices are never
  # touched.
  local id
  for id in $(t3 auth pairing list 2>/dev/null | grep -F "(${PAIR_LABEL})" | awk '{print $1}'); do
    t3 auth pairing revoke "$id" >/dev/null 2>&1 && echo "[entrypoint] revoked stale pairing link ${id}"
  done

  local out url
  if ! out="$(t3 auth pairing create \
      --base-url "http://${PUBLIC_HOST}:${T3_PORT}" \
      --ttl "${PAIR_TTL}" --label "${PAIR_LABEL}" 2>&1)"; then
    echo "[entrypoint] could not mint a pairing link: ${out}"
    return 0
  fi
  url="$(printf '%s\n' "${out}" | grep -oE 'https?://[^[:space:]]+/pair#token=[A-Za-z0-9]+' | head -n1)"

  printf '\n'
  printf '  ============= PAIRING LINK  (first device only) =============\n'
  printf '  Ignore the "Pairing URL" T3 printed above: it contains the\n'
  printf '  container internal address, which nothing can reach, and its\n'
  printf '  token dies after 5 minutes.\n'
  printf '\n'
  printf '  Pairings persist in the state volume, so this is ONE-TIME per\n'
  printf '  device, not per boot. Add more later with:\n'
  printf '      docker compose exec code pair\n'
  printf '\n'
  printf '    %s\n\n' "${url:-${out}}"
  if [ -n "${url}" ] && [ "${PAIR_QR:-1}" = "1" ] && command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "${url}"
    printf '\n'
  fi
  printf '  expires: %s   label: %s   (revoke: t3 auth pairing list|revoke <id>)\n' "${PAIR_TTL}" "${PAIR_LABEL}"
  printf '  ============================================================\n\n'
}

# --- per-project runtimes (mise) ----------------------------------------------
# Non-fatal and time-boxed on purpose. If the network is down the container
# still starts with node, Python and the C toolchain from the image - it just
# won't have rust/go until mise can fetch them. Idempotent: already-installed
# tools are skipped in well under a second.
prep_mise() {
  command -v mise >/dev/null 2>&1 || return 0
  [ "${MISE_AUTO_INSTALL}" = "1" ] || return 0

  if timeout "${MISE_INSTALL_TIMEOUT}" mise install >/tmp/mise-install.log 2>&1; then
    echo "[entrypoint] mise ready: $(mise ls 2>/dev/null | wc -l) tool(s) installed"
  else
    echo "[entrypoint] mise install failed or timed out - image toolchains still available"
    tail -3 /tmp/mise-install.log 2>/dev/null | sed 's/^/[entrypoint]   /'
  fi
}

banner() {
  printf '\n'
  printf '  CodeContainer  |  T3 Code + OpenCode  |  Ubuntu 26.04\n'
  printf '  ---------------------------------------------------------------\n'
  printf '  T3 Code UI     ->  http://<host>:%s\n' "${T3_PORT}"
  printf '  OpenCode API   ->  http://<host>:%s\n' "${OPENCODE_PORT}"
  printf '  App previews   ->  http://<host>:%s-%s\n' "${PORT_BASE:-30000}" "${PORT_END:-30099}"
  printf '  ---------------------------------------------------------------\n'
  printf '  projects       ->  %s   (only host path mounted)\n' "$PROJECTS_DIR"
  printf '  scratch        ->  %s\n' "${SCRATCH}"
  printf '  shell          ->  docker exec -it <container> bash\n'
  printf '  pair a device  ->  docker compose exec code pair\n'
  printf '  first run      ->  opencode auth login\n'
  printf '  agent rules    ->  /root/.config/opencode/AGENTS.md\n'
  printf '  T3 pairing token below is a password. Do not expose this port.\n\n'
}

# --- OpenCode (managed by mise, never baked into the image) --------------------
# Deliberately absent from the image so there is exactly ONE copy and nothing
# can go stale behind the bind mount. mise owns the version via
# /etc/mise/config.toml, so updating it is `mise up` - no redeploy.
#
# This BLOCKS on purpose before T3 starts. T3 probes for the opencode provider
# when it boots, and its periodic health checks do not re-scan, so an install
# that finished afterwards would go unnoticed until a manual refresh.
ensure_opencode() {
  if command -v opencode >/dev/null 2>&1; then
    echo "[entrypoint] opencode present: $(opencode --version 2>&1 | head -1)"
    return 0
  fi

  echo "[entrypoint] installing opencode via mise (first boot only)..."
  if timeout "${OPENCODE_INSTALL_TIMEOUT:-300}" \
    mise install opencode >/tmp/opencode-install.log 2>&1; then
    hash -r 2>/dev/null || true
    echo "[entrypoint] opencode ready: $(opencode --version 2>&1 | head -1)"
  else
    echo "[entrypoint] !! opencode install failed - T3 will show it as unavailable"
    tail -3 /tmp/opencode-install.log 2>/dev/null | sed 's/^/[entrypoint]   /'
  fi
  return 0
}

ensure_opencode

# --- misplaced-clone guard ----------------------------------------------------
# Projects live at $PROJECTS_DIR, which is mounted. Everything else under HOME
# is the container's ephemeral layer and is destroyed on rebuild, so a repo
# cloned into the wrong place vanishes later without explanation. Say so loudly.
warn_stray_repos() {
  local stray
  stray="$(find "$HOME" -maxdepth 2 -name .git -not -path "${PROJECTS_DIR}/*" 2>/dev/null | head -5)"
  [ -n "$stray" ] || return 0
  echo "[entrypoint] !! git repo(s) OUTSIDE ${PROJECTS_DIR} - these are lost on rebuild:"
  printf '%s\n' "$stray" | sed 's/^/[entrypoint]      /'
}
warn_stray_repos

# --- OpenCode HTTP API --------------------------------------------------------
# T3 Code drives the `opencode` CLI as a provider; this server is a bonus for
# `opencode --attach` and scripting. opencode defaults to a random port on
# 127.0.0.1, so both flags below are required.
OPENCODE_PID=""
if [ "$ENABLE_OPENCODE_SERVER" = "1" ] && command -v opencode >/dev/null 2>&1; then
  echo "[entrypoint] opencode serve on ${OPENCODE_HOST}:${OPENCODE_PORT}"
  opencode serve --hostname "${OPENCODE_HOST}" --port "${OPENCODE_PORT}" &
  OPENCODE_PID=$!
fi

cleanup() {
  if [ -n "${OPENCODE_PID}" ] && kill -0 "${OPENCODE_PID}" 2>/dev/null; then
    kill "${OPENCODE_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

banner

# --- T3 Code control surface (foreground / PID 1) ----------------------------
if command -v t3 >/dev/null 2>&1; then
  set -- t3 serve --host "${T3_HOST}" --port "${T3_PORT}" --no-browser --base-dir "${T3CODE_HOME}"
else
  set -- npx -y t3@nightly serve --host "${T3_HOST}" --port "${T3_PORT}" --no-browser --base-dir "${T3CODE_HOME}"
fi
echo "[entrypoint] exec: $*"

# Runs in the background: the container must come up whether or not the network
# is reachable for mise, or T3 is ready to mint a token yet.
print_pairing &
prep_mise &

exec "$@"
