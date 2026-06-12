SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

APP_NAME := Fuse
BUNDLE := build/$(APP_NAME).app
VERSION := $(shell cat VERSION)
# The Alfred workflow is versioned and released independently of the app.
WF_VERSION := $(shell cat alfred/VERSION)
CONFIG := release

# ARCHS=universal -> build a fat binary for arm64 + x86_64.
ifeq ($(ARCHS),universal)
ARCH_FLAGS := --arch arm64 --arch x86_64
else
ARCH_FLAGS :=
endif

SWIFT_BUILD := swift build -c $(CONFIG) $(ARCH_FLAGS)

.PHONY: build bundle dmg install run alfred clean

build:
	$(SWIFT_BUILD)

bundle: build
	@BIN_PATH="$$($(SWIFT_BUILD) --show-bin-path)"; \
	rm -rf "$(BUNDLE)"; \
	mkdir -p "$(BUNDLE)/Contents/MacOS"; \
	mkdir -p "$(BUNDLE)/Contents/Resources"; \
	cp "$$BIN_PATH/$(APP_NAME)" "$(BUNDLE)/Contents/MacOS/$(APP_NAME)"; \
	sed "s/__VERSION__/$(VERSION)/g" Resources/Info.plist > "$(BUNDLE)/Contents/Info.plist"; \
	bash scripts/make_icns.sh assets/icon.png "$(BUNDLE)/Contents/Resources/AppIcon.icns"; \
	cp Resources/Fuse.sdef "$(BUNDLE)/Contents/Resources/Fuse.sdef"; \
	codesign --force --deep -s - "$(BUNDLE)"; \
	echo "bundle: assembled $(BUNDLE) (version $(VERSION))"

dmg: bundle
	bash scripts/make_dmg.sh "$(BUNDLE)" "build/$(APP_NAME)-$(VERSION).dmg"

install: bundle
	@pkill -x "$(APP_NAME)" 2>/dev/null || true; \
	rm -rf "/Applications/$(APP_NAME).app"; \
	ditto "$(BUNDLE)" "/Applications/$(APP_NAME).app"; \
	echo "install: installed /Applications/$(APP_NAME).app"

run: bundle
	open "$(BUNDLE)"

alfred:
	@mkdir -p build; \
	OUT="build/$(APP_NAME)-Workflow-$(WF_VERSION).alfredworkflow"; \
	rm -f "$$OUT"; \
	(cd alfred && zip -q -r -X "../$$OUT" . -x '.*' -x 'VERSION' -x 'CHANGELOG.md'); \
	echo "alfred: packaged $$OUT"

clean:
	rm -rf .build build
