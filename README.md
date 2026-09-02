# relora-ios

The native SwiftUI iOS client for Relora. It replaces the Expo client on
iOS; the Expo app (private `relora` monorepo) keeps serving Android.

There is no local Mac: the app is authored on Windows and built by
GitHub Actions (`.github/workflows/ci.yml`). See `CLAUDE.md` for the
invariants and the TestFlight pipeline.

The app target (`Relora/`) is a thin shell. All real code lives in the
local Swift package `ReloraKit/`, split into layers:

```
ReloraCore  <- ReloraData  <- ReloraSync
ReloraServices
ReloraDesign
ReloraFeatures  (depends on all of the above)
```

`ReloraCore` has no dependencies. `ReloraFeatures` sits on top and holds
the app's screens; nothing depends on it.

## Prerequisites (macOS only)

This app builds on macOS only — Xcode and xcodebuild do not run on
Windows, which is why this scaffold was authored without a generated
`.xcodeproj`.

- Xcode 16 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Setup

```sh
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
# fill in Config/Secrets.xcconfig with real values

make gen     # runs xcodegen generate, produces Relora.xcodeproj
open Relora.xcodeproj
# or: make build
```

## Tests

`ReloraKit`'s test targets (`ReloraCoreTests`, `ReloraDataTests`,
`ReloraSyncTests`) run through the package, not the app scheme:

```sh
make kit-test
```

Do not use `swift test` — it targets macOS and fails once iOS-only
frameworks (UIKit, AVFoundation taps, etc.) are imported. `make kit-test`
runs the package tests on the iOS simulator via the auto-created
`ReloraKit-Package` scheme.

## Config

`project.yml` is the XcodeGen manifest; `make gen` turns it into
`Relora.xcodeproj`, which is gitignored and regenerated on demand.

`Config/*.xcconfig` holds build settings per configuration.
`Config/Secrets.xcconfig` is gitignored — copy it from
`Secrets.example.xcconfig` and fill in Supabase and RevenueCat keys
before building.
