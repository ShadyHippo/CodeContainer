#!/usr/bin/env bash
# Clear the CodeContainer scratch directory -- but only while the container is
# NOT running, so it can never delete a build out from under a live agent.
#
# /tmp inside the container is a bind mount to $SCRATCH_DIR on the host
# (see compose.yaml). This is the "clear it when they're done" half; the
# container also wipes scratch itself on every start.
#
# Schedule it on UnRaid with the User Scripts plugin (hourly or daily).
#
#   ./scripts/scratch-sweep.sh
#   SCRATCH_DIR=/mnt/cache/scratch/codecontainer ./scripts/scratch-sweep.sh
set -euo pipefail

SCRATCH_DIR="${SCRATCH_DIR:-/mnt/cache/scratch/codecontainer}"
CONTAINER="${CONTAINER:-codecontainer}"

# --- refuse to touch anything that looks like a real data location -----------
case "$SCRATCH_DIR" in
  "" | "/" | "/mnt" | "/mnt/user" | "/mnt/cache" | "/mnt/user/Projects" | "/boot")
    echo "scratch-sweep: refusing to sweep '$SCRATCH_DIR'" >&2
    exit 1
    ;;
esac

if [ ! -d "$SCRATCH_DIR" ]; then
  echo "scratch-sweep: '$SCRATCH_DIR' does not exist, nothing to do"
  exit 0
fi

if command -v docker >/dev/null 2>&1 &&
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
  echo "scratch-sweep: '$CONTAINER' is running, skipping"
  exit 0
fi

count="$(find "$SCRATCH_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
find "$SCRATCH_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
echo "scratch-sweep: removed $count entr(ies) from $SCRATCH_DIR"
