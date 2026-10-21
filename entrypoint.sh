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
# Demo links. The public T3 hostname usually proxies only the app port, so the
# published preview range gets its own host - the direct LAN/mDNS name.
PREVIEW_HOST="${PREVIEW_HOST:-un.raid}"
# Inbound SSH for VS Code Remote-SSH / T3's "SSH environment". Key-only: sshd
# only starts when a public key is provided, so a container with no key is a
# container with no SSH listener.
ENABLE_SSH="${ENABLE_SSH:-1}"
SSH_STATE_DIR="${SSH_STATE_DIR:-/root/.config/ssh}"
SSH_AUTHORIZED_KEYS_FILE="${SSH_AUTHORIZED_KEYS_FILE:-/secrets/authorized_keys}"

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
generate_tools_block() {
  {
    echo "Image tools: Node 24, TypeScript, Python 3.14, Ruby, PHP 8.5, C/C++, ffmpeg, PostgreSQL 18, MariaDB 11, Redis 8, SQLite, Playwright."
    echo
    echo "mise-managed runtimes (mise ls):"
    mise ls 2>/dev/null || echo "(mise not ready yet)"
    echo
    local oc npmout
    oc="$(opencode --version 2>/dev/null | head -1)"
    echo "OpenCode: ${oc:-not installed} (npm-global in ~/.local; T3 Code owns updates)"
    echo
    npmout="$(npm ls -g --depth=0 2>/dev/null || true)"
    echo "Global npm packages (npm ls -g --depth=0):"
    echo "${npmout:-(none)}"
    echo
    echo "HandBrake: not preinstalled (install per durable rules if needed)."
  } > /tmp/installed-tools-block.txt
}

update_tools_block() {
  local file="$1"
  [ -f "$file" ] || return 0
  python3 - "$file" /tmp/installed-tools-block.txt <<'PY'
import sys, re
path, blockpath = sys.argv[1], sys.argv[2]
text = open(path).read()
block = open(blockpath).read().rstrip("\n")
pattern = re.compile(r"<!-- BEGIN:installed-tools -->.*?<!-- END:installed-tools -->", re.S)
new = "<!-- BEGIN:installed-tools -->\n" + block + "\n<!-- END:installed-tools -->"
if pattern.search(text):
    text = pattern.sub(new, text, count=1)
else:
    text = text.rstrip() + "\n\n" + new + "\n"
open(path, "w").write(text)
PY
}

prep_mise() {
  command -v mise >/dev/null 2>&1 || return 0
  [ "${MISE_AUTO_INSTALL}" = "1" ] || return 0

  if timeout "${MISE_INSTALL_TIMEOUT}" mise install >/tmp/mise-install.log 2>&1; then
    echo "[entrypoint] mise ready: $(mise ls 2>/dev/null | wc -l) tool(s) installed"
  else
    echo "[entrypoint] mise install failed or timed out - image toolchains still available"
    tail -3 /tmp/mise-install.log 2>/dev/null | sed 's/^/[entrypoint]   /'
  fi
  # Refresh the auto-generated installed-tooling block in agent rules (best effort).
  generate_tools_block
  for dst in \
    "/root/.config/opencode/AGENTS.md" \
    "/root/.codex/AGENTS.md" \
    "/root/.claude/CLAUDE.md"
  do
    update_tools_block "$dst"
  done
}

banner() {
  printf '\n'
  printf '  CodeContainer  |  T3 Code + OpenCode  |  Ubuntu 26.04\n'
  printf '  ---------------------------------------------------------------\n'
  printf '  T3 Code UI     ->  http://%s:%s\n' "${PUBLIC_HOST:-<host>}" "${T3_PORT}"
  printf '  OpenCode API   ->  http://%s:%s\n' "${PREVIEW_HOST}" "${OPENCODE_PORT}"
  if [ -n "${PORT_BASE:-}" ]; then
    printf '  App previews   ->  http://%s:%s-%s\n' "${PREVIEW_HOST}" "${PORT_BASE}" "${PORT_END:-30099}"
  else
    printf '  App previews   ->  http://%s:<port>\n' "${PREVIEW_HOST}"
  fi
  printf '  ---------------------------------------------------------------\n'
  printf '  projects       ->  %s   (only host path mounted)\n' "$PROJECTS_DIR"
  printf '  scratch        ->  %s\n' "${SCRATCH}"
  printf '  shell          ->  docker exec -it <container> bash\n'
  printf '  pair a device  ->  docker compose exec code pair\n'
  printf '  first run      ->  opencode auth login\n'
  printf '  agent rules    ->  /root/.config/opencode/AGENTS.md\n'
  printf '  T3 pairing token below is a password. Do not expose this port.\n\n'
}

# --- OpenCode (npm-global in ~/.local, updated by T3 Code) --------------------
# T3 Code only offers a working "Update now" for install kinds it can drive
# itself (npm-global, brew, native). A mise-managed copy is classified as
# manual: T3 shows "Update available" with no button at all, forever, because
# `mise install` on boot never bumps a `latest` pin. So OpenCode lives where T3
# expects a provider CLI to live - npm-global under ~/.local, a bind mount that
# is first on PATH and survives rebuilds.
#
# This BLOCKS on purpose before T3 starts. T3 probes for the opencode provider
# when it boots, and its periodic health checks do not re-scan, so an install
# that finished afterwards would go unnoticed until a manual refresh.
#
# OPENCODE_CHANNEL picks the first-boot version (default: latest). After that,
# T3 owns updates - this only fills an empty install.
OPENCODE_PREFIX="${OPENCODE_PREFIX:-/root/.local}"
OPENCODE_PACKAGE="${OPENCODE_PACKAGE:-@opencode/cli}"

# Older images managed OpenCode with mise. /mise is a bind mount, so the install
# and its shim outlive an image rebuild and would shadow the npm copy on PATH.
# Remove them here rather than relying on the rebuild, and drop a stale entry
# from the system config so the next `mise install` cannot resurrect it.
migrate_opencode_from_mise() {
  local config=/etc/mise/config.toml
  if [ -e /mise/shims/opencode ] || [ -d /mise/installs/opencode ]; then
    if command -v mise >/dev/null 2>&1; then
      mise uninstall opencode >/dev/null 2>&1 || true
    fi
    # /mise is a bind mount, so a failed or partial uninstall would leave a
    # copy that shadows the npm one on PATH. Remove the tool's tree outright.
    rm -rf /mise/installs/opencode
    rm -f /mise/shims/opencode
    echo "[entrypoint] moved opencode out of mise (T3 Code owns updates now)"
  fi
  if [ -f "$config" ] && grep -qE '^[[:space:]]*opencode[[:space:]]*=' "$config"; then
    sed -i -E '/^[[:space:]]*opencode[[:space:]]*=/d' "$config"
  fi
}

ensure_opencode() {
  migrate_opencode_from_mise

  if command -v opencode >/dev/null 2>&1; then
    echo "[entrypoint] opencode present: $(opencode --version 2>&1 | head -1)"
    return 0
  fi

  echo "[entrypoint] installing opencode via npm into ${OPENCODE_PREFIX} (first boot only)..."
  mkdir -p "${OPENCODE_PREFIX}/lib"
  local log=/tmp/opencode-install.log
  local spec="${OPENCODE_PACKAGE}@${OPENCODE_CHANNEL:-latest}"
  if ! timeout "${OPENCODE_INSTALL_TIMEOUT:-300}" \
    npm install -g --prefix "${OPENCODE_PREFIX}" \
      --allow-scripts="${OPENCODE_PACKAGE}" "$spec" >"$log" 2>&1; then
    # Older npm builds reject --allow-scripts; they run lifecycle scripts anyway.
    echo "[entrypoint] npm rejected --allow-scripts, retrying without it"
    if ! timeout "${OPENCODE_INSTALL_TIMEOUT:-300}" \
      npm install -g --prefix "${OPENCODE_PREFIX}" "$spec" >>"$log" 2>&1; then
      echo "[entrypoint] !! opencode install failed - T3 will show it as unavailable"
      tail -3 "$log" 2>/dev/null | sed 's/^/[entrypoint]   /'
      return 0
    fi
  fi
  hash -r 2>/dev/null || true
  echo "[entrypoint] opencode ready: $(opencode --version 2>&1 | head -1)"
  return 0
}

ensure_opencode

# --- misplaced-clone guard ----------------------------------------------------
# Projects live at $PROJECTS_DIR, which is mounted. Code cloned anywhere
# else under HOME is in the wrong place: it is not part of the projects share
# and may be lost on rebuild (only state/cache dirs are bind-mounted). Say so
# loudly.
warn_stray_repos() {
  local stray
  stray="$(find "$HOME" -maxdepth 2 -name .git -not -path "${PROJECTS_DIR}/*" 2>/dev/null | head -5)"
  [ -n "$stray" ] || return 0
  echo "[entrypoint] !! git repo(s) OUTSIDE ${PROJECTS_DIR} - keep code in the projects share:"
  printf '%s\n' "$stray" | sed 's/^/[entrypoint]      /'
}
warn_stray_repos

# --- inbound SSH (VS Code Remote-SSH, T3 SSH environments) --------------------
# T3's "Open in VS Code" builds vscode://vscode-remote/ssh-remote+<host><path>:
# no port, no path translation. It only works if <host> is SSH-reachable and
# has the same absolute paths, i.e. if this container *is* the SSH target.
#
# Key-only, root login restricted to keys. Nothing starts unless a key is
# present - an sshd nobody can authenticate to is just an open port.
#
# Host keys live in SSH_STATE_DIR (/root/.config is a bind mount) so rebuilds do
# not change the fingerprint and re-prompt every client.
start_sshd() {
  [ "${ENABLE_SSH}" = "1" ] || { echo "[entrypoint] sshd disabled (ENABLE_SSH=0)"; return 0; }
  command -v sshd >/dev/null 2>&1 || { echo "[entrypoint] sshd missing - rebuild the image"; return 0; }

  local keys_file=""
  if [ -s "${SSH_AUTHORIZED_KEYS_FILE}" ]; then
    keys_file="${SSH_AUTHORIZED_KEYS_FILE}"
  elif [ -z "${SSH_AUTHORIZED_KEYS:-}" ]; then
    echo "[entrypoint] sshd not started: no key in ${SSH_AUTHORIZED_KEYS_FILE}"
    echo "[entrypoint]   (drop an ed25519/rsa public key there to enable Remote-SSH)"
    return 0
  fi

  install -d -m 0700 "${SSH_STATE_DIR}" /root/.ssh /run/sshd
  if [ ! -f "${SSH_STATE_DIR}/host_ed25519" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "codecontainer@$(hostname)" \
      -f "${SSH_STATE_DIR}/host_ed25519"
  fi

  if [ -n "$keys_file" ]; then
    install -m 0600 "${keys_file}" /root/.ssh/authorized_keys
  else
    printf '%s\n' "${SSH_AUTHORIZED_KEYS}" \
      | grep -v '^[[:space:]]*$' > /root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys
  fi

  cat > "${SSH_STATE_DIR}/sshd_config" <<EOF
Port 22
ListenAddress 0.0.0.0
HostKey ${SSH_STATE_DIR}/host_ed25519
PidFile /run/sshd.pid
AuthorizedKeysFile /root/.ssh/authorized_keys
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
UseDNS no
AllowTcpForwarding yes
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp internal-sftp
LogLevel VERBOSE
EOF

  if /usr/sbin/sshd -f "${SSH_STATE_DIR}/sshd_config" -E /tmp/sshd.log; then
    echo "[entrypoint] sshd listening on 22 (key-only, $(wc -l < /root/.ssh/authorized_keys) key(s))"
  else
    echo "[entrypoint] !! sshd failed to start - see /tmp/sshd.log"
    tail -3 /tmp/sshd.log 2>/dev/null | sed 's/^/[entrypoint]   /'
  fi
}

# VS Code installs its remote server into ~/.vscode-server; keep it on the
# persisted ~/.local bind mount so rebuilds do not re-download it.
install -d /root/.local/vscode-server
[ -e /root/.vscode-server ] || ln -s /root/.local/vscode-server /root/.vscode-server

start_sshd

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
  if [ -f /run/sshd.pid ]; then
    kill "$(cat /run/sshd.pid)" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

banner

# --- T3 Code control surface (foreground / PID 1) ----------------------------
# Runtime channel override: set T3_CHANNEL (e.g. "latest" for the stable
# release, "nightly", or a pinned version like "0.1.0") to use that build even
# when a different one is baked into the image. Unset -> use the baked `t3`.
T3_CHANNEL="${T3_CHANNEL:-}"
if [ -n "${T3_CHANNEL}" ]; then
  set -- npx -y "t3@${T3_CHANNEL}" serve --host "${T3_HOST}" --port "${T3_PORT}" --no-browser --base-dir "${T3CODE_HOME}"
elif command -v t3 >/dev/null 2>&1; then
  set -- t3 serve --host "${T3_HOST}" --port "${T3_PORT}" --no-browser --base-dir "${T3CODE_HOME}"
else
  set -- npx -y "t3@${T3_VERSION:-latest}" serve --host "${T3_HOST}" --port "${T3_PORT}" --no-browser --base-dir "${T3CODE_HOME}"
fi
echo "[entrypoint] exec: $*"

# Runs in the background: the container must come up whether or not the network
# is reachable for mise, or T3 is ready to mint a token yet.
print_pairing &
prep_mise &

exec "$@"
