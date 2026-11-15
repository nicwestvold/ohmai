.PHONY: project build test clean release release-check

project:
	xcodegen generate

build: project
	xcodebuild -project ohmai.xcodeproj -scheme ohmai -configuration Debug build

test:
	cd Packages/OhmaiCore && swift test

clean:
	rm -rf ohmai.xcodeproj Packages/OhmaiCore/.build build

# Signed, notarized, stapled zip in build/release/. See scripts/release.sh.
release:
	scripts/release.sh

# Same, without uploading to Apple: archive, Developer ID sign, verify.
release-check:
	scripts/release.sh --no-notarize
