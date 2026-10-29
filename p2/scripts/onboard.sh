#!/usr/bin/env bash
# Phase 2: deliver apps to downstream cluster(s) via Fleet GitOps. Idempotent -
# safe to re-run. Requires Phase 1 (`make provision`): CAAPF must have registered
# a downstream Fleet cluster labeled environment=local.
set -euo pipefail

# --- Paths ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"          # repo root (p2/scripts -> root)

MGMT_CONTEXT="kind-capi-mgmt"
# Fleet's GitRepo URL requests /$CANONICAL_REPO; must match p0/scripts/bootstrap.sh.
CANONICAL_REPO="${CANONICAL_REPO:-capi-local-lab}"
APPS_PATH="p2/apps/hello-world"         # committed path the apps GitRepo watches
TARGET_NS="default"                      # apps GitRepo ns = downstream Fleet cluster ns

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

# --- 0. Preflight: tooling + management plane -------------------------------
log "Checking prerequisites"
missing=()
for cmd in kubectl git envsubst; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required command(s): ${missing[*]}" >&2
  exit 1
fi
# Drop any inherited KUBECONFIG (e.g. the workload kubeconfig verify.sh exports);
# the mgmt context lives in the default config written by `kind export kubeconfig`.
unset KUBECONFIG
kubectl config use-context "$MGMT_CONTEXT" >/dev/null 2>&1 || {
  echo "ERROR: context '$MGMT_CONTEXT' not found - run 'make bootstrap' first." >&2
  exit 1
}

# --- 1. Require a registered downstream cluster (environment=local) ---------
# CAAPF registers CAPI workload clusters as fleet.cattle.io/Cluster objects and
# copies their labels; the apps GitRepo targets environment=local, so without a
# matching cluster there is nothing to deliver to.
if ! kubectl get cluster.fleet.cattle.io -A -l environment=local \
     -o name 2>/dev/null | grep -q .; then
  echo "ERROR: no Fleet cluster labeled environment=local found." >&2
  echo "       Run 'make provision' first so CAAPF registers the cluster." >&2
  exit 1
fi

# --- 2. Committed ref (Fleet clones a committed ref, never the working tree) -
GIT_BRANCH=$(git -C "$REPO_ROOT" branch --show-current)
export GIT_BRANCH CANONICAL_REPO
if ! git -C "$REPO_ROOT" ls-tree -r --name-only "$GIT_BRANCH" -- "$APPS_PATH" | grep -q .; then
  echo "ERROR: '$APPS_PATH' is not committed on branch '$GIT_BRANCH'." >&2
  echo "       Fleet serves committed refs only. Commit it first:" >&2
  echo "         git add $APPS_PATH && git commit -m 'Add $APPS_PATH'" >&2
  exit 1
fi

# --- 3. Apps GitRepo (Fleet pulls the committed app manifests) --------------
log "Applying apps GitRepo (branch '$GIT_BRANCH', repo '$CANONICAL_REPO')"
envsubst < "$REPO_ROOT/p2/gitrepo.yaml" | kubectl apply -f -

# --- 4. Report --------------------------------------------------------------
log "Phase 2 applied - Fleet will deliver $APPS_PATH to environment=local clusters."
echo "Watch:   kubectl get gitrepo apps -n $TARGET_NS --watch"
echo "Verify:  kubectl get bundles -n $TARGET_NS"
