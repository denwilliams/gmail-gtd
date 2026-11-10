# Gmail GTD: build and install the Mac app.
#
#   make                 build build/GmailGTD.app (release)
#   make install         build, install to ~/Applications (quits a running copy) and launch it
#   make install OPEN=0  the same, without launching
#   make help            list every target

APP   := build/GmailGTD.app
OPEN  ?= 1

.DEFAULT_GOAL := app
.PHONY: app debug install run demo test clean help ios-project ios-sim ios-device ios-signing ios-icon

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
# Signing for your own iPhone, kept in iOS/signing.env (not committed) so regenerating the project keeps it.
SIGNING := iOS/signing.env
-include $(SIGNING)
GMAIL_GTD_TEAM      ?=
GMAIL_GTD_BUNDLE_ID ?= dev.denw.gmail-gtd.ios
export GMAIL_GTD_TEAM GMAIL_GTD_BUNDLE_ID

IOS_PBX := iOS/GmailGTDiOS.xcodeproj/project.pbxproj

# With no TEAM or BUNDLE_ID given, it reads what you last picked in Xcode's Signing tab (the project file Xcode saved).
ios-signing: ## Save the iPhone app's signing team and bundle ID: pick them in Xcode, then run this (or pass TEAM=, BUNDLE_ID=)
	@team="$(TEAM)"; bundle="$(BUNDLE_ID)"; \
	[ -n "$$team" ] || team=$$(grep -m1 -oE 'DEVELOPMENT_TEAM = "?[A-Z0-9]{10}"?;' $(IOS_PBX) 2>/dev/null | sed -E 's/.* = "?([A-Z0-9]+)"?;/\1/'); \
	[ -n "$$bundle" ] || bundle=$$(grep -m1 -oE 'PRODUCT_BUNDLE_IDENTIFIER = "?[A-Za-z0-9.-]+"?;' $(IOS_PBX) 2>/dev/null | sed -E 's/.* = "?([^";]+)"?;/\1/'); \
	[ -n "$$bundle" ] || bundle="$(GMAIL_GTD_BUNDLE_ID)"; \
	if [ -z "$$team" ]; then \
		echo "No signing team yet. Run make ios-device, choose your team in the target's Signing & Capabilities tab,"; \
		echo "then run make ios-signing again (or pass TEAM=XXXXXXXXXX)."; exit 1; fi; \
	printf 'GMAIL_GTD_TEAM := %s\nGMAIL_GTD_BUNDLE_ID := %s\n' "$$team" "$$bundle" > $(SIGNING); \
	echo "Saved to $(SIGNING):"; cat $(SIGNING)
	@$(MAKE) --no-print-directory ios-project

IOS_ICON := iOS/GmailGTD/Assets.xcassets/AppIcon.appiconset/AppIcon.png

ios-icon: ## Redraw the iPhone app icon from the Mac app's icon code (AppIcon.swift)
	swift build --product GmailGTD
	"$$(swift build --show-bin-path)/GmailGTD" --export-ios-icon $(IOS_ICON)

ios-project: ## Generate iOS/GmailGTDiOS.xcodeproj with your saved signing (needs `brew install xcodegen`)
	cd iOS && xcodegen generate --quiet

ios-sim: ios-project ## Build the iPhone app and run it in the simulator on the demo mailbox (IOS_SIM="iPhone 17 Pro")
	xcodebuild -project iOS/GmailGTDiOS.xcodeproj -scheme GmailGTDiOS -destination 'platform=iOS Simulator,name=$(IOS_SIM)' -derivedDataPath $(IOS_DD) -quiet build
	xcrun simctl boot "$(IOS_SIM)" 2>/dev/null || true
	open -b com.apple.iphonesimulator 2>/dev/null || echo "Simulator app not found: the app still runs; take screenshots with xcrun simctl io booted screenshot"
	xcrun simctl install "$(IOS_SIM)" "$(IOS_DD)/Build/Products/Debug-iphonesimulator/Gmail GTD.app"
	xcrun simctl launch "$(IOS_SIM)" $(GMAIL_GTD_BUNDLE_ID) --demo

ios-device: ios-project ## Open the iOS project in Xcode to run on your iPhone (save your team first: make ios-signing TEAM=…)
	open iOS/GmailGTDiOS.xcodeproj

clean: ## Remove build outputs (build/ and .build/)
	rm -rf build .build

help: ## List the targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'
