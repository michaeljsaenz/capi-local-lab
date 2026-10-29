.PHONY: bootstrap destroy provision deprovision verify onboard offboard

# Phase 0: host runtime + management plane (CAPI, CAPD, CAAPH, CAAPF, Fleet).
bootstrap:
	p0/scripts/bootstrap.sh

# Tear down Phase 0: delete the management cluster + host services.
destroy:
	p0/scripts/destroy.sh

# Phase 1: provision the workload cluster + addons via Fleet GitOps.
provision:
	p1/scripts/provision.sh

# Tear down Phase 1: remove the workload cluster + addons (mgmt plane stays).
deprovision:
	p1/scripts/deprovision.sh

# Phase 1: health-check a workload cluster, e.g. `make verify CLUSTER=local-cluster`.
verify:
	p1/scripts/verify.sh $(CLUSTER)

# Phase 2: deliver apps to downstream cluster(s) via Fleet GitOps.
onboard:
	p2/scripts/onboard.sh

# Tear down Phase 2: remove the apps GitRepo (Phases 0 and 1 stay).
offboard:
	p2/scripts/offboard.sh
