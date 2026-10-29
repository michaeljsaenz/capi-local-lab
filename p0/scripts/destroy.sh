#!/usr/bin/env bash
# Teardown Phase 0: delete the management plane and host services.
set -euo pipefail

CLUSTER_NAME="capi-mgmt"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

# --- 1. Management Kind cluster ---------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "Deleting Kind cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME"
else
  log "Kind cluster '$CLUSTER_NAME' not present - skipping"
fi

# --- 2. Host chart server ---------------------------------------------------
if docker ps -a --format '{{.Names}}' | grep -qx chart-server; then
  log "Removing chart server container"
  docker rm -f chart-server >/dev/null
else
  log "Chart server not present - skipping"
fi

# --- 3. Host git daemon -----------------------------------------------------
# `git daemon` re-execs as `git-daemon`, so match the separator with a wildcard.
if pgrep -f 'git.daemon.*--export-all' >/dev/null 2>&1; then
  log "Stopping git daemon"
  pkill -f 'git.daemon.*--export-all'
else
  log "Git daemon not running - skipping"
fi
rm -rf /tmp/fleet-capi-git-root

log "Teardown complete - next 'make bootstrap' starts clean."
