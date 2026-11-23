export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
TEAM ?= $(shell cat .team 2>/dev/null)
APP := build/Build/Products/Debug/Redline.app

ifeq ($(strip $(TEAM)),)
SIGN_FLAGS := CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual
else
SIGN_FLAGS := DEVELOPMENT_TEAM=$(TEAM) -allowProvisioningUpdates
endif

.PHONY: test project app run release clean

test:
	cd Packages/RedlineCore && swift test

project:
	xcodegen generate

app: project
	@if [ -z "$(strip $(TEAM))" ]; then echo "No .team file: building ad-hoc signed; macOS will re-ask for permissions after each rebuild"; fi
	xcodebuild -project Redline.xcodeproj -scheme Redline -configuration Debug \
	  -destination 'platform=macOS,arch=arm64' -derivedDataPath build $(SIGN_FLAGS) -quiet build

# Launch through LaunchServices so macOS attributes permissions to Redline, not Terminal.
run: app
	@pkill -x Redline || true
	@# Wait for the old instance to fully exit, or LaunchServices fails with error -600.
	@for i in $$(seq 1 50); do pgrep -x Redline >/dev/null || break; sleep 0.1; done
	open $(APP)

# A download for other Macs: universal (Apple silicon + Intel), ad-hoc signed, not notarized.
VERSION := $(shell sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
RELEASE_APP := build/release/Build/Products/Release/Redline.app

release: project
	xcodebuild -project Redline.xcodeproj -scheme Redline -configuration Release \
	  -destination 'generic/platform=macOS' -derivedDataPath build/release \
	  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
	  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual -quiet build
	rm -rf dist && mkdir -p dist/dmg
	cp -R $(RELEASE_APP) dist/dmg/
	ln -s /Applications dist/dmg/Applications
	hdiutil create -quiet -volname "Redline $(VERSION)" -srcfolder dist/dmg -ov -format UDZO dist/Redline-$(VERSION).dmg
	rm -rf dist/dmg
	@echo "Built dist/Redline-$(VERSION).dmg"

clean:
	rm -rf build dist Redline.xcodeproj Packages/RedlineCore/.build
