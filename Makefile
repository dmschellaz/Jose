export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
TEAM ?= $(shell cat .team 2>/dev/null)
APP := build/Build/Products/Debug/Redline.app

ifeq ($(strip $(TEAM)),)
SIGN_FLAGS := CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual
else
SIGN_FLAGS := DEVELOPMENT_TEAM=$(TEAM)
endif

.PHONY: test project app run clean

test:
	cd Packages/RedlineCore && swift test

project:
	xcodegen generate

app: project
	@if [ -z "$(strip $(TEAM))" ]; then echo "No .team file: building ad-hoc signed; macOS will re-ask for permissions after each rebuild"; fi
	xcodebuild -project Redline.xcodeproj -scheme Redline -configuration Debug \
	  -derivedDataPath build $(SIGN_FLAGS) -quiet build

# Launch through LaunchServices so macOS attributes permissions to Redline, not Terminal.
run: app
	-pkill -x Redline
	open $(APP)

clean:
	rm -rf build Redline.xcodeproj Packages/RedlineCore/.build
