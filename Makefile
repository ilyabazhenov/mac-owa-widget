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

.PHONY: build bundle release-package run kill clean watch logs help

## Compile Swift sources
build:
	swift build 2>&1

## Assemble .app bundle from compiled binary
bundle: build
	@mkdir -p $(APP_PATH)/Contents/MacOS
	@mkdir -p $(APP_PATH)/Contents/Resources
	@rm -rf "$(APP_PATH)/$(APP_NAME)_$(APP_NAME).bundle"
	cp $(BINARY) $(APP_PATH)/Contents/MacOS/$(APP_NAME)
	cp $(INFO_PLIST) $(APP_PATH)/Contents/
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(APP_BUNDLE_ID)" "$(APP_PATH)/Contents/Info.plist"
	@if [ -d "$(RESOURCE_BUNDLE)" ]; then cp -R "$(RESOURCE_BUNDLE)" $(APP_PATH)/Contents/Resources/; fi
	@if [ -d "$(SRC_DIR)/Resources" ]; then cp -R $(SRC_DIR)/Resources/*.lproj $(APP_PATH)/Contents/Resources/; fi
	@printf 'APPL????' > $(APP_PATH)/Contents/PkgInfo
	codesign --sign "$(CODE_SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) --force $(APP_PATH)
	@echo "✓ Bundle ready: $(APP_PATH)"

## Build .app and package release zip
release-package: bundle
	@test -f $(VERSION_FILE) || (echo "Missing $(VERSION_FILE)" && exit 1)
	@test -f $(RELEASE_NOTES_FILE) || (echo "Missing $(RELEASE_NOTES_FILE)" && exit 1)
	@VERSION=$$(tr -d '[:space:]' < $(VERSION_FILE)); \
	NOTES=$$(tr -d '[:space:]' < $(RELEASE_NOTES_FILE)); \
	[ -n "$$VERSION" ] || (echo "$(VERSION_FILE) is empty" && exit 1); \
	[ -n "$$NOTES" ] || (echo "$(RELEASE_NOTES_FILE) is empty" && exit 1); \
	mkdir -p $(DIST_DIR); \
	ARCHIVE="$(DIST_DIR)/$(APP_NAME)-v$$VERSION-macos.zip"; \
	rm -f "$$ARCHIVE"; \
	ditto -c -k --sequesterRsrc --keepParent $(APP_PATH) "$$ARCHIVE"; \
	echo "✓ Release package ready: $$ARCHIVE"

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
	@fswatch -o \
	         --event Updated \
	         --event Created \
	         --event Removed \
	         --event Renamed \
	         -e ".*\.o$$" \
	         -e ".*\.d$$" \
	         -e ".*\.swp$$" \
	         $(SRC_DIR)/ | xargs -n1 -I{} sh -c \
	    'echo "\n──── change detected → rebuilding ────" && make run APP_BUNDLE_ID="$(APP_BUNDLE_ID_DEV)"'

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
