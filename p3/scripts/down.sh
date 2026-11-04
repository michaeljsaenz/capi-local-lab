#!/usr/bin/env bash
# Teardown Phase 3: the whole platform, in reverse. Peels Phases 2 -> 1 -> 0
# (offboard -> deprovision -> destroy); destroy deletes the management cluster
# and sweeps any CAPD containers still terminating. Safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"          # repo root (p3/scripts -> root)

phase() { printf '\n\033[1;35m######## %s ########\033[0m\n' "$*"; }

phase "Phase 2: offboard apps"
"$REPO_ROOT/p2/scripts/offboard.sh"

phase "Phase 1: deprovision the workload cluster"
"$REPO_ROOT/p1/scripts/deprovision.sh"

phase "Phase 0: destroy the management plane"
"$REPO_ROOT/p0/scripts/destroy.sh"

rm -f /tmp/local-cluster-kubeconfig

phase "Platform torn down - next 'make up' starts clean"
