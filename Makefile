.PHONY: help test

help: ## Liste les cibles
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:[^#]*## /\t/' | expand -t20

test: ## Tests du toolkit (validate, sops, action Discord sans envoi)
	@s=0; for t in tests/*.sh; do echo "== $$t"; $$t || s=1; done; exit $$s

include make/toolkit.mk
