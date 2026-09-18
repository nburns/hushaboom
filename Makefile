-include .env
export

BUILD_DIR     := .build
IOS_SCHEME    := Hushaboom-iOS
MAC_SCHEME    := Hushaboom-macOS
BUNDLE_ID     := io.burns.hushaboom

IOS_DEVICE    ?= Foo
IOS_SIMULATOR ?= iPhone 17

# CFBundleVersion must increase with every upload; the date gives a value that
# always does without any state to track.
BUILD_NUMBER  ?= $(shell date +%Y.%-j.%-H)

XCPROJ        := Hushaboom.xcodeproj
SHOTS_DIR     := fastlane/screenshots/en-US
MAC_SHOTS_DIR := fastlane/screenshots-mac/en-US
ASC_KEY_PATH  ?= $(HOME)/.appstoreconnect/private_keys/AuthKey_$(ASC_KEY_ID).p8

.PHONY: help setup install-key generate build build-ios test run run-simulator run-ios \
        logs-ios archive-ios archive-mac beta beta-ios beta-mac screenshots screenshots-ios screenshots-mac create-app metadata icon clean

help:
	@echo "Targets:"
	@echo "  setup           Install tools, generate the project, check signing credentials"
	@echo "  install-key     Install the App Store Connect key: make install-key SRC=<path to .p8>"
	@echo "  generate        Regenerate $(XCPROJ) from project.yml"
	@echo "  build           Build the macOS app"
	@echo "  build-ios       Build the iOS app for the simulator"
	@echo "  test            Run the NoiseKit test suite (slow: spectral tests take ~5 min)"
	@echo "  run             Build and launch the macOS app"
	@echo "  run-simulator   Build, install, and launch on IOS_SIMULATOR (default: $(IOS_SIMULATOR))"
	@echo "  run-ios         Build, install, and launch on IOS_DEVICE (default: $(IOS_DEVICE))"
	@echo "  logs-ios        Stream app logs from IOS_DEVICE"
	@echo "  archive-ios     Release archive for iOS"
	@echo "  archive-mac     Release archive for macOS"
	@echo "  beta            Upload both platforms to TestFlight"
	@echo "  beta-ios        Upload the iOS build to TestFlight"
	@echo "  beta-mac        Upload the macOS build to TestFlight"
	@echo "  screenshots     Capture all App Store screenshots (iOS + macOS)"
	@echo "  screenshots-ios Capture iPhone and iPad screenshots (fastlane snapshot)"
	@echo "  screenshots-mac Capture macOS screenshots (XCUITest + result bundle)"
	@echo "  create-app      Create the App Store Connect record (one time)"
	@echo "  metadata        Upload metadata and screenshots (no binary)"
	@echo "  icon            Regenerate Design/icon/ from Design/generate-icon.py"
	@echo "  clean           Remove $(BUILD_DIR)"

setup:
	@command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not installed - run: brew bundle" >&2; exit 1; }
	@command -v fastlane >/dev/null 2>&1 || { echo "error: fastlane not installed - run: brew bundle" >&2; exit 1; }
	$(MAKE) generate
	@[ -f .env ] || { echo "error: .env missing - copy .env.example to .env" >&2; exit 1; }
	@[ -n "$(ASC_KEY_ID)" ] || { echo "error: ASC_KEY_ID not set in .env" >&2; exit 1; }
	@[ -n "$(ASC_ISSUER_ID)" ] || { echo "error: ASC_ISSUER_ID not set in .env" >&2; exit 1; }
	@if [ ! -f "$(ASC_KEY_PATH)" ]; then \
		echo "error: App Store Connect key not found at $(ASC_KEY_PATH)" >&2; \
		echo "Install it with: make install-key SRC=/path/to/AuthKey_$(ASC_KEY_ID).p8" >&2; \
		exit 1; \
	fi
	@echo "Setup OK - signing key $(ASC_KEY_ID), team $$(awk '/DEVELOPMENT_TEAM:/ {print $$2}' project.yml)"

install-key:
	@[ -n "$(SRC)" ] || { echo "error: pass the key path, e.g. make install-key SRC=~/Downloads/AuthKey_$(ASC_KEY_ID).p8" >&2; exit 1; }
	@[ -f "$(SRC)" ] || { echo "error: no such file: $(SRC)" >&2; exit 1; }
	mkdir -p -- "$(dir $(ASC_KEY_PATH))"
	install -m 600 -- "$(SRC)" "$(ASC_KEY_PATH)"
	@echo "Installed key at $(ASC_KEY_PATH)"

generate:
	xcodegen generate

build:
	xcodebuild build -scheme "$(MAC_SCHEME)" -destination 'platform=macOS' \
		-derivedDataPath "$(BUILD_DIR)" CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)"

build-ios:
	xcodebuild build -scheme "$(IOS_SCHEME)" -destination 'platform=iOS Simulator,name=$(IOS_SIMULATOR)' \
		-derivedDataPath "$(BUILD_DIR)" CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)"

test:
	cd NoiseKit && swift test

run: build
	-killall Hushaboom 2>/dev/null
	xattr -cr "$(CURDIR)/$(BUILD_DIR)/Build/Products/Debug/Hushaboom.app" 2>/dev/null; \
	open "$(CURDIR)/$(BUILD_DIR)/Build/Products/Debug/Hushaboom.app"

run-simulator: build-ios
	open -a Simulator
	xcrun simctl boot "$(IOS_SIMULATOR)" 2>/dev/null || true
	xcrun simctl bootstatus "$(IOS_SIMULATOR)"
	xcrun simctl terminate "$(IOS_SIMULATOR)" "$(BUNDLE_ID)" 2>/dev/null || true
	xcrun simctl install "$(IOS_SIMULATOR)" "$(CURDIR)/$(BUILD_DIR)/Build/Products/Debug-iphonesimulator/Hushaboom.app"
	xcrun simctl launch "$(IOS_SIMULATOR)" "$(BUNDLE_ID)"

run-ios:
	xcodebuild build -scheme "$(IOS_SCHEME)" -destination 'platform=iOS,name=$(IOS_DEVICE)' \
		-derivedDataPath "$(BUILD_DIR)" CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)" -allowProvisioningUpdates
	xcrun devicectl device install app --device "$(IOS_DEVICE)" "$(BUILD_DIR)/Build/Products/Debug-iphoneos/Hushaboom.app"
	xcrun devicectl device process launch --device "$(IOS_DEVICE)" --terminate-existing "$(BUNDLE_ID)"

logs-ios:
	xcrun devicectl device console --device "$(IOS_DEVICE)" 2>/dev/null || \
		log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --level debug

archive-ios:
	xcodebuild archive -scheme "$(IOS_SCHEME)" -configuration Release -destination 'generic/platform=iOS' \
		-archivePath "$(BUILD_DIR)/Hushaboom-iOS.xcarchive" \
		CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)" -allowProvisioningUpdates

archive-mac:
	xcodebuild archive -scheme "$(MAC_SCHEME)" -configuration Release -destination 'generic/platform=macOS' \
		-archivePath "$(BUILD_DIR)/Hushaboom-macOS.xcarchive" \
		CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)" -allowProvisioningUpdates

beta: beta-ios beta-mac

beta-ios:
	BUILD_NUMBER="$(BUILD_NUMBER)" fastlane ios beta

beta-mac:
	BUILD_NUMBER="$(BUILD_NUMBER)" fastlane mac beta

screenshots: screenshots-ios screenshots-mac

# Both platforms capture into a staging directory and only replace the
# previous set once the run has succeeded. Deleting up front meant a failed
# run left nothing behind.
screenshots-ios:
	rm -rf -- "$(BUILD_DIR)/ios-shots"
	fastlane ios screenshots output_directory:"$(CURDIR)/$(BUILD_DIR)/ios-shots"
	mkdir -p "$(SHOTS_DIR)"
	rm -f -- $(SHOTS_DIR)/iPhone*.png $(SHOTS_DIR)/iPad*.png
	cp -- "$(BUILD_DIR)"/ios-shots/en-US/*.png "$(SHOTS_DIR)/"
	@echo "iOS screenshots updated in $(SHOTS_DIR)"

# The macOS test runner is sandboxed, so the PNGs come out of the result
# bundle rather than being written straight to disk. A copy of the app left
# running steals the launch and the test never sees a window.
screenshots-mac:
	rm -rf -- "$(BUILD_DIR)/mac-screenshots.xcresult" "$(BUILD_DIR)/mac-shots"
	-pkill -x Hushaboom
	xcodebuild test -scheme "$(MAC_SCHEME)" -testPlan Screenshots-macOS -destination 'platform=macOS' \
		-derivedDataPath "$(BUILD_DIR)" -resultBundlePath "$(BUILD_DIR)/mac-screenshots.xcresult"
	mkdir -p "$(BUILD_DIR)/mac-shots"
	xcrun xcresulttool export attachments --path "$(BUILD_DIR)/mac-screenshots.xcresult" \
		--output-path "$(BUILD_DIR)/mac-shots"
	python3 Scripts/rename-mac-screenshots.py "$(BUILD_DIR)/mac-shots"
	mkdir -p "$(MAC_SHOTS_DIR)"
	rm -f -- $(MAC_SHOTS_DIR)/*.png
	cp -- "$(BUILD_DIR)"/mac-shots/*.png "$(MAC_SHOTS_DIR)/"
	@echo "macOS screenshots updated in $(MAC_SHOTS_DIR)"

create-app:
	fastlane create_app

metadata:
	fastlane metadata

icon:
	python3 Design/generate-icon.py

clean:
	rm -rf -- "$(BUILD_DIR)"
