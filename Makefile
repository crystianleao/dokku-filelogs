.PHONY: test lint unit-tests ci-dependencies clean

SHELL := /usr/bin/env bash
TMP_DIR := tmp
RESULTS := $(TMP_DIR)/test-results/bats

SCRIPTS := \
  commands config functions install uninstall \
  post-app-create post-delete post-app-rename \
  subcommands/default subcommands/enable subcommands/disable \
  subcommands/set subcommands/report subcommands/gc subcommands/tail \
  subcommands/backup subcommands/backup-auth subcommands/backup-deauth \
  subcommands/backup-schedule subcommands/backup-unschedule \
  subcommands/backup-report \
  gc/gc.sh

test: lint unit-tests

lint:
	@echo "--> shellcheck"
	@shellcheck -x $(SCRIPTS)

unit-tests: | $(RESULTS)
	@echo "--> bats"
	cd tests && bats --timing ./*.bats

$(RESULTS):
	mkdir -p $(RESULTS)

ci-dependencies:
	bash tests/setup.sh

clean:
	rm -rf $(TMP_DIR)
