# First macOS build — verification checklist

Everything under `apps/ios-native` was authored on Windows with no Swift
toolchain: **nothing has compiled or run yet.** This file collects the
spots each milestone flagged as most likely to need correction on the
first real build. Work top to bottom.

## 0. Get it building

```sh
cd apps/ios-native
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig  # fill in
make gen && make build
make kit-test
```

Fix compile errors package-by-package in dependency order:
ReloraCore → ReloraData → ReloraSync → ReloraServices → ReloraDesign →
ReloraFeatures → app target.

## 1. supabase-swift API drift (ReloraServices)

`IdentitySupabaseBackend.swift` carries an UNVERIFIED banner listing the
`AuthClient` members most likely to have moved, roughly most-to-least
likely. Reconcile against the version `Package.resolved` pins.
Keep the `.lowercased()` on the user id — see docs/milestone-notes.md.

## 2. M5 flags (UI shell), highest risk first

1. `SystemContactPicker` — presented from a host UIViewController inside
   the representable (CNContactPickerViewController is a remote view
   controller). Check present/return/dismiss, and that
   `MainActor.assumeIsolated` in the delegate methods compiles under
   Swift 6.
2. `CNContactStore.requestAccess(for:)` async spelling;
   `CNAuthorizationStatus.limited` behind `#available(iOS 18.0, *)`.
3. `PhoneContactStore.map` — `isKeyAvailable` guards; exercise with a
   picked contact, not just a fetched one (unfetched keys throw ObjC
   exceptions no `try` catches).
4. `AppDatabase.observe` — GRDB 7 `ValueObservation...start(in:scheduling:onError:onChange:)`
   spelling; `AsyncStream` + `continuation.onTermination` captures under
   Swift 6.
5. `nonisolated(unsafe)` on NWPathMonitor; `OSAllocatedUnfairLock` in
   NetworkMonitor and SyncIdentityBox.
6. `@Bindable var model = model` inside `body` (HomeView,
   ContactDetailView, RootView).
7. `.searchable` + `List` + `.safeAreaInset(edge: .bottom)` together —
   record button must not cover the last row; toast clearance constant
   verified on device.
8. `ContentUnavailableView.search(text:)` availability and the
   three-closure init form.
9. `Date.FormatStyle` chaining in RelativeTime (conditional `.year()`).
10. `ToolbarItem(placement: .status)` in ContactImportView.
11. `$(SUPABASE_URL)` xcconfig → Info.plist substitution — xcconfig
    escapes `//`; confirm the value that lands in `Bundle.main`.
12. Eyeball the four `ReloraShadow` tiers against the RN build (note in
    Shape.swift).

## 3. M6 flags (voice)

1. `VoiceCaptureReviewSection.swift:98` — `if case .some(.new) = model.selection`;
   an unlabelled case pattern will not match through an `Optional`.
2. `VoiceCaptureViewModel` — `if case VoiceSaveError.noReviewItems = error`
   matching an enum case against `any Error`.
3. `VoiceCaptureViewModel.beginCapture` — three `Task {}` loops over
   `AsyncStream`s assigning to `@ObservationIgnored` state under strict
   concurrency.
4. `VoiceCaptureEnvironment` is deliberately not `Sendable` (it holds a
   `@MainActor () -> Bool`); confirm no diagnostic at the `RootView` /
   `AppBootstrap` boundary.
5. `meter.tick(...)` mutates an `@Observable` stored struct property —
   relies on the Observation macro's generated `_modify` accessor.
6. `VoiceCaptureComposerView.swift:45` — `@Bindable var model = model`
   shadowing the `@State` property inside `body`.
7. `VoiceContactPickerSheet.withSearch(_:)` — conditional `.searchable`
   returning `_ConditionalContent`, with `.listStyle`, `.safeAreaInset`
   and `.toolbar` applied outside it.
8. `.presentationDetents([.medium, .large], selection: $detent)` driven by
   `withReloraAnimation(.gentle)` on the `.draft` stage change — confirm
   it animates rather than snapping.
9. `.accessibilityAddTraits(cond ? [.isButton, .isSelected] : .isButton)`
   — ternary with an OptionSet array literal on one branch only.
10. `TextField(_:text:axis: .vertical)` + `.lineLimit(2...8)` inside a
    `ScrollView` whose bottom `safeAreaInset` is the save bar, plus
    `.scrollDismissesKeyboard(.interactively)`.
11. `Toggle` bound to a get/set `Binding` whose setter ignores its
    argument and calls `toggleKeep` — check for a double-toggle.
12. `DisclosureGroup(isExpanded:)` inside `ReloraCard` rather than a `List`.
13. `#expect(throws: VoiceSaveError.noReviewItems) { ... }` where the
    closure passes `&ids`.
14. `ReloraServicesTests` carries a second `URLProtocol` subclass beside
    `MockURLProtocol`; the new suite is `@Suite(.serialized)` — confirm no
    cross-registration between the two.
15. `Duration` arithmetic in `VoiceMeter.tick`, and the `.seconds(120)`
    inner budget in the pipeline tests that keeps the per-call backstop
    from firing before the shared clock.

## 4. M7 flags (realtime + replay)

1. `RealtimeVoiceTranscriptionPipeline.beginLiveSession` — the
   `AsyncStream` relay (one `events()` stream forwarded into a second via
   `AsyncStream.makeStream` inside a background `Task`, inspecting
   `.error` on the way through). Two consumers of one relayed stream is
   new to this codebase; check for a stuck relay `Task` when the composer
   tears down mid-capture.
2. Live-session teardown — `cancelLiveSession()` runs from
   `VoiceCaptureViewModel.discard()` and at the top of `beginCapture()`.
   Verify with Instruments/Console that discarding mid-realtime-capture
   actually closes the WebSocket (RN parity: `cancel()` closes the
   client).
3. `LiveSessionState.take()` consumes — `process()` and
   `cancelLiveSession()` are the only callers; a second `process()` sees
   empty state and silently falls back to batch (pinned by test).
4. `environment.pipeline as? any LiveTranscribingVoicePipeline` — if the
   `AppBootstrap` swap is missing, this silently no-ops to batch. That is
   the intended failure mode, but confirm the swap landed (it goes in
   after M8, which owns the file).
5. `AudioReplayPlayer` — `PlaybackDelegateBridge` (`NSObject` +
   `AVAudioPlayerDelegate`, weak owner) mirrors `OpenSignal`; confirm the
   delegate callback thread assumption holds.
6. Replay vs. recording session race — each replay control owns its own
   `AudioSessionController`, all wrapping the shared `AVAudioSession`.
   A stray `deactivate()` while the recorder's engine runs fails with
   `AVAudioSessionErrorCodeIsBusy` (swallowed — fine), but "Record again
   while replay is playing" can land the replay pill's `.onDisappear`
   deactivate between the recorder's `activate()` and engine start.
   Device-check that path: worst case is a start failure with Retry.
7. Replay after relaunch or app update — recordings live in
   `temporaryDirectory` and `audio_local_uri` stores the absolute
   `file://` URL, so the OS purging tmp or an app update changing the
   container UUID kills replay. RN stores expo's cache URI the same way
   (verified — parity, not a defect). Confirm the dead-file case lands on
   the disabled "Could not play audio" pill, not a crash.
8. `ContactDetailView` memory rows — `ContactItemRow` + replay pill share
   one `VStack` so `.swipeDelete` swipes the whole row; check swipe
   hit-testing on the taller row.
9. `RealtimeVoiceTranscriptionPipelineTests.processFallsBackWhenExtractionThrows`
   exercises the empty-transcript branch, not extraction-throws (no seam
   to feed `finish()` a transcript without a live socket; its docstring
   says so). Don't mistake it for real coverage of that branch.

## 5. M8 flags (reminders + notifications)

1. `RestorableReminder`'s explicit `public init` in `ContactItemStore.swift`
   — the change that lets `RemindersViewModel.undoComplete()` compile across
   the module boundary. A wrong signature is a hard compile error; the
   struct's fields are the source of truth.
2. The whole `UserNotifications` surface in `SystemNotificationCenter` —
   `UNCalendarNotificationTrigger` from `Calendar.current.dateComponents`,
   `notificationSettings().authorizationStatus` mapping, async
   `requestAuthorization(options:)`, `center.add(request)` — authored
   against docs, never compiled.
3. Notification identifiers are client-minted `ReloraID.new()` values —
   confirm `UNNotificationRequest(identifier:)` accepts them (no length or
   character constraint hit).
4. `AppBootstrap.init` builds `router` and `notificationDelegate` as
   locals before the assignment block — m8's original draft referenced the
   stored property from the tap closure, which is an implicit `self`
   capture before phase-1 init completes (a definite-initialization
   error); fixed in review with the local-first pattern. If a later edit
   reintroduces a bare stored-property read inside a closure in `init`,
   that is the same bug.
5. `start()`'s `onIdentityApplied` composition is guarded by
   `if let syncOnIdentityApplied` — it silently skips reconciliation if
   `SyncOrchestrator.observeIdentity` ever stops setting the hook.
6. Fire-and-forget cancel Tasks in `RemindersViewModel.complete()`/
   `delete()` and the voice-saved reconciliation trigger in `RootView` —
   deliberate (RN parity; see milestone-notes "M8 outcomes"), untestable
   deterministically. Verify by device trace: complete a reminder, check
   the pending notification disappears.
7. `SystemNotificationCenter` is `@unchecked Sendable` over
   `UNUserNotificationCenter.current()` (documented thread-safe; the
   compiler can't see it).
8. Overlapping reconciler passes — the voice-saved trigger is
   fire-and-forget, so two rapid saves can run two passes concurrently.
   The pending-before-rows ordering in `NotificationReconciler` is what
   makes that safe; do not reorder those two reads.
9. ~~**Notifications cannot fire yet**~~ — closed by M8b: the
   add-reminder save action now primes and calls `requestAuthorization`
   via `ReminderNotificationPrimingCoordinator.respondAllow`.

## 5b. M8b flags (add-reminder + priming)

1. `NotificationScheduler.mint` deliberately has no permission check:
   when authorization is denied, `UNUserNotificationCenter.add` is
   expected to throw, mint returns nil, and the row is written with a
   NULL `notification_id` the reconciler heals after a later grant.
   **Verify on device that `add(_:)` actually throws when denied** — if
   it silently succeeds instead, denied-state saves would carry ids for
   notifications that never fire and the reconciler would never repair
   them.
2. The priming sheet is a local `.sheet` nested inside the router's
   `.addReminder` sheet (`AddReminderView`). Nested sheet presentation
   is precedented (`VoiceContactPickerSheet`), but check the pre-prompt
   actually appears above the form and that dismissing it does not
   dismiss the form.
3. `ReminderPrimingSession.primedThisSession` — `@MainActor` enum with a
   static mutable var; confirm no strict-concurrency diagnostic.
4. `DatePicker(selection:in: Date()..., ...)` — a `PartialRangeFrom`
   lower bound evaluated at each body render; confirm it compiles and
   doesn't fight the picker when the selected time drifts behind now.
5. `AddReminderView`'s contact-name footer reads
   `model.contactName` passed through the router — display-only, but
   confirm the fallback (`?? ""`) never renders an empty "For ." footer
   for a just-deleted contact.
6. On a grant, `respondAllow` runs a full reconciliation pass
   (`trigger: .permissionGranted`) before the suspended save resumes —
   RN's exact moment. The pass is awaited on the MainActor-hopping
   path; watch for UI stall if the user has thousands of reminders
   (rows are capped at 10000 by `listFullByUser`).

## 5c. M9 flags (billing)

1. **The whole RevenueCat 5.x surface in `RevenueCatPurchasesAdapter` is
   unverified** — the file carries its own ⚠️ banner listing every
   assumed member, most-to-least likely to have drifted. Reconcile
   against what `Package.resolved` pins, first thing.
2. `async let infoResult: PurchasesCustomerInfo? = try? purchases.customerInfo()`
   in `BillingService.handleIdentityChange` — `try?` inside an
   `async let` initializer; confirm the spelling compiles.
3. First-ever `configure(apiKey:)` runs without an `appUserID`, then
   `logIn` aliases — RN passes the user id at configure instead. The
   split is SDK-supported; the cost is one anonymous RevenueCat
   customer + an alias event on the very first account configure per
   install. Confirm dashboard noise is acceptable; on relaunch the SDK
   resumes its cached user, so this does not repeat.
4. PostgREST `HEAD` + `Prefer: count=exact` against live Supabase — the
   `Content-Range` parse handles `*/N` and `N-M/TOTAL`; anything else
   throws and falls back to the local ledger. Verify the real header.
5. Swift 6 strict concurrency across `@MainActor @Observable
   BillingService: Sendable`, the fire-and-forget billing `Task`s in
   `AppBootstrap`, and `RevenueCatVoiceAccess`'s
   `Task.detached` ledger reads.
6. `MockURLProtocol` static state is now shared by `EdgeFunctionsTests`
   and `ServerUsageQueryTests` (pre-existing pattern, neither suite
   serialized) — if the Services test target ever flakes in parallel,
   look here.
7. **Offline launch as a paid user**: the RC SDK's own customer-info
   cache is what keeps a Pro user Pro when `customerInfo()` cannot
   reach the network (RN's app-storage seed was deliberately not
   ported). Airplane-mode launch → record a voice note → must not be
   gated as free.
8. Sandbox end-to-end: `Secrets.xcconfig` filled with real RevenueCat
   keys, a StoreKit configuration file for local runs, purchase +
   restore both land on `PurchaseSuccessView`, entitlement lookup keys
   match the dashboard exactly ("Relora Plus"/"Relora Pro").
9. Guest resume flow on device: choose a plan as a guest → auth gate
   sheet → create account → the pending purchase resumes off
   `.onChange(of: identity.identity)` without re-tapping.

## 5d. M10 flags (onboarding settings + set-new-password), highest risk first

1. **`RootGate.destination(identity:isBootstrapped:onboardingCompleted:)` in
   `AppRouter.swift`** — the load-bearing fix this milestone landed: an
   `.account` identity always resolves to `.home`, bypassing the
   `onboardingCompleted` check that previously stranded a signed-in user on
   onboarding after sign-out/sign-back-in. Build `RootGateTests.swift`
   first and confirm `accountAlwaysGoesHome` and
   `guestIdentityStaysInOnboardingUntilFlagged` both pass before touching
   anything else — this gates real device navigation, not just Settings.
2. `ReminderNotificationsToggle.enable`'s cancel-then-reschedule pass —
   depends on `NotificationScheduler.schedule(_:now:)` actually minting a
   fresh OS request every time it's called with a cleared
   `notificationID`, against the real `UNUserNotificationCenter`, not just
   `FakeNotificationCenter`. Device-check: toggle notifications off then
   on with several existing reminders — confirm exactly one pending OS
   notification per reminder afterward, not two.
3. `SettingsView.swift`'s `open(_:failureTitle:failureFallback:)` —
   `Environment(\.openURL)`'s completion closure wraps a `viewModel` call
   in `Task { @MainActor in ... }`; confirm `OpenURLAction`'s completion
   handler type actually accepts that under Swift 6 strict concurrency
   (unverified against docs, never compiled).
4. `SettingsViewModel.toggleReminderNotifications(_:)` /
   `toggleSaveVoiceTranscripts(_:)` are called from `Toggle(isOn:)`
   bindings inside `SettingsView`'s `Form` — confirm the `Binding`
   plumbing (get/set closures calling into an `async` view-model method
   via `Task {}`) matches the established pattern elsewhere in the app
   (`AddReminderView`) rather than fighting the toggle's own animation.
5. `SetNewPasswordView`'s `@FocusState` chaining
   (`.onSubmit { focusedField = .confirmPassword }` /
   `.onSubmit { handleSubmit() }`) — straightforward SwiftUI, low risk,
   but confirm the `SecureField` submit label transitions (`.next` →
   `.done`) render correctly since this screen has no earlier native
   analog to check against.
6. Manager-review additions: a Plus sandbox account's Settings plan row
   must read "N of 100 notes used this month" (rewritten
   `SettingsPlanCopy` Plus branch, pinned by `SettingsPlanCopyTests`);
   and an expired/already-used `relora://reset-password` link must show
   the "That reset link expired" banner inside the set-new-password
   sheet, with a swipe-dismiss clearing recovery status (the
   `onDisappear` acknowledge — check the sheet does not reappear).
7. `SettingsView`'s Contacts section deliberately does not replicate RN's
   five-state permission machine (loading/unavailable/undetermined/
   denied/granted) — it opens `.contactImport` directly and lets
   `ContactImportView`/`store.requestAccess()` own the whole permission
   flow. Device-check the first-run permission prompt still appears from
   that entry point.

## 5e. M11 flags (polish, accessibility, dark mode), highest risk first

Compile risk first, then the checks only a device can settle.

1. **`ReloraFlowLayout` in `ReloraDesign/FlowLayout.swift`** — the one new
   type this milestone adds, and the only `Layout` conformance in the
   codebase. It relies on three protocol defaults rather than writing
   them: `Cache == Void` (so there is no `makeCache`), the default
   `layoutProperties`, and the default `animatableData`. The two members
   it does write take `cache: inout Void`. If the conformance fails, it
   fails here. Build `ReloraDesignTests` first — `FlowLayoutTests` covers
   the row-breaking math (`ReloraFlowSolver`) with no SwiftUI types in
   it, so a green test target means the arithmetic is right and anything
   still red is the conformance.
2. **`ReloraDesignTests` is a new test target** (`Package.swift`, added
   between `ReloraServicesTests` and `ReloraFeaturesTests`). Confirm SPM
   picks up `Tests/ReloraDesignTests/` — the directory did not exist
   before this milestone.
3. **`dynamicTypeSize.isAccessibilitySize` in `SettingsView`** — first
   use of `@Environment(\.dynamicTypeSize)` anywhere in the app. It
   drives `actionRow`'s switch from a label-beside-button row to a
   stacked one. Also note `actionRow` lost its `@ViewBuilder` attribute
   and now returns explicitly, building its two halves as locals; if the
   opaque return type complains, that is where.
4. **`ReminderRowView` is now a `NavigationLink(value:)`**, not a
   `Button`. It pushes `AppRouter.Route.contactDetail`, which resolves
   against `RootView`'s stack-level `.navigationDestination`. Device-check
   that tapping a reminder still opens the right contact — a link whose
   destination is not registered fails silently at runtime, not at
   compile time.
5. **`RemindersView` now reads `@Environment(SyncOrchestrator.self)`** for
   its new `.refreshable`. It inherits the value from the same place
   `HomeView` does; confirm the environment is populated on the pushed
   screen and not only at the stack root, or pull-to-refresh will trap.
6. `.accessibilityLabel` on a `.labelsHidden()` segmented `Picker`
   (`ContactImportView`'s per-row disposition control) — the combination
   is legal but untested here.
7. `@ScaledMetric(relativeTo:)` added in three places
   (`OnboardingHowItWorksStepView.badgeSize`,
   `ReminderNotificationPrimingSheet.glyphSize`,
   `PurchaseSuccessView.sealSize`), following `ReloraAvatar`'s existing
   pattern.

### Device-only checks (cannot be settled on Windows)

- **Real VoiceOver.** Swipe through Home, Reminders, a contact, the voice
  composer and the paywall end to end. Listen for: no element announced
  as plain "button" with no name; no "bullet" or "checkmark" spoken (both
  were silenced this milestone — Paywall plan bullets, the two contact
  pickers, Home's context card); the onboarding progress dots announcing
  "Step 2 of 5" as one element rather than five anonymous shapes; and no
  button that renames itself mid-action (Save/Saving, Restore/Restoring,
  Create account/Creating all now keep a fixed spoken name while the
  visible text changes).
- **Actual Dynamic Type rendering** at AX3 and AX5. The specific places
  to look, because they were changed or deliberately left: `SettingsView`
  action rows must drop the button below the text (this is the reflow
  that was added — verify the threshold looks right and does not trigger
  at merely large non-accessibility sizes); `OnboardingPillButton` must
  grow taller rather than clip, and the Personalize pills must wrap
  through `ReloraFlowLayout` rather than sitting in rows of two; Home's
  reminder-bell badge and the record button's mic glyph are fixed on
  purpose and must be checked for looking wrong rather than for clipping.
- **Dark mode on an OLED device.** The palette's dark ratios were
  verified arithmetically, not visually. What arithmetic cannot answer:
  whether cards read as lifted off the near-black ground now that
  elevation is carried by surface colour rather than shadow (check
  `SetNewPasswordView`'s card, which switched to `reloraSurface` this
  milestone), and whether the coral fills bloom on OLED.
- **Reduce Motion on.** Confirm the toast still appears and disappears
  without sliding, the onboarding dots and pills snap rather than spring,
  and `VoiceLevelMeter` collapses to a single bar instead of a scrolling
  history. `VoiceLevelMeter` is the one component allowed to read the
  trait directly (its motion is content, not decoration); everything else
  goes through `reloraAnimation` and was swept to confirm it.
- **Differentiate Without Color on.** The audit found no place where
  colour is the only signal, but two are worth eyeing: overdue reminders
  (red, and the text begins with the word "Overdue") and the import
  screen's duplicate note (states "Possible duplicate" in words).

## 5f. Simplify-pass flags (pre-PR removal sweep), highest risk first

The pass removed dead code only (behavior-identical by review); these are
the removals a compiler could still disagree with, plus two flags left
for after the first green build.

1. **`ContactSearchIndex.initialize(database)` call added to
   `AppBootstrap.start()`** — the one behavior change from the pass, and
   a bug fix: it ports RN's startup `initializeSearchIndex`, which was
   never wired. Without it a sync-pull-deferred FTS rebuild throws inside
   the read-connection search path and every search LIKE-falls-back until
   the next local write. Verify it compiles (`try?` on the throwing
   `AppDatabase` overload) and, in behavior checks, that search still
   returns synced contacts right after a fresh install + first sync.
2. **`LocalVoiceAccess` deleted** (`VoiceQuotaGate.swift`) — dead since
   M9's `RevenueCatVoiceAccess`. Its `import ReloraData` went with it;
   confirm nothing else in `VoiceQuotaGate.swift` needed that import
   (`QuotaPolicy`, `BackendError`, `Duration` are Core/stdlib).
3. **`ReloraCard`'s `bordered:` parameter deleted** — no caller ever
   passed it; every card keeps the border via a direct `.reloraBorder`.
4. **`ReminderDraftError.alertTitle` deleted** — RN pairs it with a toast;
   native's inline form error uses `.message` only (deviation noted in
   the source).
5. **Two placeholder test files deleted**
   (`ReloraCoreTests.swift`, `ReloraSyncTests.swift`) — SPM discovers
   tests by directory, so both targets must still resolve and run their
   remaining suites.
5a. **`ReminderNotificationsToggleTests` fixture fixed** — the fixture
   contact now defaults to id `"c1"`, matching the reminders it backs;
   the old random default violated the enforced
   `FOREIGN KEY(contact_id, user_id)` and would have failed all five
   database-backed tests in that file. They should pass now; if any
   still throws an FK error, look at the fixture, not the toggle.
6. **Flag, untouched:** `Package.swift` gives `ReloraDesign` a dependency
   on `ReloraCore`, but no file in `Sources/ReloraDesign` imports it.
   Likely a dead edge; remove it only after the first green build proves
   nothing needs it transitively.
7. **Flag, untouched:** `VoiceLevelMeter.loudnessDescription(_:isActive:)`
   is internal (test-shaped visibility) but `ReloraDesignTests` has no
   test for it. Either add the test or tighten to `private` later.

## 6. Behavior spot-checks once it runs

- Voice-less smoke test: add a contact, edit, delete with Undo, search,
  dark mode, Dynamic Type at accessibility sizes.
- Sign-out lands on a signed-out Home, never onboarding (the RN bug this
  rebuild fixes; RootGateTests encode it, verify live too).
- A build with placeholder secrets boots into the offline app (no
  sync-failed banner).
- `make kit-test` green: ~380 tests across Core/Data/Sync/Services/
  Features as of M6, plus M10's new `Onboarding/` and `Settings/` suites
  under `ReloraFeaturesTests`.
- Voice smoke test (guest, works offline): record → stop → review opens on
  an empty draft (AUTH_REQUIRED fallback) → write a note → save → lands on
  the contact, ledger row written once.
- Realtime smoke test (signed in, online): live transcript builds while
  talking; kill the network mid-capture → capture completes via batch
  fallback with no user-visible error; discard mid-recording → socket
  closes (checklist item 4.2); replay pill plays in review and on the
  saved memory row.
- Reminders smoke test: Home bell shows the overdue badge and opens the
  screen; swipe-Done moves the row to Done's top with an Undo toast that
  restores it; swipe-Delete + Undo round-trips; tapping a row opens the
  contact.
- Add-reminder + notification smoke test (M8b): from a contact's toolbar
  menu, Add reminder → first save shows the priming sheet → Turn on
  notifications → OS dialog → grant; schedule a reminder a minute out,
  background the app, tap the banner → lands on the contact; cold-launch
  from a notification tap → same, via the queued deep-link replay. Also:
  decline the pre-prompt three times → fourth save never primes again;
  save while denied → reminder saved silently with no notification, then
  grant later via a new save's priming → the old reminder's notification
  appears (the `.permissionGranted` reconciliation pass).
- Onboarding smoke test (M10): fresh install walks Welcome → HowItWorks →
  Personalize → LetsTryIt → GetStarted; kill and relaunch mid-flow resumes
  on the same step; Skip from each of the first three steps lands on
  LetsTryIt (not GetStarted); Skip from LetsTryIt lands on GetStarted with
  copy that never claims an example is ready; running the LetsTryIt
  example through to completion seeds one contact, memory, two key
  things, and a reminder that never gets an OS notification, and
  GetStarted's copy then reads "Your example is ready".
- Settings smoke test (M10): Export data produces a share sheet with a
  `relora-export-*.json` file containing all four tables scoped to the
  signed-in user; Sync now reflects `syncStatusLabel`'s four states
  (Syncing/Synced/failed/offline); toggling reminder notifications off
  then on reschedules every live reminder with exactly one pending OS
  notification each, and never schedules the LetsTryIt tutorial reminder;
  Sign out lands on signed-out Home (see 5d.1); Delete account shows the
  confirmation dialog, calls `delete_account_data`, and lands on
  signed-out Home; Upgrade opens the paywall; the signed-out Account
  section offers create-account/sign-in via the auth gate.
- Set-new-password smoke test (M10): open `relora://reset-password` on a
  device with the app installed → the sheet appears; a password under 6
  characters or a mismatched confirm shows the matching error toast and
  does not submit; a valid 6+ character matching pair updates the
  password, shows a success toast, and dismisses back to normal signed-in
  navigation.

## 7. Fixtures to record at first build (M6 contract check)

Contract fixtures from the live edge functions (transcribe success /
402 / error envelope / dedupe) — the plan's M6 verification step.
