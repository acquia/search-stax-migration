# acquia/search-stax-migration — Makefile
# Lint, smoke-test, and regenerate auto-generated documentation.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

SHELL := /usr/bin/env bash

.PHONY: help lint check test demo docs clean

help:
	@echo "Targets:"
	@echo "  lint        - bash -n + shellcheck on all shell scripts"
	@echo "  check       - lint + verify config keys, install.sh manifest, and docs"
	@echo "  test        - run --demo end-to-end with scripted answers (smoke test)"
	@echo "  demo        - launch interactive demo mode in this terminal"
	@echo "  docs        - check docs against the code (phases, subcommands, links)"
	@echo "  clean       - remove local artifacts/, logs/, state/"

SHELL_FILES := install.sh srsx-migrate \
               $(wildcard lib/demo/bin/*) \
               $(wildcard lib/php-eval/*.php)

lint:
	@for f in install.sh srsx-migrate lib/demo/bin/*; do \
	    bash -n "$$f" && echo "  bash -n $$f OK" || exit 1; \
	done
	@if command -v shellcheck >/dev/null 2>&1; then \
	    shellcheck install.sh srsx-migrate lib/demo/bin/* || exit 1; \
	    echo "  shellcheck OK"; \
	else \
	    echo "  shellcheck not installed (skipping)"; \
	fi

check: lint
	@bash tests/check-config-keys.sh
	@bash tests/check-install-manifest.sh
	@bash tests/check-arith-increment.sh
	@bash tests/generate-docs.sh --check

test:
	@rm -rf state/ artifacts/ logs/ /tmp/srsx-demo-home-mtest
	@SRSX_DEMO_HOME=/tmp/srsx-demo-home-mtest \
	 DEMO_ANSWERS="demoapp,dev,n,1,,main,https://demo.searchstax.com,write_token,https://analytics.demo.searchstax.com,analytics_key,1" \
	    ./srsx-migrate --demo all </dev/null >/tmp/srsx-demo.log 2>&1 \
	    && echo "  demo end-to-end OK (log: /tmp/srsx-demo.log)" \
	    || { tail -30 /tmp/srsx-demo.log; exit 1; }
	@bash tests/test-resume-after-completion.sh
	@bash tests/test-force-all-resets-progress.sh
	@bash tests/test-ssx-json-body.sh
	@bash tests/test-provision-skip-when-endpoint-set.sh
	@bash tests/test-provision-demo-skip.sh
	@bash tests/test-multisite-app-topology.sh
	@bash tests/test-remote-php-and-endpoint.sh
	@bash tests/test-phase-continues-onward.sh
	@bash tests/test-cache-rebuild-resilient.sh
	@bash tests/test-index-detection.sh
	@bash tests/test-clone-index.sh
	@bash tests/test-multisite-isolation.sh
	@bash tests/test-inspect-acquia-search-cores.sh
	@bash tests/test-preflight-search-health.sh
	@bash tests/test-loop-stdin.sh

demo:
	@./srsx-migrate --demo

docs:
	@bash tests/generate-docs.sh
clean:
	@rm -rf artifacts/ logs/ state/ /tmp/srsx-*.log
	@echo "  cleaned"
