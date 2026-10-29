#!/usr/bin/env bash
# Bootstrap Phase 1: workload cluster + label-matched infrastructure, delivered
# via Fleet GitOps. Idempotent - safe to re-run. Requires Phase 0 first
# (`make bootstrap`): management plane, git daemon, and chart server must be up.
set -euo pipefail

# --- Paths ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"          # repo root (p1/scripts -> root)

CLUSTER_NAME="local-cluster"
MGMT_CONTEXT="kind-capi-mgmt"
CHART_SERVER="chart-server"
# Fleet's GitRepo URL requests /$CANONICAL_REPO; must match p0/scripts/bootstrap.sh.
CANONICAL_REPO="${CANONICAL_REPO:-capi-local-lab}"
WATCH_PATH="p1/clusters/local"          # committed path the cluster GitRepo watches

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

# --- 0. Preflight: tooling + Phase 0 must be up -----------------------------
log "Checking prerequisites"
missing=()
for cmd in docker kubectl git envsubst; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required command(s): ${missing[*]}" >&2
  exit 1
fi
kubectl config use-context "$MGMT_CONTEXT" >/dev/null 2>&1 || {
  echo "ERROR: context '$MGMT_CONTEXT' not found - run 'make bootstrap' first." >&2
  exit 1
}
docker ps --format '{{.Names}}' | grep -qx "$CHART_SERVER" || {
  echo "ERROR: '$CHART_SERVER' not running - run 'make bootstrap' first." >&2
  exit 1
}

# --- 1. Chart server IP (dynamic on the kind network) -----------------------
CHART_SERVER_IP=$(docker inspect "$CHART_SERVER" \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
export CHART_SERVER_IP
log "Chart server at $CHART_SERVER_IP:8879"

# --- 2. HelmChartProxy addon templates --------------------------------------
# repoURL carries ${CHART_SERVER_IP}; CAAPH turns these into HelmReleaseProxies
# on label-matched workload clusters.
log "Applying HelmChartProxy addons (cilium, cert-manager, ingress)"
for addon in cilium cert-manager ingress; do
  envsubst < "$REPO_ROOT/p1/addons/helmchartproxy-$addon.yaml" | kubectl apply -f -
done

# --- 3. ClusterClass --------------------------------------------------------
# The cluster uses topology.class: quick-start, so this must exist first.
log "Applying quick-start ClusterClass"
kubectl apply -f "$REPO_ROOT/p1/cluster-quickstart.yaml"

# --- 4. Label the Fleet local cluster so the cluster GitRepo target matches --
# The GitRepo targets management.cattle.io/cluster-display-name=local; Fleet does
# not set that label automatically.
log "Labeling Fleet local cluster for GitRepo targeting"
for _ in $(seq 1 30); do
  kubectl get cluster.fleet.cattle.io -n fleet-local local >/dev/null 2>&1 && break
  sleep 2
done
kubectl label cluster.fleet.cattle.io -n fleet-local local \
  management.cattle.io/cluster-display-name=local --overwrite >/dev/null

# --- 5. Cluster GitRepo (Fleet pulls the committed cluster manifest) --------
# Fleet clones a COMMITTED ref from the host git daemon, never the working tree.
GIT_BRANCH=$(git -C "$REPO_ROOT" branch --show-current)
export GIT_BRANCH CANONICAL_REPO
if ! git -C "$REPO_ROOT" ls-tree -r --name-only "$GIT_BRANCH" -- "$WATCH_PATH" | grep -q .; then
  echo "ERROR: '$WATCH_PATH' is not committed on branch '$GIT_BRANCH'." >&2
  echo "       Fleet serves committed refs only. Commit it first:" >&2
  echo "         git add $WATCH_PATH && git commit -m 'Add $WATCH_PATH'" >&2
  exit 1
fi
log "Applying cluster GitRepo (branch '$GIT_BRANCH', repo '$CANONICAL_REPO')"
envsubst < "$REPO_ROOT/p1/gitrepo.yaml" | kubectl apply -f -

# --- 6. Report --------------------------------------------------------------
log "Phase 1 applied - Fleet will provision '$CLUSTER_NAME' from $WATCH_PATH."
echo "Watch:   kubectl get cluster $CLUSTER_NAME -n default --watch"
echo "Verify:  make verify CLUSTER=$CLUSTER_NAME"
