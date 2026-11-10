# Gmail GTD: build and install the Mac app.
#
#   make                 build build/GmailGTD.app (release)
#   make install         build, install to ~/Applications (quits a running copy) and launch it
#   make install OPEN=0  the same, without launching
#   make help            list every target

APP   := build/GmailGTD.app
OPEN  ?= 1

.DEFAULT_GOAL := app
.PHONY: app debug install run demo test clean help ios-project ios-sim ios-device

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

IOS_SIM ?= iPhone 17 Pro
IOS_DD  := build/ios-dd

ios-project: ## Generate iOS/GmailGTDiOS.xcodeproj (needs `brew install xcodegen`)
	cd iOS && xcodegen generate --quiet

ios-sim: ios-project ## Build the iPhone app and run it in the simulator on the demo mailbox (IOS_SIM="iPhone 17 Pro")
	xcodebuild -project iOS/GmailGTDiOS.xcodeproj -scheme GmailGTDiOS -destination 'platform=iOS Simulator,name=$(IOS_SIM)' -derivedDataPath $(IOS_DD) -quiet build
	xcrun simctl boot "$(IOS_SIM)" 2>/dev/null || true
	open -b com.apple.iphonesimulator 2>/dev/null || echo "Simulator app not found: the app still runs; take screenshots with xcrun simctl io booted screenshot"
	xcrun simctl install "$(IOS_SIM)" "$(IOS_DD)/Build/Products/Debug-iphonesimulator/Gmail GTD.app"
	xcrun simctl launch "$(IOS_SIM)" dev.denw.gmail-gtd.ios --demo

ios-device: ios-project ## Open the iOS project in Xcode to run on your iPhone (pick your team under Signing)
	open iOS/GmailGTDiOS.xcodeproj

clean: ## Remove build outputs (build/ and .build/)
	rm -rf build .build

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'
