SHELL := /bin/bash
APP := PDFQuickFix
SCHEME := PDFQuickFix
DERIVED := build
PROJECT := $(APP).xcodeproj
USER ?= $(shell id -un)
export USER

.PHONY: bootstrap generate build run clean dmg debug release

bootstrap:
	brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
	@echo "✅ XcodeGen ready"

generate:
	xcodegen generate

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) build | xcpretty || true
	@echo "✅ Build done"
	@ls -1 $(DERIVED)/Build/Products/Release/$(APP).app >/dev/null && echo "Artifact: $(DERIVED)/Build/Products/Release/$(APP).app"

debug: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) build | xcpretty || true
	open $(DERIVED)/Build/Products/Debug/$(APP).app || true

run:
	open $(DERIVED)/Build/Products/Release/$(APP).app

clean:
	rm -rf $(DERIVED) $(PROJECT)

dmg: build
	which create-dmg >/dev/null 2>&1 || (echo "Install create-dmg: brew install create-dmg" && exit 1)
	mkdir -p dist
	rm -f dist/$(APP).dmg
	create-dmg --volname "$(APP)" --window-size 500 300 --icon-size 100 --app-drop-link 380 120 dist/$(APP).dmg $(DERIVED)/Build/Products/Release/$(APP).app
	@echo "✅ DMG: dist/$(APP).dmg"

release: dmg
	@echo "Tag and upload with GitHub Releases or CI."
