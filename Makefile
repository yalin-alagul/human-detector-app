# Human Detector — convenience targets
#
#   make test     run the unit tests (SwiftPM)
#   make xctest   run the same tests through Xcode (⌘U equivalent)
#   make app      build the macOS app
#   make run      build, refresh build/Human Detector.app, and open it
#   make models   export the CoreML models (needs the Python venv)
#   make hooks    install the pre-push test gate in this clone
#   make ci       run exactly what CI runs
#   make clean    delete build outputs (.build, build)
#   make uninstall remove the app and its data from this Mac (asks first)

DERIVED := build/DerivedData
APP_NAME := Human Detector.app
APP := $(DERIVED)/Build/Products/Debug/$(APP_NAME)
STAGED := build/$(APP_NAME)
PROJECT := HumanDetector.xcodeproj/project.pbxproj

# A fresh Mac points xcode-select at the Command Line Tools, which have no
# XCTest and no xcodebuild. Use the installed Xcode instead; an explicit
# DEVELOPER_DIR in the environment still wins.
XCODE_DEVELOPER := /Applications/Xcode.app/Contents/Developer
ifneq ($(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),)
ifneq ($(wildcard $(XCODE_DEVELOPER)),)
export DEVELOPER_DIR ?= $(XCODE_DEVELOPER)
endif
endif

.PHONY: test xctest app run models icon cli hooks ci clean uninstall

test:
	swift test

# The Xcode project is generated from project.yml and not checked in.
$(PROJECT): project.yml
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found — run: brew install xcodegen"; exit 1; }
	xcodegen generate
	@touch $@

xctest: $(PROJECT)
	xcodebuild -project HumanDetector.xcodeproj -scheme HumanDetector \
		-configuration Debug -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO test

app: $(PROJECT)
	xcodebuild -project HumanDetector.xcodeproj -scheme HumanDetector \
		-configuration Debug -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO build

run: app
	rm -rf "$(STAGED)"
	ditto "$(APP)" "$(STAGED)"
	codesign --force --deep --sign - "$(STAGED)" >/dev/null 2>&1 || true
	open "$(STAGED)"

cli:
	swift build -c release
	@echo "built .build/release/humandetector"

models:
	.venv/bin/python Models/export_models.py --family yolo26 --sizes n s m x --task seg

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
