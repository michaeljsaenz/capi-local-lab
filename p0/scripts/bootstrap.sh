#!/usr/bin/env bash
# Bootstrap: host runtime + management plane.
set -euo pipefail

# --- Paths ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"          # repo root (p0/scripts -> root)

CLUSTER_NAME="capi-mgmt"
# GitRepo manifests use this with envsubst; export it when applying them.
CANONICAL_REPO="${CANONICAL_REPO:-capi-local-lab}"   # git path segment served under GIT_ROOT
CHART_DIR="$REPO_ROOT/charts"
CHART_PORT="8879"
GIT_LOG="/tmp/git-daemon.log"
GIT_ROOT="/tmp/fleet-capi-git-root"     # base-path holding the canonical symlink

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

# --- 0. Preflight: required tooling and runtime -----------------------------
log "Checking prerequisites"
missing=()
for cmd in docker kind kubectl clusterctl helm git python3; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required command(s): ${missing[*]}" >&2
  exit 1
fi

docker info >/dev/null 2>&1 || {
  echo "ERROR: Docker runtime unreachable - start OrbStack (or Docker) and retry." >&2
  exit 1
}

# --- 1. Kernel limits (reset on every runtime restart) ----------------------
log "Raising inotify limits"
docker run --privileged --rm alpine \
  sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512 >/dev/null

# --- 2. Management Kind cluster ---------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "Kind cluster '$CLUSTER_NAME' already exists - reusing"
else
  log "Creating Kind cluster '$CLUSTER_NAME'"
  # Mount the host Docker socket so CAPD can run workload nodes as containers.
  kind create cluster --name "$CLUSTER_NAME" --config=- <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
    - hostPath: /var/run/docker.sock
      containerPath: /var/run/docker.sock
EOF
fi
kind export kubeconfig --name "$CLUSTER_NAME"
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

# --- 3. CAPI + CAPD + CAAPH + CAAPF -----------------------------------------
if kubectl get namespace capi-system >/dev/null 2>&1; then
  log "CAPI already installed - skipping clusterctl init"
else
  log "Installing CAPI (docker) + CAAPH + CAAPF"
  export CLUSTER_TOPOLOGY=true   # REQUIRED - defaults to false in CAPI v1.13+
  clusterctl init --infrastructure docker --addon helm,rancher-fleet
fi

# --- 4. Fleet ---------------------------------------------------------------
# Guarded: re-running helm upgrade after step 7 stamps the fleet-controller
# ConfigMap conflicts on .data.config, so skip once the release exists.
if helm status fleet -n cattle-fleet-system >/dev/null 2>&1; then
  log "Fleet already installed - skipping helm install"
else
  log "Installing Fleet"
  helm repo add fleet https://rancher.github.io/fleet-helm-charts/ >/dev/null 2>&1 || true
  helm repo update fleet >/dev/null
  helm upgrade --install fleet-crd fleet/fleet-crd \
    -n cattle-fleet-system --create-namespace --wait
  helm upgrade --install fleet fleet/fleet \
    -n cattle-fleet-system --wait
fi
kubectl rollout status deployment fleet-controller -n cattle-fleet-system
kubectl rollout status deployment gitjob -n cattle-fleet-system

# --- 5. Host git daemon (serves committed refs to Fleet) --------------------
# Fleet's GitRepo URL requests /$CANONICAL_REPO. Serve the repo under that
# canonical path via a symlink, so the clone dir can be named anything and only
# this repo is exposed (not sibling repos under the parent).
mkdir -p "$GIT_ROOT"
ln -sfn "$REPO_ROOT" "$GIT_ROOT/$CANONICAL_REPO"
if pgrep -f 'git.daemon.*--export-all' >/dev/null 2>&1; then
  log "Git daemon already running"
else
  log "Starting git daemon on :9418 (serving /$CANONICAL_REPO)"
  git daemon --reuseaddr --base-path="$GIT_ROOT" --export-all \
    --enable=receive-pack --listen=0.0.0.0 >"$GIT_LOG" 2>&1 &
fi

# --- 6. Host chart server ---------------------------------------------------
if docker ps --format '{{.Names}}' | grep -qx chart-server; then
  log "Chart server already running"
else
  log "Starting chart server on :$CHART_PORT"
  docker rm -f chart-server >/dev/null 2>&1 || true
  docker run -d --name chart-server --network kind \
    --restart=unless-stopped \
    -v "$CHART_DIR:/charts" -w /charts \
    python:3-alpine python -m http.server "$CHART_PORT" --bind 0.0.0.0 >/dev/null
fi

# --- 7. Point Fleet's agent callback at the management API ------------------
log "Configuring Fleet apiServerURL + apiServerCA"
MGMT_IP=$(docker inspect "${CLUSTER_NAME}-control-plane" \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
CA_B64=$(kubectl config view --raw \
  -o jsonpath="{.clusters[?(@.name==\"kind-$CLUSTER_NAME\")].cluster.certificate-authority-data}")
kubectl get configmap fleet-controller -n cattle-fleet-system \
  -o jsonpath='{.data.config}' > /tmp/fc.json
python3 - "$MGMT_IP" "$CA_B64" <<'PY'
import json, sys
ip, ca = sys.argv[1], sys.argv[2]
with open('/tmp/fc.json') as f:
    cfg = json.load(f)
cfg['apiServerURL'] = f'https://{ip}:6443'
cfg['apiServerCA'] = ca
with open('/tmp/fc-new.json', 'w') as f:
    json.dump(cfg, f, indent=2)
PY
kubectl create configmap fleet-controller -n cattle-fleet-system \
  --from-file=config=/tmp/fc-new.json \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment fleet-controller -n cattle-fleet-system

log "Bootstrap complete - management plane is ready."
