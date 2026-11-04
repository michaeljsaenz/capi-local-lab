#!/usr/bin/env bash
# Phase 3: the whole platform, soup to nuts, in one command. Chains Phases 0-2
# (bootstrap -> provision -> onboard) and gates each hand-off on real readiness,
# since provision and onboard return before Fleet/CAPI finish reconciling.
# Idempotent - safe to re-run; already-ready gates pass immediately.
set -euo pipefail

# --- Paths ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"          # repo root (p3/scripts -> root)

CLUSTER_NAME="local-cluster"
MGMT_CONTEXT="kind-capi-mgmt"
TARGET_NS="default"                      # CAPI Cluster, Fleet Cluster, and apps GitRepo ns
APP_NAME="hello-world"
WC_KUBECONFIG="/tmp/${CLUSTER_NAME}-kubeconfig"   # written by p1/scripts/verify.sh
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"      # seconds per readiness gate
POLL_INTERVAL=5

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
phase() { printf '\n\033[1;35m######## %s ########\033[0m\n' "$*"; }

# wait_until <description> <check-fn>: poll check-fn until it succeeds or
# WAIT_TIMEOUT elapses.
wait_until() {
  local desc="$1" check="$2" waited=0
  printf '\033[1;33m...\033[0m waiting: %s ' "$desc"
  until "$check" >/dev/null 2>&1; do
    if (( waited >= WAIT_TIMEOUT )); then
      printf '\n'
      echo "ERROR: timed out after ${WAIT_TIMEOUT}s waiting for: $desc" >&2
      echo "       Re-run 'make up' to resume, or raise WAIT_TIMEOUT." >&2
      exit 1
    fi
    printf '.'
    sleep "$POLL_INTERVAL"
    waited=$(( waited + POLL_INTERVAL ))
  done
  printf ' \033[1;32mready\033[0m (%ss)\n' "$waited"
}

mgmt() { kubectl --context "$MGMT_CONTEXT" "$@"; }

# --- Readiness checks -------------------------------------------------------
providers_available() {
  local ns
  for ns in capi-system capi-kubeadm-bootstrap-system \
            capi-kubeadm-control-plane-system capd-system caaph-system caapf-system; do
    mgmt wait --for=condition=Available deployment --all -n "$ns" --timeout=5s || return 1
  done
}

# clusterctl init returns before the provider webhooks serve; a server-side
# dry-run of Phase 1's HelmChartProxies + ClusterClass exercises the CAAPH,
# CAPI, and CAPD webhooks without persisting anything.
webhooks_serving() {
  local addon
  for addon in cilium cert-manager ingress; do
    CHART_SERVER_IP=127.0.0.1 envsubst < "$REPO_ROOT/p1/addons/helmchartproxy-$addon.yaml" \
      | mgmt apply --dry-run=server -f - || return 1
  done
  mgmt apply --dry-run=server -f "$REPO_ROOT/p1/cluster-quickstart.yaml"
}

cluster_exists() { mgmt get cluster "$CLUSTER_NAME" -n "$TARGET_NS"; }

# Available=True needs the control plane up and both workers Ready - which in
# turn needs Cilium (no CNI, no Ready nodes).
cluster_available() {
  [[ "$(mgmt get cluster "$CLUSTER_NAME" -n "$TARGET_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" == "True" ]]
}

addons_deployed() {
  local statuses
  statuses=$(mgmt get helmreleaseproxy -n "$TARGET_NS" \
    -l "cluster.x-k8s.io/cluster-name=$CLUSTER_NAME" \
    -o jsonpath='{range .items[*]}{.status.status}{"\n"}{end}')
  [[ "$(grep -cx deployed <<<"$statuses")" -ge 3 ]]
}

# CAAPF imports the cluster into Fleet; the downstream fleet-agent must have
# checked in (lastSeen set) and the Fleet Cluster must be Ready.
fleet_registered() {
  local out
  out=$(mgmt get cluster.fleet.cattle.io -n "$TARGET_NS" -l environment=local \
    -o jsonpath='{range .items[*]}{.status.agent.lastSeen}|{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')
  grep -Eq '^[^|]+\|True$' <<<"$out"
}

# GitRepo display reads "<ready>/<desired>", e.g. "1/1".
apps_delivered() {
  local rbd
  rbd=$(mgmt get gitrepo apps -n "$TARGET_NS" \
    -o jsonpath='{.status.display.readyBundleDeployments}')
  [[ "$rbd" =~ ^([0-9]+)/([0-9]+)$ ]] \
    && (( BASH_REMATCH[2] > 0 && BASH_REMATCH[1] == BASH_REMATCH[2] ))
}

app_available() {
  KUBECONFIG="$WC_KUBECONFIG" kubectl rollout status "deployment/$APP_NAME" \
    -n "$TARGET_NS" --timeout=5s
}

START=$(date +%s)

# --- Preflight: union of the Phase 0-2 tooling, checked once up front --------
log "Checking prerequisites"
missing=()
for cmd in docker kind kubectl clusterctl helm git python3 envsubst; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required command(s): ${missing[*]}" >&2
  exit 1
fi

# --- Phase 0: management plane ----------------------------------------------
phase "Phase 0: bootstrap the management plane"
"$REPO_ROOT/p0/scripts/bootstrap.sh"

log "Gating Phase 0 on the management controllers"
wait_until "CAPI/CAPD/CAAPH/CAAPF controllers Available" providers_available
wait_until "provider webhooks serving"                   webhooks_serving

# --- Phase 1: workload cluster + addons -------------------------------------
phase "Phase 1: provision the workload cluster"
"$REPO_ROOT/p1/scripts/provision.sh"

log "Gating Phase 1 on the provisioning cascade"
wait_until "Fleet delivers Cluster '$CLUSTER_NAME'"                cluster_exists
wait_until "Cluster '$CLUSTER_NAME' Available (CP + workers)"      cluster_available
wait_until "CAAPH addons deployed (cilium, cert-manager, ingress)" addons_deployed
wait_until "CAAPF registers '$CLUSTER_NAME' into Fleet"            fleet_registered

# Writes $WC_KUBECONFIG and health-checks nodes + infra.
"$REPO_ROOT/p1/scripts/verify.sh" "$CLUSTER_NAME"

# --- Phase 2: apps ----------------------------------------------------------
phase "Phase 2: onboard apps"
"$REPO_ROOT/p2/scripts/onboard.sh"

log "Gating Phase 2 on app delivery"
wait_until "apps GitRepo bundle deployments ready"     apps_delivered
wait_until "'$APP_NAME' rolled out on '$CLUSTER_NAME'" app_available

# --- Report -----------------------------------------------------------------
ELAPSED=$(( $(date +%s) - START ))
phase "Platform ready in $(( ELAPSED / 60 ))m$(( ELAPSED % 60 ))s"
mgmt get cluster "$CLUSTER_NAME" -n "$TARGET_NS"
mgmt get gitrepo -A
KUBECONFIG="$WC_KUBECONFIG" kubectl get deploy,svc -n "$TARGET_NS" -l "app=$APP_NAME"
echo ""
echo "Workload cluster:  export KUBECONFIG=$WC_KUBECONFIG"
echo "Tear it all down:  make down"
