.PHONY: help all setup deps build fmt fmt-check diff-check lint test windows-native-test coverage ci dialyzer e2e

MIX ?= mix
DIFF_RANGE ?=

help:
	@echo "Targets: setup, deps, fmt, fmt-check, diff-check, lint, test, windows-native-test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

diff-check:
ifeq ($(strip $(DIFF_RANGE)),)
	git diff --check
else
	git diff --check $(DIFF_RANGE)
endif

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

windows-native-test:
	$(MIX) test test/symphony_elixir/local_shell_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/windows_preflight_test.exs test/symphony_elixir/ssh_test.exs test/mix/tasks/workspace_before_remove_test.exs test/mix/tasks/pr_body_check_test.exs test/symphony_elixir/specs_check_test.exs

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) diff-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
