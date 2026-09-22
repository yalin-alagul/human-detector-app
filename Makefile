# Human Detector — convenience targets
#
#   make test     run the unit tests (SwiftPM)
#   make xctest   run the same tests through Xcode (⌘U equivalent)
#   make app      build the macOS app
#   make run      build, refresh build/Human Detector.app, and open it
#   make models   export the CoreML models (needs the Python venv)
#   make hooks    install the pre-push test gate in this clone
#   make ci       run exactly what CI runs

DERIVED := build/DerivedData
APP_NAME := Human Detector.app
APP := $(DERIVED)/Build/Products/Debug/$(APP_NAME)
STAGED := build/$(APP_NAME)

.PHONY: test xctest app run models cli hooks ci clean

test:
	swift test

xctest:
	xcodebuild -project HumanDetector.xcodeproj -scheme HumanDetector \
		-configuration Debug -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO test

app:
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

# Make every push in this clone run the tests first.
hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-push
	@echo "pre-push test gate installed"

# The same checks the GitHub Actions workflow runs.
ci: test app

clean:
	rm -rf .build build
