# Runs on macOS only. xcodegen and xcodebuild are not available on this repo's Windows dev machine.

.PHONY: gen build test kit-test clean

gen:
	xcodegen generate

build: gen
	xcodebuild -project Relora.xcodeproj -scheme Relora \
		-destination 'generic/platform=iOS Simulator' build

test:
	xcodebuild test -project Relora.xcodeproj -scheme Relora \
		-destination 'platform=iOS Simulator,name=iPhone 16'

# Runs the ReloraKit package tests on the iOS simulator. Do not use `swift test`:
# it targets macOS and breaks once iOS-only frameworks are imported.
kit-test:
	cd ReloraKit && xcodebuild test -scheme ReloraKit-Package \
		-destination 'platform=iOS Simulator,name=iPhone 16'

clean:
	rm -rf Relora.xcodeproj DerivedData
