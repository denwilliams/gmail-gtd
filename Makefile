# Gmail GTD: build and install the Mac app.
#
#   make                 build build/GmailGTD.app (release)
#   make install         build, install to ~/Applications (quits a running copy) and launch it
#   make install OPEN=0  the same, without launching
#   make help            list every target

APP   := build/GmailGTD.app
OPEN  ?= 1

.DEFAULT_GOAL := app
.PHONY: app debug install run demo test clean help

app: ## Build build/GmailGTD.app (release)
	./scripts/make-app.sh release

debug: ## Build build/GmailGTD.app (debug: faster to compile)
	./scripts/make-app.sh debug

install: ## Build and install to ~/Applications, replacing any copy (OPEN=0 to not launch)
	./scripts/install.sh $(if $(filter 0,$(OPEN)),--no-open)

run: app ## Build, then open the app from build/
	open $(APP)

demo: app ## Build, then open the app on the demo mailbox (no sign-in; resets on relaunch)
	open -n $(APP) --args --demo

test: ## Run the unit tests
	swift test

clean: ## Remove build outputs (build/ and .build/)
	rm -rf build .build

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'
