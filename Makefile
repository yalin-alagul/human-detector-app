# Human Detector — convenience targets
#
#   make test      run the unit tests (SwiftPM)
#   make xctest    run the same tests through Xcode (⌘U equivalent)
#   make app       check that the macOS app builds (Debug; what CI runs)
#   make install   build a Release app into /Applications and delete the build copy
#   make run       install, then open /Applications/Human Detector.app
#   make models    export the CoreML models into Resources/Models (needs the Python venv)
#   make models-upload HF_REPO=<user>/human-detector-models
#                  upload Resources/Models to a Hugging Face repo the app downloads from
#   make hooks     install the pre-push test gate in this clone
#   make ci        run exactly what CI runs
#   make clean     delete build outputs (.build, build)
#   make uninstall remove the app and its data from this Mac (asks first)

# `.noindex` keeps Spotlight (and so Launchpad) from listing build products as
# extra copies of the app.
DERIVED := build/DerivedData.noindex
APP_NAME := Human Detector.app
DEBUG_APP := $(DERIVED)/Build/Products/Debug/$(APP_NAME)
RELEASE_APP := $(DERIVED)/Build/Products/Release/$(APP_NAME)
INSTALLED := /Applications/$(APP_NAME)
BUNDLE_ID := com.humandetector.app
PROJECT := HumanDetector.xcodeproj/project.pbxproj
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# A fresh Mac points xcode-select at the Command Line Tools, which have no
# XCTest and no xcodebuild. Use the installed Xcode instead; an explicit
# DEVELOPER_DIR in the environment still wins.
XCODE_DEVELOPER := /Applications/Xcode.app/Contents/Developer
ifneq ($(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),)
ifneq ($(wildcard $(XCODE_DEVELOPER)),)
export DEVELOPER_DIR ?= $(XCODE_DEVELOPER)
endif
endif

.PHONY: test xctest app install run models models-upload icon cli hooks ci clean uninstall

test:
	swift test

# The Xcode project is generated from project.yml and not checked in. It lists
# source files, so adding or removing one regenerates it too.
$(PROJECT): project.yml $(wildcard Sources/HumanDetectorApp/*.swift)
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found — run: brew install xcodegen"; exit 1; }
	xcodegen generate
	@touch $@

# Xcode registers every app it builds with LaunchServices, which is how build
# products showed up as extra copies of the app. Unregister and delete them,
# even when the build or tests fail: the only copy is the installed one.
define discard_build
	-@$(LSREGISTER) -u "$(1)" 2>/dev/null
	@rm -rf "$(1)"
endef

XCODEBUILD_DEBUG := xcodebuild -project HumanDetector.xcodeproj -scheme HumanDetector \
	-configuration Debug -destination 'platform=macOS' \
	-derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO

xctest: $(PROJECT)
	status=0; $(XCODEBUILD_DEBUG) test || status=$$?; \
	$(LSREGISTER) -u "$(DEBUG_APP)" 2>/dev/null; rm -rf "$(DEBUG_APP)"; exit $$status

app: $(PROJECT)
	status=0; $(XCODEBUILD_DEBUG) build || status=$$?; \
	$(LSREGISTER) -u "$(DEBUG_APP)" 2>/dev/null; rm -rf "$(DEBUG_APP)"; exit $$status

# The one copy of the app lives in /Applications. (/System/Applications is on
# the sealed, read-only system volume; nothing can be installed there.)
# Release builds every architecture by default; this app is Apple Silicon only
# (tuned for the Neural Engine, and Float16 doesn't exist on Intel), so ARCHS
# is set on the command line, where it also reaches the Swift package.
install: $(PROJECT)
	xcodebuild -project HumanDetector.xcodeproj -scheme HumanDetector \
		-configuration Release -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build
	@if pgrep -xq "Human Detector"; then \
		echo "quitting the running app"; \
		osascript -e 'quit app id "$(BUNDLE_ID)"' >/dev/null 2>&1 || pkill -x "Human Detector"; \
		sleep 1; \
	fi
	rm -rf "$(INSTALLED)"
	ditto "$(RELEASE_APP)" "$(INSTALLED)"
	codesign --force --deep --sign - "$(INSTALLED)" >/dev/null 2>&1 || true
	$(call discard_build,$(RELEASE_APP))
	$(LSREGISTER) -f "$(INSTALLED)"
	@echo "installed $(INSTALLED)"

run: install
	open "$(INSTALLED)"

cli:
	swift build -c release
	@echo "built .build/release/humandetector"

models:
	.venv/bin/python Models/export_models.py --family yolo26 --sizes n s m x --task seg

# Token from HF_TOKEN or `hf auth login`. The repo is created private if missing.
models-upload:
	@test -n "$(HF_REPO)" || { echo "usage: make models-upload HF_REPO=<user>/human-detector-models"; exit 2; }
	.venv/bin/python Models/upload_to_hf.py --repo "$(HF_REPO)"

icon:
	.venv/bin/python Scripts/generate_app_icon.py

# Make every push in this clone run the tests first.
hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-push
	@echo "pre-push test gate installed"

# The same checks the GitHub Actions workflow runs.
ci: test app

clean:
	rm -rf .build build

uninstall:
	Scripts/uninstall.sh
