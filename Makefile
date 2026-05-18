APP_NAME    := OWAWidget
APP_PATH    := .build/$(APP_NAME).app
SRC_DIR     := OWAWidget
BIN_DIR     := $(shell swift build --show-bin-path)
BINARY      := $(BIN_DIR)/$(APP_NAME)
RESOURCE_BUNDLE := $(BIN_DIR)/$(APP_NAME)_$(APP_NAME).bundle
ENTITLEMENTS := $(SRC_DIR)/OWAWidget-dev.entitlements
INFO_PLIST  := $(SRC_DIR)/Info.plist
CODE_SIGN_IDENTITY ?= -
APP_BUNDLE_ID_BASE := com.owawidget.MacOwaWidget
APP_BUNDLE_ID_DEV := $(APP_BUNDLE_ID_BASE).dev
APP_BUNDLE_ID ?= $(APP_BUNDLE_ID_BASE)
VERSION_FILE := VERSION
RELEASE_NOTES_FILE := RELEASE_NOTES.md
DIST_DIR := dist
WATCH_DEBOUNCE ?= 2

# Sparkle artifacts produced by `swift package resolve` for the SPM binaryTarget.
SPARKLE_ARTIFACTS_DIR := .build/artifacts/sparkle/Sparkle
SPARKLE_FRAMEWORK     := $(SPARKLE_ARTIFACTS_DIR)/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework

.PHONY: build bundle validate-release-notes release-package run kill clean watch logs help

## Validate latest release notes structure (RU/EN)
validate-release-notes:
	@./scripts/validate_release_notes.sh $(RELEASE_NOTES_FILE)

## Compile Swift sources
build:
	swift build 2>&1

## Assemble .app bundle from compiled binary
bundle: build
	@mkdir -p $(APP_PATH)/Contents/MacOS
	@mkdir -p $(APP_PATH)/Contents/Resources
	@mkdir -p $(APP_PATH)/Contents/Frameworks
	@rm -rf "$(APP_PATH)/$(APP_NAME)_$(APP_NAME).bundle"
	cp $(BINARY) $(APP_PATH)/Contents/MacOS/$(APP_NAME)
	cp $(INFO_PLIST) $(APP_PATH)/Contents/
	@VERSION=$$(tr -d '[:space:]' < "$(VERSION_FILE)"); \
	[ -n "$$VERSION" ] || (echo "$(VERSION_FILE) is empty" && exit 1); \
	BUILD_NUMBER=$$(git rev-list --count HEAD 2>/dev/null || echo "1"); \
	case "$$BUILD_NUMBER" in \
	  ''|*[!0-9]*) BUILD_NUMBER=1 ;; \
	esac; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$VERSION" "$(APP_PATH)/Contents/Info.plist" >/dev/null 2>&1 || \
	  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $$VERSION" "$(APP_PATH)/Contents/Info.plist"; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$BUILD_NUMBER" "$(APP_PATH)/Contents/Info.plist" >/dev/null 2>&1 || \
	  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $$BUILD_NUMBER" "$(APP_PATH)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(APP_BUNDLE_ID)" "$(APP_PATH)/Contents/Info.plist"
	@if [ -d "$(RESOURCE_BUNDLE)" ]; then cp -R "$(RESOURCE_BUNDLE)" $(APP_PATH)/Contents/Resources/; fi
	@if [ -d "$(SRC_DIR)/Resources" ]; then cp -R $(SRC_DIR)/Resources/*.lproj $(APP_PATH)/Contents/Resources/; fi
	@if [ -f "$(SRC_DIR)/Resources/AppIcon.icns" ]; then cp "$(SRC_DIR)/Resources/AppIcon.icns" "$(APP_PATH)/Contents/Resources/AppIcon.icns"; fi
	@printf 'APPL????' > $(APP_PATH)/Contents/PkgInfo
	@# Embed Sparkle.framework so the auto-updater works at runtime.
	@if [ ! -d "$(SPARKLE_FRAMEWORK)" ]; then \
	  echo "Sparkle.framework not found at $(SPARKLE_FRAMEWORK)."; \
	  echo "Run 'swift package resolve' once to download Sparkle's binary artifact."; \
	  exit 1; \
	fi
	@rm -rf "$(APP_PATH)/Contents/Frameworks/Sparkle.framework"
	@ditto "$(SPARKLE_FRAMEWORK)" "$(APP_PATH)/Contents/Frameworks/Sparkle.framework"
	@# Sign nested helpers + framework first, then the app, all with the same identity.
	@# Note: hardened runtime (--options runtime) is intentionally NOT used here.
	@# With ad-hoc identities (CODE_SIGN_IDENTITY=-) hardened runtime enables
	@# library validation, which then refuses to load Sparkle.framework because
	@# its embedded ad-hoc signature has no Team ID matching the host process.
	@codesign --sign "$(CODE_SIGN_IDENTITY)" --force --deep \
	  "$(APP_PATH)/Contents/Frameworks/Sparkle.framework"
	codesign --sign "$(CODE_SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) --force --deep $(APP_PATH)
	@echo "✓ Bundle ready: $(APP_PATH)"

## Build .app and package release zip + appcast.xml.
## Internally delegates to scripts/package_release.sh which:
##   1) builds the bundle (re-invokes this Makefile's bundle target),
##   2) creates the versioned zip,
##   3) EdDSA-signs it via Sparkle's sign_update,
##   4) emits dist/appcast.xml with the resulting signature/length.
release-package: validate-release-notes
	@test -f $(VERSION_FILE) || (echo "Missing $(VERSION_FILE)" && exit 1)
	@test -f $(RELEASE_NOTES_FILE) || (echo "Missing $(RELEASE_NOTES_FILE)" && exit 1)
	@bash scripts/package_release.sh

## Kill running instance
kill:
	@-pkill -x $(APP_NAME) 2>/dev/null; true

## Build, bundle and launch
run: kill
	@$(MAKE) bundle APP_BUNDLE_ID="$(APP_BUNDLE_ID_DEV)"
	open $(APP_PATH)

## Clean build artifacts
clean:
	swift package clean
	rm -rf $(APP_PATH)

## Auto-rebuild on .swift file changes (requires: brew install fswatch)
watch: run
	@which fswatch > /dev/null 2>&1 || (echo "Install: brew install fswatch" && exit 1)
	@echo "Watching $(SRC_DIR)/ for changes... (Ctrl+C to stop)"
	@set -u; \
	cleanup() { $(MAKE) --no-print-directory kill >/dev/null 2>&1 || true; }; \
	trap 'cleanup; exit 0' INT TERM; \
	trap cleanup EXIT; \
	fswatch -o \
	        --event Updated \
	        --event Created \
	        --event Removed \
	        --event Renamed \
	        -e ".*\.o$$" \
	        -e ".*\.d$$" \
	        -e ".*\.swp$$" \
	        $(SRC_DIR)/ | while IFS= read -r _; do \
	    while IFS= read -r -t $(WATCH_DEBOUNCE) _; do :; done; \
	    echo "\n──── change detected → rebuilding ────"; \
	    if $(MAKE) --no-print-directory run APP_BUNDLE_ID="$(APP_BUNDLE_ID_DEV)"; then \
	        echo "✓ Rebuild succeeded. Watching for next change..."; \
	    else \
	        echo "✗ Rebuild failed. Fix the error and save again to retry."; \
	    fi; \
	done

## Show recent diagnostic logs
logs:
	/usr/bin/log show --info --style compact --last 20m --predicate 'subsystem == "com.owawidget" && (category == "CalendarService" || category == "OWACalendarProvider" || category == "OWAClient")'

help:
	@echo "make build   — compile Swift sources"
	@echo "make release-package — build and create release zip from VERSION"
	@echo "make run     — build, bundle and launch"
	@echo "make watch   — auto-rebuild on file changes"
	@echo "make logs    — show recent diagnostic logs"
	@echo "make clean   — remove build artifacts"
	@echo "make kill    — stop running instance"
	@echo "Local dev bundle id: $(APP_BUNDLE_ID_DEV)"
	@echo "Release bundle id: $(APP_BUNDLE_ID_BASE)"
	@echo "make run CODE_SIGN_IDENTITY='Apple Development: Name (TEAMID)' — launch with stable signing identity"
