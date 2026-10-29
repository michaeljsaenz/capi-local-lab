#!/usr/bin/env bash
# Teardown Phase 1: remove the workload cluster, its GitRepo, and addon
# templates. Leaves the Phase 0 management plane intact. Safe to re-run.
set -euo pipefail

# --- Paths ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"          # repo root (p1/scripts -> root)

CLUSTER_NAME="local-cluster"
MGMT_CONTEXT="kind-capi-mgmt"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

kubectl config use-context "$MGMT_CONTEXT" >/dev/null 2>&1 || {
  log "Context '$MGMT_CONTEXT' not found - nothing to tear down."
  exit 0
}

# --- 1. GitRepo first (stop Fleet re-applying the cluster) ------------------
log "Deleting cluster GitRepo"
kubectl delete gitrepo capi-clusters -n fleet-local --ignore-not-found

# --- 2. Workload cluster ----------------------------------------------------
log "Deleting workload cluster '$CLUSTER_NAME'"
kubectl delete cluster "$CLUSTER_NAME" -n default --ignore-not-found --wait=false

# --- 3. HelmChartProxy addon templates --------------------------------------
log "Deleting HelmChartProxy addons"
kubectl delete helmchartproxy cilium cert-manager nginx-ingress \
  -n default --ignore-not-found

# --- 4. ClusterClass (skipped while the cluster is still deleting) -----------
# CAPI's webhook rejects deleting a ClusterClass that is still in use, so this
# may no-op until the cluster finishes terminating; re-run to remove it.
log "Deleting quick-start ClusterClass"
kubectl delete -f "$REPO_ROOT/p1/cluster-quickstart.yaml" --ignore-not-found \
  || log "ClusterClass still in use (cluster deleting) - re-run later to remove."

log "Phase 1 torn down. Management plane (Phase 0) left intact."
