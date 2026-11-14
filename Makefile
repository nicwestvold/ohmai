.PHONY: project build test clean

project:
	xcodegen generate

build: project
	xcodebuild -project ohmai.xcodeproj -scheme ohmai -configuration Debug build

test:
	cd Packages/OhmaiCore && swift test

clean:
	rm -rf ohmai.xcodeproj Packages/OhmaiCore/.build build
