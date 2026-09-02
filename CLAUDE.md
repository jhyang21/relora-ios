# CLAUDE.md — relora-ios

## What this is

The native SwiftUI iPhone client for Relora, a client relationship memory
app. It replaces the Expo client on iOS; the Expo app (in the private
`relora` monorepo) keeps serving Android. This repo is **public** so
GitHub Actions macOS minutes are free — never commit anything private.

This code was extracted from the monorepo's `apps/ios-native` on
2026-09-01 with fresh history. The backend (Supabase edge functions) and
the Android client live in the private `relora` monorepo.

The app target (`Relora/`) is a thin shell; all real code lives in the
local Swift package `ReloraKit/` (six library targets, six test targets).
`project.yml` is the XcodeGen manifest. Bundle ID `com.immform.relora`,
team `SUFCW5V2QV`, iOS 17+, Swift 6 strict concurrency.

## Invariants

- **Never commit an `.xcodeproj`.** The project is generated from
  `project.yml` via XcodeGen — run `xcodegen generate` after any checkout
  or change to `project.yml`. `.xcodeproj` is gitignored.
- **Never commit secrets.** No `.p8` keys, no match passwords, no API
  tokens, no real `Config/Secrets.xcconfig` (gitignored; CI writes it).
  This repo is public — a leaked secret here is fully public.
- Repo is authored on Windows — there is no local Xcode. Everything is
  written as plain text and verified via GitHub Actions (`macos-26`
  runners). Don't assume a local build; push and watch CI.
- **Version rule:** bump `MARKETING_VERSION` in `project.yml` before any
  TestFlight run that ships new work (patch = fixes, minor =
  user-visible new, major = Andrew decides). Build numbers are
  `github.run_number` — never set by hand, never via agvtool (xcodegen
  would clobber it).

## Build & test

```sh
xcodegen generate      # produces Relora.xcodeproj (or: make gen)
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig

# Unsigned build, matches CI:
xcodebuild build -project Relora.xcodeproj -scheme Relora \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO

# ReloraKit tests (make kit-test). Never `swift test` — it targets macOS:
cd ReloraKit && xcodebuild test -scheme ReloraKit-Package \
  -destination 'platform=iOS Simulator,name=<discovered at runtime>'
```

See `.github/workflows/ci.yml` for the exact CI commands, including
runtime simulator discovery.

## CI / TestFlight

- `ci.yml` — every PR/push: xcodegen, unsigned build, ReloraKit tests.
  Uploads `Package.resolved` as an artifact even on failure.
- TestFlight ships via fastlane `beta` (added once CI is green):
  `setup_ci` → `app_store_connect_api_key` → `match` → `build_app`
  (build number via `CURRENT_PROJECT_VERSION` xcarg) →
  `upload_to_testflight`. Dispatch-only: `gh workflow run testflight.yml`.
- Certificates/profiles live in the private repo
  `https://github.com/jhyang21/ios-certificates`, managed
  headlessly by fastlane match. **Shared with TidyNote** — a `match nuke`
  or `MATCH_PASSWORD` rotation breaks both apps' pipelines.
- Repo secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64`,
  `MATCH_PASSWORD`, `MATCH_GIT_TOKEN`, plus `IOS_SUPABASE_URL`,
  `IOS_SUPABASE_ANON_KEY`, `IOS_REVENUECAT_APPLE_API_KEY` (baked into
  `Secrets.xcconfig` by the TestFlight workflow only; CI uses
  placeholders and the app's offline mode).
- match mints profiles; it does not create App IDs. A new bundle ID must
  be registered in the developer portal first.

## History

Authored on Windows against unverified SDK surfaces
(`docs/macos-build-checklist.md` is the triage index for first-compile
errors). App Store facts: ASC app ID 6761505803; store/RevenueCat setup
docs live in the private monorepo (`docs/ios-app-store-release.md`).
