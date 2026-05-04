APP_NAME    := OWAWidget
APP_PATH    := .build/$(APP_NAME).app
SRC_DIR     := OWAWidget
BINARY      := .build/debug/$(APP_NAME)
ENTITLEMENTS := $(SRC_DIR)/OWAWidget-dev.entitlements
INFO_PLIST  := $(SRC_DIR)/Info.plist
CODE_SIGN_IDENTITY ?= -

.PHONY: build bundle run kill clean watch help

## Compile Swift sources
build:
	swift build 2>&1

## Assemble .app bundle from compiled binary
bundle: build
	@mkdir -p $(APP_PATH)/Contents/MacOS
	@mkdir -p $(APP_PATH)/Contents/Resources
	cp $(BINARY) $(APP_PATH)/Contents/MacOS/$(APP_NAME)
	cp $(INFO_PLIST) $(APP_PATH)/Contents/
	@printf 'APPL????' > $(APP_PATH)/Contents/PkgInfo
	codesign --sign "$(CODE_SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) --force $(APP_PATH)
	@echo "✓ Bundle ready: $(APP_PATH)"

## Kill running instance
kill:
	@-pkill -x $(APP_NAME) 2>/dev/null; true

## Build, bundle and launch
run: kill bundle
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
	    'echo "\n──── change detected → rebuilding ────" && make run'

help:
	@echo "make build   — compile Swift sources"
	@echo "make run     — build, bundle and launch"
	@echo "make watch   — auto-rebuild on file changes"
	@echo "make clean   — remove build artifacts"
	@echo "make kill    — stop running instance"
	@echo "make run CODE_SIGN_IDENTITY='Apple Development: Name (TEAMID)' — launch with stable signing identity"
