.PHONY: bootstrap destroy

# Phase 0: host runtime + management plane (CAPI, CAPD, CAAPH, CAAPF, Fleet).
bootstrap:
	p0/scripts/bootstrap.sh

# Tear down Phase 0: delete the management cluster + host services.
destroy:
	p0/scripts/destroy.sh
