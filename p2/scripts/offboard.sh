#!/usr/bin/env bash
# Teardown Phase 2: remove the apps GitRepo so Fleet stops delivering apps and
# garbage-collects the delivered bundles. Leaves Phases 0 and 1 intact. Safe to
# re-run.
set -euo pipefail

MGMT_CONTEXT="kind-capi-mgmt"
TARGET_NS="default"                      # apps GitRepo ns = downstream Fleet cluster ns

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

# Drop any inherited KUBECONFIG (e.g. the workload kubeconfig verify.sh exports);
# the mgmt context lives in the default config written by `kind export kubeconfig`.
unset KUBECONFIG
kubectl config use-context "$MGMT_CONTEXT" >/dev/null 2>&1 || {
  log "Context '$MGMT_CONTEXT' not found - nothing to tear down."
  exit 0
}

# --- Apps GitRepo (Fleet garbage-collects the delivered bundles) ------------
log "Deleting apps GitRepo"
kubectl delete gitrepo apps -n "$TARGET_NS" --ignore-not-found

log "Phase 2 torn down. Fleet removes the delivered apps; Phases 0 and 1 left intact."
