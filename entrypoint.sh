#!/usr/bin/env bash
set -euo pipefail

T3_HOST="${T3_HOST:-0.0.0.0}"
T3_PORT="${T3_PORT:-3773}"
T3CODE_HOME="${T3CODE_HOME:-/root/.t3code}"
OPENCODE_HOST="${OPENCODE_HOST:-0.0.0.0}"
OPENCODE_PORT="${OPENCODE_PORT:-4096}"
ENABLE_OPENCODE_SERVER="${ENABLE_OPENCODE_SERVER:-1}"

export T3CODE_HOME
mkdir -p /workspace "$T3CODE_HOME" "${GOPATH:-/root/go}" "${CARGO_HOME:-/usr/local/cargo}"

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
    /workspace | /workspace/*)
      echo "refusing to wipe the projects mount"
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

banner() {
  printf '\n'
  printf '  CodeContainer  |  T3 Code + OpenCode  |  Ubuntu 26.04\n'
  printf '  ---------------------------------------------------------------\n'
  printf '  T3 Code UI     ->  http://<host>:%s\n' "${T3_PORT}"
  printf '  OpenCode API   ->  http://<host>:%s\n' "${OPENCODE_PORT}"
  printf '  App previews   ->  http://<host>:%s-%s\n' "${PORT_BASE:-30000}" "${PORT_END:-30099}"
  printf '  ---------------------------------------------------------------\n'
  printf '  workspace      ->  /workspace   (only host path mounted)\n'
  printf '  scratch        ->  %s\n' "${SCRATCH}"
  printf '  shell          ->  docker exec -it <container> bash\n'
  printf '  pair a device  ->  docker compose exec code pair\n'
  printf '  first run      ->  opencode auth login\n'
  printf '  agent rules    ->  /root/.config/opencode/AGENTS.md\n'
  printf '  T3 pairing token below is a password. Do not expose this port.\n\n'
}

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
  set -- npx -y t3@latest serve --host "${T3_HOST}" --port "${T3_PORT}" --no-browser --base-dir "${T3CODE_HOME}"
fi
echo "[entrypoint] exec: $*"
exec "$@"
