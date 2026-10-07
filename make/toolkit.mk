# Targets shared by consuming repositories. In their Makefile:
#
#   SOPS_PLAINTEXT := compose/app/.env config/secrets.yaml
#   include toolkit/make/toolkit.mk
#
# Each plaintext path has its ciphertext next to it as <path>.sops.

# Directory of the toolkit, wherever the consumer mounted it.
TOOLKIT_DIR := $(patsubst %/,%,$(dir $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))))

# sops resolves the age key through the OS config directory, which is
# ~/Library/Application Support on macOS and ~/.config on Linux. Pinning the
# path keeps one convention across every machine.
SOPS_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE

SOPS_PLAINTEXT ?=

# Where `make hooks` points git. A repository can keep its own hooks directory
# that delegates to $(TOOLKIT_DIR)/hooks, for instance to keep a path its
# existing clones already use.
TOOLKIT_HOOKS_DIR ?= $(TOOLKIT_DIR)/hooks

.PHONY: secrets encrypt validate hooks

secrets: ## Déchiffre les .sops vers leurs fichiers en clair
	@$(TOOLKIT_DIR)/sops/sops-files.sh decrypt $(SOPS_PLAINTEXT)

encrypt: ## Chiffre les fichiers en clair vers .sops
	@$(TOOLKIT_DIR)/sops/sops-files.sh encrypt $(SOPS_PLAINTEXT)

validate: ## Contrôles bloquants (CI et hook pre-push)
	@$(TOOLKIT_DIR)/validate/validate.sh

hooks: ## Active le hook pre-push
	@git config core.hooksPath $(TOOLKIT_HOOKS_DIR) && echo "hooks activés : $(TOOLKIT_HOOKS_DIR)"
