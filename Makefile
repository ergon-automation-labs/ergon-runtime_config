SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)
# Toolchain locations are machine-specific, so they are resolved per machine by
# the versioned resolver in the shared scripts dir (scripts/bot-helpers/portable.mk).
SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)
PORTABLE_MK := $(SCRIPTS_DIRECTORY)/portable.mk
ifneq ($(wildcard $(PORTABLE_MK)),)
include $(PORTABLE_MK)
else ifeq ($(strip $(MIX)),)
$(error mix: no portable resolver at $(PORTABLE_MK) and no MIX set — run `make install-helpers` in the elixir_bots monorepo, or pass MIX=/path/to/mix)
else
$(warning no portable resolver at $(PORTABLE_MK) — using MIX=$(MIX) as-is; run `make install-helpers` for portable resolution)
endif

.PHONY: setup help deps test credo dialyzer coverage check format clean release publish-release setup-hooks setup-db reset-db logs push-and-publish bump-version

help:
	@echo "Runtime Config Bot"
	@echo ""
	@echo "Setup commands:"
	@echo "  make setup           - Set up project (deps.get + install git hooks + setup database)"
	@echo "  make setup-hooks     - Install git hooks for pre-push validation"
	@echo "  make setup-db        - Create and migrate test database (required for testing)"
	@echo "  make reset-db        - Drop and recreate test database (useful for troubleshooting)"
	@echo ""
	@echo "Development commands:"
	@echo "  make test            - Run all tests"
	@echo "  make credo           - Run linter"
	@echo "  make dialyzer        - Run static analysis"
	@echo "  make coverage        - Run tests with coverage"
	@echo "  make check           - Run all checks (test, credo, dialyzer)"
	@echo "  make format          - Format Elixir code"
	@echo "  make clean           - Clean build artifacts"
	@echo ""
	@echo "Operations (deployed server logs):"
	@echo "  make logs            - Tail server log with grc (auto-detected by repo name; make -C .. install-grc)"
	@echo ""
	@echo "Release commands:"
	@echo "  make release         - Build OTP release locally"
	@echo "  make publish-release - Build, package, and publish to GitHub"
	@echo ""
	@echo "Normal workflow:"
	@echo "  git push             - Fast compile+test validation"
	@echo "  make push-and-publish - Push then publish release asset"
	@echo ""

setup: init deps setup-hooks
	@echo "✓ Setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Optional: configure .env (NATS_HOST, NATS_PORT, BOT_ARMY_TENANT_ID)"
	@echo "  2. Run: make test"
	@echo "  3. Start developing!"
	@echo ""

setup-hooks:
	@git config core.hooksPath git-hooks
	@echo "✓ Git hooks installed (core.hooksPath = git-hooks)"

setup-db:
	@echo "This bot has no database (ETS in memory). Nothing to do."

reset-db:
	@echo "This bot has no database (ETS in memory). Nothing to do."

init:
	@if [ ! -d .git ]; then git init; echo "Git initialized."; else echo "Git already initialized."; fi

deps:
	$(MIX) deps.get

compile:
	@LOG_FILE="/tmp/compile-config-$$(date +%s).log"; \
	echo "Compiling config and logging to $$LOG_FILE..."; \
	$(MIX) compile 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Compilation log: $$LOG_FILE"

test:
	$(MIX) test

credo:
	$(MIX) credo --only warning

dialyzer: deps
	$(MIX) dialyzer

coverage:
	$(MIX) coveralls

check: test credo
	@echo "All checks passed!"

format:
	$(MIX) format

clean:
	$(MIX) clean
	rm -rf _build cover

release: check
	@echo "==============================================="
	@echo "Building OTP release"
	@echo "==============================================="
	rm -rf _build/prod/rel/runtime_config_bot
	MIX_ENV=prod $(MIX) release
	@echo ""
	@echo "✓ Release built successfully"
	@echo "Location: _build/prod/rel/runtime_config_bot/"
	@echo ""

publish-release: release
	@echo "==============================================="
	@echo "Publishing release to GitHub"
	@echo "==============================================="
	@echo ""

	# Get version from release metadata
	VERSION=$$(cat _build/prod/rel/runtime_config_bot/releases/RELEASES | tail -1 | cut -d' ' -f2); \
	echo "Version: $$VERSION"; \
	\
	# Create tarball
	echo "Creating release tarball..."; \
	tar -czf runtime_config_bot-$$VERSION.tar.gz -C _build/prod/rel runtime_config_bot/; \
	echo "✓ Tarball created: runtime_config_bot-$$VERSION.tar.gz"; \
	echo ""; \
	\
	# Create GitHub release
	echo "Creating GitHub release v$$VERSION..."; \
	gh release create v$$VERSION runtime_config_bot-$$VERSION.tar.gz \
		--title "Release v$$VERSION" \
		--notes "Runtime Config Bot Elixir release v$$VERSION. Download and deploy with Jenkins." \
		--draft=false; \
	echo "✓ Release published to GitHub"; \
	echo ""; \
	echo "Next steps:"; \
	echo "1. Jenkins will automatically detect the new release"; \
	echo "2. Trigger deployment in Jenkins UI or wait for auto-deployment"; \
	echo "3. Check deployment status: make jenkins-logs"; \
	echo ""

push-and-publish:
	@git push && $(MAKE) publish-release

logs:
	@$(SCRIPTS_DIRECTORY)/tail_bot_log.sh

bump-version:
	@if [ -z "$(BUMP)" ]; then echo "Usage: make bump-version BUMP=major|minor|patch"; exit 1; fi
	@OLD=$$(grep 'version:' mix.exs | head -1 | sed -E 's/.*version: "([^"]+)".*/\1/'); \
	bash $(SCRIPTS_DIRECTORY)/bump_version.sh mix.exs $(BUMP) > /dev/null; \
	NEW=$$(grep 'version:' mix.exs | head -1 | sed -E 's/.*version: "([^"]+)".*/\1/'); \
	echo "✓ Bumped: $$OLD → $$NEW"

push: test compile credo
	@echo "✅ All validations passed"
	@echo "$$(date +%s)" > .push-validated
	@echo "✓ Proof-of-validation created"
	@$(MAKE) git-push


git-push:
	@LOG="/tmp/git-push-$$(date +%s).log"; if git push origin main > "$$LOG" 2>&1; then tail -3 "$$LOG"; else cat "$$LOG"; echo "✗ Push failed — log: $$LOG"; exit 1; fi
