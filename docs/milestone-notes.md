# Milestone notes — manager rulings and open spec items

Decisions made while reviewing M0–M4 that later milestones must honor.
Each item names the milestone that consumes it.

## Sync / notifications boundary (M8, and whoever wires sync into the app)

`SyncEngine` surfaces `pulledReminderTombstoneNotificationIDs` and does
**not** clear `reminders.notification_id` itself. This differs from RN,
which cancels notifications inline during pull — deliberate here, because
ReloraData/ReloraSync never import UserNotifications. The caller must:

1. Cancel each surfaced notification id via `UNUserNotificationCenter`.
2. Only then clear `notification_id` on those rows locally.

If step 2 runs without step 1, a ghost notification fires with no row to
back it. `NotificationReconciler.rescheduleAll()` (M8) is the safety net,
but the sync-completion path must still do both steps in order.

## Usage ledger — there is no client upload path (M6, M9)

Verified against `apps/mobile/src/features/billing/storage.ts` and
`state/localOwnership.ts`:

- **Signed-in users (anonymous or account)** never write local usage
  rows — `recordVoiceNoteProcessed` returns early. The server writes its
  own ledger row inside `transcribe_audio` (source `transcribe_audio`).
  Usage summaries come from live PostgREST `count: exact, head: true`
  queries on `voice_note_usage_events` (lifetime + current-month), with
  the local count as fallback on query failure.
- **Local guests** insert local rows (source `voice_capture_review`,
  `server_synced_at = NULL`, `INSERT OR IGNORE`) and count locally.
- **Month window** = local-time month boundaries converted to UTC
  instants (RN: `new Date(y, m, 1).toISOString()`). Port exactly.
- **Guest migration** re-owns local usage rows to the account id and
  nulls `server_synced_at`; the rows are never uploaded. They only feed
  the local fallback count. `server_synced_at` is vestigial — keep the
  column (schema parity) and the behavior, add no upload.
- `voice_note_usage_events` stays excluded from `SyncTable` (matches RN).

## Voice capture timeout (M6)

`EdgeFunctions` provides a per-call 60s budget with 15s/30s progress
marks. RN's `voiceCaptureFlow.ts` runs a **shared** 60s two-stage clock
across transcribe → extract (extract gets what transcribe left). M6 must
build that shared-clock orchestrator on top of the per-call primitive,
not call the primitive twice with fresh budgets.

## Save-path text hygiene (M6)

RN's Zod schemas `.trim()` all user-visible text on save. Every iOS save
path (voice review edits, manual add/edit) must trim before persisting.

## Error-code catalog reconciliation (M7)

`RealtimeTranscriber` carries inline `BackendError` code strings. When
M7 wires realtime into the composer, reconcile those strings into the
catalog in `ReloraCore/Backend.swift` — one catalog, no string forks.

## Identity rulings from the M3 review (M5, M10)

- **Bootstrap is lazy, matching RN.** `IdentityController.bootstrap()`
  restores a session or a stored guest, else stays `.unresolved` — it
  never mints an identity. Identity first appears when something asks:
  the tutorial seed calls `ensureLocalGuestSession()`, GetStarted calls
  `beginAnonymousSession()` (M10), and any data-creating action taken
  while `.unresolved` must call `ensureLocalGuestSession()` first (M5).
- **Routing (M5):** `.unresolved` + onboarding incomplete → Onboarding;
  `.unresolved` + onboarding complete (post-sign-out) → the signed-out
  Home, per the design direction — never back into onboarding. A Home
  rendered while `.unresolved` must not read `identity.ownerUserID`
  (it precondition-fails); show the signed-out empty state instead.
- **Stored-guest migration keys on the session's user id** (anonymous or
  account), not `syncUserID` — fixed during review to match RN.
- **`beginAnonymousSession()` is a no-op for `.account`** — guard added
  in review; calling `signInAnonymously()` over an account session would
  replace it.
- **Supabase user ids are lowercased at the boundary**
  (`SupabaseAuthBackend.map` uses `uuidString.lowercased()`) — Foundation
  renders UUIDs uppercase, which would fork local ownership scoping from
  server-spelled ids. Do not "simplify" this away.
- `IdentitySupabaseBackend.swift` carries an UNVERIFIED banner listing
  the supabase-swift API names most likely to have drifted — first
  macOS build must reconcile it against the pinned version.

## M5 outcomes later milestones consume (M6, M8)

- **M6:** `AppRouter.Sheet.voiceComposer(contactID:)` exists with a
  placeholder view in `RootView.swift` — replace the placeholder, keep
  the route. Toasts go through `ReloraToastCenter`; completion-driven
  navigation lands on `router.showNewlySavedContact(_:)`.
- **M8:** replace the `cancelNotifications: { _ in }` no-op in
  `AppBootstrap` with the real `UNUserNotificationCenter` call; step 2
  (`ReminderRepository.clearNotificationIDs`) is already wired after it
  in `SyncOrchestrator.sync`. Note `AppDatabase.observeContentChanges()`
  cannot see notification_id-only writes (the column is local-only and
  does not bump `updated_at`) — never drive rescheduling off that token.
- Contact delete confirms via alert only when the contact carries
  memories or key things — that IS RN parity
  (`contactDeleteConfirmation.ts`), not a deviation, despite the plan's
  shorthand "no confirmation dialogs".

## M6 outcomes later milestones consume (M7, M8, M9)

- **M7:** the seam is `VoiceTranscriptionPipeline` (ReloraServices). The
  realtime conformer wraps `BatchVoiceTranscriptionPipeline` for its
  fallback leg; the one line that changes is the pipeline construction in
  `AppBootstrap`. The live-transcript stream is deliberately outside the
  protocol — it reaches the composer through
  `RecordingController.setPCMFrameHandler` and
  `RealtimeTranscriber.events()`.
- **M8:** a voice-saved reminder row lands with `notification_id = NULL`
  and nothing schedules it (deliberate — the row must survive a denied
  notification permission). The scheduler must pick up newly saved voice
  reminders, not only ones created on the reminder screens.
- **M9:** `LocalVoiceAccess` (ReloraFeatures) is the interim
  `VoiceAccessProviding` conformer — plan hardcoded `.free`, counts from
  the local ledger only. M9 replaces it with the RevenueCat plan +
  server-first usage query and keeps the local count as the fallback.
  Until then a signed-in Plus/Pro subscriber is gated as free (recorded
  M6 deviation). `AppRouter.PaywallReason` carries no analytics `source`;
  M9 derives it from the reason.
- **Manager fix during review:** a mid-processing 402 now routes through
  `VoiceQuotaGate.paywallReason(forServerCode:)` — the server's body code
  (`PLUS_QUOTA_REACHED` vs `FREE_LIMIT_REACHED`) picks the wall; m6 had
  hardcoded the free limit. Test pins it.
- **Manager ruling — no offline gate on recording.** The M6 draft refused
  to record while offline; removed in review. RN has no such gate, a
  local guest's flow needs no network at all (AUTH_REQUIRED throws
  before any request), and a signed-in user's kept audio + Retry makes
  offline capture "record now, send later". Do not reintroduce it.
  `VoiceCaptureEnvironment.isOnline` stays for M7's realtime-vs-batch
  resolution.
- **Audio replay is an M7 deliverable, not an optional polish.** RN ships
  `AudioReplayButton` in two surfaces — the voice review section and
  `ContactDetailScreen` memory rows (`audio_local_uri`). The native app
  currently has no playback anywhere; M6 lands the URI on the memory row.
  M7 builds the player (one, coordinated with `AudioSessionController` —
  playback and recording must not fight over the session) and places it
  in both surfaces.
- A guest capture is charged inside the save transaction
  (`usageEvent` in `VoiceCapturePlan`), keyed on
  `usedLocalGuestFallback` — the invariant is "the server never counted
  this note", not the identity kind. Do not move the charge out of the
  transaction.

## M7 outcomes (M8 integration step, M9, and the final report)

- **AppBootstrap swap is pending, deliberately.** M8 owns
  `AppBootstrap.swift`; once M8 lands, the manager applies m7's one-line
  swap (one shared `EdgeFunctionsClient`, realtime wrapping batch). Until
  then the app runs batch-only — the composer's downcast no-ops, which is
  the designed failure mode.
- **Ruling — no realtime timer is missing.** m7 flagged
  `BackendError.realtimeTranscriptTimeout` as unused and asked where a
  realtime clock should fire. Verified against RN: the only realtime
  timer is `waitForLatestTranscript(timeoutMs = 4_000)` inside the stop
  path, and `RealtimeTranscriber.finish()` already implements exactly
  that bounded wait. The code string is RN's fallback *label*, not a
  thrown error with its own timer. The catalog constant stays as a
  defensive entry (`VoiceErrorCopy` maps it); nothing throws it. Do not
  add a shared clock to the realtime leg — RN has none.
- **Ruling — fallback re-transcribes from scratch.** RN's
  `processRealtimeCapture` discards the partial transcript and re-runs
  the file through batch. m7's implementation matches; not a gap.
- **`fallbackReason` is analytics-only in RN** and the native app has no
  analytics layer (PostHog not ported — standing item for Andrew's final
  report). Not ported, deliberate.
- **Manager fix — live-session teardown.** m7's draft never closed the
  realtime transcriber on discard: RN's `cancel()` closes the client, but
  `discard()` only cancelled the recorder, leaking the socket, the relay
  task, and the recorder's PCM handler (same on a retry re-entering
  `beginCapture`). Added `cancelLiveSession()` to
  `LiveTranscribingVoicePipeline`, implemented by closing the held
  transcriber; called from `discard()` and the top of `beginCapture()`,
  which also clears the PCM handler. Test pins that a cancelled session
  cannot be picked up by a later `process()`.
- Replay storage is ephemeral **by RN parity**: recordings live in
  `temporaryDirectory`, `audio_local_uri` stores the absolute `file://`
  string, and both die on tmp purge or app update (RN stores expo's
  cache URI the same way). A dead file degrades to the disabled replay
  pill. If Andrew wants durable replay, that is a product change (move
  to Application Support + relative path), not a porting fix.
- **Durable replay landed in 2.2.0.** `RecordingStore` (ReloraServices)
  moves a finished recording out of `temporaryDirectory` into
  Application Support, and `audio_local_uri` now stores the file name,
  not an absolute path — so a recording survives a tmp purge and an app
  update, whose container path changes. Legacy absolute `file://` rows
  still resolve, and the contact timeline shows the replay pill only
  when the store finds the file on disk.
- **A launch-time sweep landed in 2.3.0.** It removes any recording no
  live memory references, after a one-hour grace. A tombstoned memory's
  file goes at the next launch — Undo is a 4 s in-process toast and
  cannot race it. A row un-tombstoned remotely and pulled back later
  degrades to no replay pill, not a restored recording. Delete Account
  removes every recording at once. Stale `audio_local_uri` values are
  never nulled: that would dirty the row and push a local concern onto
  the server.

## M8 outcomes (M8b, M9, M10, and the final report)

- **The two-step cancel-then-clear rule is a sync-pull rule, not a local
  one.** Verified against RN: `softDeleteContactItem` clears
  `notification_id` inside the delete transaction and cancels the OS
  notification *after* commit, and the native `ContactItemStore.softDelete`
  matches it exactly. Same for `RemindersViewModel.complete()`, where the
  cancel is a fire-and-forget Task racing a synchronous clear (m8's flag
  6): the id is captured first, so the cancel always runs, and the only
  gap is a crash between the write and the cancel — which the
  reconciler's orphan cleanup now heals on the next pass. Do not
  "correct" the local paths to cancel-first; the ordering rule in "Sync /
  notifications boundary" above governs the pull path, where the row is
  gone for good and no repair pass will ever see it again.
- **Reconciler orphan cleanup is an approved superset of RN.** RN's
  repair pass only schedules missing notifications; the native one also
  cancels OS-pending notifications no live scheduled row backs. Kept
  because it heals the crash windows the fire-and-forget cancels leave.
  Manager fix during review: pending identifiers are fetched **before**
  the row snapshot, so a concurrently minted id can never look orphaned.
- **Tutorial title guard** (`NotificationReconciler.tutorialReminderTitle`)
  is a stand-in M10 must replace with a real mechanism when it builds the
  seed. Side-finding for Andrew: RN's own repair pass *would* schedule
  the tutorial reminder (future-dated, `notification_id` NULL, and
  `disableScheduling` only suppresses the write-time schedule) — a
  latent RN hole; the guard makes native stricter than RN, on purpose.
- **List-model rulings from review:** rows whose contact has no live row
  are dropped (manager fix — RN parity; the "Unknown contact" fallback
  rendered a row navigating to a dead screen). Done sorts by `updatedAt`
  descending, deviating from RN's `remind_at` — approved: marking a
  reminder done moves it to the top of Done, which is the feedback the
  gesture deserves. RN's "· dismissed/fired" meta suffix on done rows is
  dropped — approved: no code path on either platform ever writes
  `fired`, so the suffix could only ever read "· dismissed", internal
  vocabulary a user shouldn't see.
- **M8b (assigned to m8-reminders): manual add/edit reminder + priming
  wiring.** RN has `AddReminderScreen.tsx` (create/edit from
  ContactDetail) and it is the *only* trigger of the permission-priming
  flow. Native has neither, so today nothing in the app ever calls
  `requestAuthorization` — reminder rows save, and no notification ever
  fires for anyone. Not just a parity gap; a functional hole. The
  priming sheet, store and `decide()` are built and tested, waiting on
  this surface.
- `RemindersViewModel`/`RemindersView` have no tests (m8's flag 8, by
  design — the deterministic layers below them are covered). Candidate
  for a follow-up pass once the suite runs on a Mac.

## M8b outcomes (add-reminder + priming, reviewed and signed off)

The functional hole above is closed: `AddReminderView` (sheet from
ContactDetail's toolbar menu) → `AddReminderForm.validate` →
priming-if-due (save suspends behind the sheet, resumes on either
answer) → `ReminderScheduling.decide` → `NotificationScheduler.mint`
(schedule-before-write, id handed back for rollback) →
`ReminderRepository.upsert`, cancel-on-write-failure.

m8b's deviations, all approved on review:

- **No edit mode** — RN has no reminder edit screen either
  (`AddReminderScreen.tsx` is create-only; verified in source, not docs).
  `ReminderScheduling.decide` still takes `existing:` for a future edit
  path, and the view model looks it up for real rather than assuming nil.
- **Entry point is ContactDetail's toolbar menu**, not RN's
  ContactCaptureMenu — the M5 one-floating-action ruling removed that
  menu; the toolbar `Menu` is its native home.
- **No save toast** — RN parity (RN's `onSave` just `goBack()`s).
- **Gated Save button** (`canSave`) instead of RN's validate-on-press —
  native idiom; `validate` still runs at save for the future check.
- **RN's non-finite-date validation branch not ported** — a Swift `Date`
  cannot be NaN; unportable by construction.
- **`existingIsScheduled` empty-string guard** ports JS truthiness
  (`!!existing?.notification_id`), commented at the site.
- **`mint` has no permission check, on purpose** — when denied,
  `center.add` throws, mint returns nil, the row lands with a NULL id,
  and a reconciliation pass heals it after a later grant. Self-healing
  beats a pre-flight status read that can race the dialog. (Build
  checklist 5b.1: verify `add` really throws when denied.)

Manager fixes during review (both in
`ReminderNotificationPrimingCoordinator`):

- **OS-dialog deny no longer records a decline.** RN increments the
  counter only for the pre-prompt's "Not now"; a system-dialog deny
  flips the OS status to `denied`, which itself stops all future
  priming — counting it too would double-penalize. m8b's draft counted
  both.
- **Grant now runs an immediate reconciliation pass**
  (`rescheduleAll(userID:trigger:.permissionGranted)`, new `Trigger`
  case) — RN's exact behavior: reminders saved while permission was
  missing get their notifications back at the grant, not at the next
  cold launch. `respondAllow` gained a `userID:` parameter for this;
  no tests referenced the old signature.

`ReminderPrimingSession.primedThisSession` is a `@MainActor` static —
the same process-lifetime shape as RN's module-level flag, scoped to
the one file that reads it.

## M9 outcomes (billing, reviewed and signed off)

`BillingService` (RevenueCat session + entitlement snapshot + catalog),
`RevenueCatVoiceAccess` (plan from the snapshot, usage server-first with
local-ledger fallback — `LocalVoiceAccess`'s replacement), and
`PaywallView`/`AuthGateView`. Verified line-by-line against
`billingState.ts`, `purchases.ts`, `storage.ts`, `paywallContent.ts` and
`authGateContent.ts`; all copy is verbatim. The RevenueCat SDK sits
behind `PurchasesProviding`, and `RevenueCatPurchasesAdapter` is the one
file importing it (the `NotificationCenterProviding` pattern).

Integration was applied by the manager (m9 was fenced off from these
files): `AppBootstrap` builds the billing stack and swaps
`RevenueCatVoiceAccess` in; `RootView` gained a `billing:` parameter and
the real `.paywall`/`.authGate` sheets (placeholders deleted);
`ReloraApp` passes `bootstrap.billing`. Two wiring points m9's snippet
did not cover, added during integration:

- **The launch seed.** `onIdentityApplied` never fires for a
  bootstrap-restored session (the same reason `syncIdentity` is seeded
  by hand in `start()`), so without a seed a restored account would sit
  on the free snapshot all process. `start()` now fires
  `billing.handleIdentityChange(identity.identity)` after `bootstrap()`.
- Both the seed and the hook call are fire-and-forget `Task`s — RC's
  network round-trips must not delay launch, sign-in completion, or the
  notification reconciliation pass.

Manager fix: m9's `paywallCopy` folded RN's fourth `manual` reason into
the free-limit fallback, claiming their copy was identical — it is not
("Upgrade when you're ready for more" is distinct). `AppRouter.
PaywallReason` gained `.manual` and the copy branch is restored; M10's
Settings upgrade entry is its caller.

m9's deviations, all approved on review:

- **PurchaseSuccess is an in-place state swap** inside the paywall
  sheet, not a second route — matches RN's `navigation.replace`.
- **The pending auth intent lives in `@State`**, not persisted like
  RN's `pendingAuthIntent`. A user whose app dies while an
  email-confirmation link is pending must re-tap the plan. Accepted for
  v1; on the final-report list for Andrew as a known parity gap.
- **No analytics calls** — the rebuild has no analytics layer
  (standing final-report item), so RN's `track(...)`s are omitted.
- **Catalog-unavailable copy authored fresh** — RN's message there is
  dynamic error text, not one fixed string.
- **Footer drops "or Google Play"** — the native build is iOS-only.
- **`AuthGateSource.voiceCapture` is defined but unreachable** —
  `Sheet.authGate` carries no payload yet. Wiring it (payload on the
  router case + `RootView` pass-through) unlocks RN's "Sign in to
  finish this note" copy; queued for M10/M11.
- **`SignUpError.didNotOpenASession` is the confirmation-required
  signal**, caught specifically in `AuthGateView.onSignUp` — the native
  shape of RN's `status === 'confirmation_required'`.

Rulings re-confirmed: the id handed to `logIn` is lowercased at its one
source (`IdentitySupabaseBackend`), so `BillingService` correctly takes
it as given; there is still no client usage-upload path; offline
entitlements ride on the RC SDK's own cache (RN's storage seed is not
ported — both apps map a failed `customerInfo` to free, and the SDK
cache is what keeps a paid user paid offline; build-checklist item).
The soft-upsell core logic has lived in `QuotaPolicy` since M1; whether
a UI surface shows it is an M11 check, not an M9 gap.

## M10 outcomes (onboarding + settings + set-new-password) — reviewed, see "M10 manager review" below

Ports `features/onboarding/`, `features/settings/`, and
`SetNewPasswordScreen.tsx`. Behavior verified against RN source, not
docs, per standing rule. Not yet built or run — see the new M10 section
in `macos-build-checklist.md` for compile-risk flags.

- **The M9-flagged `RootGate` bug is fixed.** `RootGate.destination` now
  returns `.home` whenever `identity` is `.account`, before checking
  `onboardingCompleted` at all — closing the exact "signed-in user
  stranded on onboarding after sign-out/sign-back-in" gap the M3 review's
  routing ruling was written to prevent (see "Identity rulings from the
  M3 review" above). `RootGateTests.swift` gained
  `accountAlwaysGoesHome` / `guestIdentityStaysInOnboardingUntilFlagged`
  to pin it. This is a root-navigation change, not a Settings-scoped one
  — flagged first, both here and in the build checklist, because it
  should be built and device-verified before anything else in this
  milestone.
- **`AuthGateSource.voiceCapture` is now reachable — the M9 report's
  framing was one file off.** M9 recorded this as blocked on an edit to
  `AppRouter.swift`, which M9 did not own. It never needed one:
  `AppRouter.presentAuthGate(_:)` already accepted a context parameter.
  `RootView.swift`'s voice-capture auth-required branch now calls
  `router.presentAuthGate(AuthGateContext(action: .signIn, source: .voiceCapture))`
  directly. `AuthGateSource.voiceCapture`'s own doc comment in
  `Billing/AuthGateView.swift` still says "kept in the type... a future
  milestone can wire it through" — stale now, but `Billing/` is outside
  this milestone's edit rights, so left as a one-line finding rather than
  fixed.
- **Tutorial-reminder guard replaced, as M8 queued it.**
  `NotificationReconciler`'s stand-in `tutorialReminderTitle` guard is
  gone; the reconciler and `ReminderNotificationsToggle` (new) both key
  off the seeded reminder's own row id, stored at
  `AppSettingsKey.onboardingTutorialReminderID` and written by
  `OnboardingTutorialSeedWriter.seed` immediately after its transaction
  commits. M8's side-finding stands: RN's own repair pass has no
  equivalent guard and would schedule the tutorial reminder on a
  disable/enable cycle — native is stricter than RN here, on purpose.
- **Settings "Sync now" has no RN-equivalent "Last synced: {time}"
  label.** `SyncOrchestrator` exposes `status`/`isOnline`, no timestamp.
  Replaced with a qualitative `syncStatusLabel` (Syncing.../Synced/Sync
  failed.../Offline...) rather than inventing a client-side clock RN
  never had reason to keep. Flagged for Andrew's final report as a
  visible, deliberate copy deviation, not a bug.
- **Reminder-notifications toggle is scoped to `userID`, RN's is not.**
  RN's disable cancels every pending OS notification the device has ever
  scheduled (no `user_id` filter) and clears `notification_id` across
  every row in the local table. `ReminderRepository` has no
  "every reminder regardless of owner" read, and adding one sits outside
  ReloraData (out of this milestone's ownership), so both the cancel and
  the clear are scoped to the signed-in user's own reminders. Net effect:
  a stale notification left behind by a previously signed-out account on
  the same device is not touched by a later account's toggle. Also
  closes a gap disable/enable would otherwise open on the tutorial
  reminder (see above) — RN has no equivalent guard.
- **`NotificationScheduler.schedule(_:now:)`'s doc comment overstates
  what it checks (minor, informational, file outside this milestone's
  ownership).** It claims it schedules a reminder only when it "has no
  notification id yet"; the code never reads `notificationID` before
  minting a new request. `ReminderNotificationsToggle.enable` cancels and
  clears any reminder that already carries an id before calling
  `schedule`, specifically because of this — a caller that trusted the
  comment and skipped that pass would risk two live OS notifications for
  one reminder.
- **Settings' Contacts section does not replicate RN's five-state
  contacts-permission machine** (loading/unavailable/undetermined/
  denied/granted, each with its own copy). `ContactImportView` (M5)
  already owns the whole `CNContactStore.requestAccess` flow end-to-end
  once its sheet opens, so Settings is one entry row — "Bulk import from
  phone" — rather than a second, parallel permission-state tracker.
- **Plan copy still degrades the same way M9 recorded.**
  `SettingsViewModel` reads the real entitlement
  (`billing.subscriptionSnapshot.planID`) for which plan-copy branch and
  the "Upgrade your plan" row's visibility use, but the free-usage
  sub-copy still comes from `VoiceAccessSnapshot`, which
  `LocalVoiceAccess` hardcodes to `.free` regardless of actual plan (M6
  deviation, not new). A signed-in Plus/Pro subscriber can see free-tier
  usage phrasing alongside correct plan-gating. Same root cause as the
  M9 "signed-in Plus/Pro subscriber gated as free" item; no new fix
  attempted here.
- **`AuthGateContext` carries no resume-intent for either of this
  milestone's two auth-gate call sites** (`GetStartedViewModel.openAccount()`,
  `SettingsViewModel.restorePurchases()`), the same "pending auth intent
  lives in `@State`, not persisted" gap M9 recorded for the paywall path.
  Not fixed here — same accepted v1 gap, same final-report line item.
- **Skip-semantics correction, carried from onboarding (built earlier
  this milestone, not new today):** Skip on Welcome/HowItWorks/Personalize
  lands on LetsTryIt, never straight to GetStarted — only LetsTryIt's own
  separate skip action lands on GetStarted. `OnboardingStep.skipDestination`
  encodes this; team-lead's original framing ("skip on any step jumps to
  GetStarted") did not match RN source.
- Placeholder cleanup: `MilestonePlaceholderSheet` and
  `OnboardingPlaceholderView` are removed from `RootView.swift` /
  `AppRouter.swift` — grepped first, nothing else in the app target
  referenced either.
- Shared-file edits this milestone touched, all inside the file-ownership
  exception the assignment granted: `AppRouter.swift` (`RootGate` fix,
  placeholder removal), `RootView.swift` (`RootGate` consumption, the
  `.voiceCapture` auth-gate call site, `.settings`/`.setNewPassword`
  sheet wiring, placeholder removal), `RootGateTests.swift` (two new
  cases), `ReloraCore/Settings.swift`
  (`AppSettingsKey.onboardingTutorialReminderID`),
  `NotificationReconciler.swift` (id-based tutorial guard, replacing the
  title-based stand-in).
- New Swift Testing coverage, `ReloraKit/Tests/ReloraFeaturesTests/`:
  `Onboarding/OnboardingStepTests.swift`,
  `Onboarding/OnboardingStorageTutorialStateTests.swift`,
  `Onboarding/GetStartedCopyBuilderTests.swift`,
  `Onboarding/TutorialSeedTests.swift`,
  `Settings/ReminderNotificationsToggleTests.swift`,
  `Settings/DataExportTests.swift`,
  `Settings/SetNewPasswordViewModelTests.swift`. Authored against every
  callee's actual signature (re-verified via source reads, not assumed),
  never run — same standing constraint as every prior milestone.

## M10 manager review (signed off)

Verified against RN source: the `RootGate` fix (`navigationFlow.ts` lines
107–128 — accounts reset to Home unconditionally; the flag gates only
guest identities), skip semantics (`OnboardingStep.skipDestination`
matches the RN step files; the rules-doc line was stale), the tutorial
seed constants (verbatim vs `tutorialSeed.ts`), the scoped
notifications-toggle deviation (vs `reminderNotificationPreferences.ts`),
and both adjacent-gap `AppBootstrap` wirings (`onSignedOut`,
`deleteRemoteAccountData`) — all accepted. Fixes applied in review:

- **`ReloraToastCenter.showError` calls fixed in 10 places**
  (`SettingsViewModel` ×6, `LetsTryItStep` ×1,
  `SetNewPasswordViewModel` ×3): the second argument requires the
  `message:` label; the unlabeled form does not compile.
- **`SettingsPlanCopy`'s Plus branch rewritten to RN parity.** The
  report's "plan copy still degrades" premise was stale: M9's
  `RevenueCatVoiceAccess` evaluates `QuotaPolicy` against the real plan,
  so `monthlyNotesRemaining` IS populated for a Plus subscriber. The
  branch now renders RN's "N of 100 notes used this month"; generic copy
  remains only for the honest `nil` (`SettingsViewModel.init`'s
  pre-`load()` placeholder — RN's `?? 0` would flash "100 of 100 used").
  Pinned by new `Settings/SettingsPlanCopyTests.swift`.
- **Tutorial-seed guard id now written BEFORE the transaction**
  (`OnboardingTutorialSeedWriter.seed`). Written after, a crash between
  commit and guard-write left the reminder schedulable by the next
  launch's reconciliation pass. A dangling id from the reverse failure
  guards nothing and harms nothing.
- **`NotificationScheduler.schedule` doc comment corrected** (the
  report's finding): the false "no notification id yet" claim is gone;
  the comment now states callers own that check and why
  (`ReminderNotificationsToggle.enable` depends on it staying unchecked).
- **`AuthGateSource.voiceCapture`'s stale doc comment fixed** (the
  report's finding; `Billing/` was outside m10's edit rights).
- **`SetNewPasswordView` now reads `passwordRecoveryStatus`**, making
  `AppRouter.handle`'s doc comment true: a failed/expired recovery link
  shows RN's `PasswordRecoveryBridge` copy ("That reset link expired /
  Request a new one from the sign-in screen") as an in-sheet banner, and
  `onDisappear` acknowledges recovery so a swipe-dismissed sheet never
  leaves `.pending`/`.error` behind (RN's navigation gating forces the
  screen; a SwiftUI sheet is dismissible).
- **`OnboardingStorage.readTutorialReminderID()`** switched from `try?`
  to explicit `do`/`catch`, per the file's own header rule.

Accepted deviations carried to the final report: no persisted pending
auth intent (GetStarted + restore purchases), qualitative sync label,
user-scoped notifications toggle, `usageEvent: nil` on the tutorial seed
(RN's seed bypasses usage recording too), hand-chunked Personalize pill
rows + inferred onboarding-component layout (M11 device check).

## M11 outcomes — reviewed, see "M11 manager review" below

Polish, accessibility, dark-mode hardening, and a read of every screen as
a picky iOS reviewer. Nothing here changes behaviour except where noted.

**Queued items from earlier milestones, now closed**

- **Onboarding components corrected against the RN source**, not the
  docs. Four fidelity errors M10 had inferred: the hero card is
  `warmCard` (`#FFF7EF`), not white; its padding is `xl`, not `lg`; its
  gap is `md`, not `sm`; and Skip now carries a 44pt target, which RN
  buys with `hitSlop={10}`. Dot sizing was checked and already matched.
  Two deviations stay, recorded on the type: RN's ink-filled primary
  action (native uses `.reloraPrimary`), and RN's 1.05 scale on a
  selected pill, which overlaps its neighbours once the pills wrap.
- **Personalize's hand-chunked rows of two are gone**, replaced by
  `ReloraFlowLayout` — a real `Layout` conformance in `ReloraDesign`.
  The row-breaking arithmetic is split into `ReloraFlowSolver` so it can
  be tested without constructing `LayoutSubviews`, which is not
  constructible; `FlowLayoutTests` pins ten cases including the one that
  matters, an item wider than the row overflowing instead of looping.
  This retires the "hand-chunked pill rows" accepted deviation.
- **44pt targets and Differentiate Without Color swept across every
  screen.** Four controls were under size and now carry a `minHeight`
  and a `contentShape`: onboarding Skip, the paywall's Restore and
  create-account actions, and AuthGate's Forgot password. No place was
  found where colour is the only signal — overdue reminders lead with
  the word "Overdue", the import screen writes "Possible duplicate", and
  every selected row carries `.isSelected` beside its checkmark.

**VoiceOver**

Icon-only controls all had labels already. What was actually wrong was
the opposite problem — decoration being read aloud, and labels that
lied. Silenced: the paywall's plan bullets (the "•" is inside the
string, so the fix is an `accessibilityLabel`, not `accessibilityHidden`),
the selected-row checkmarks in both contact pickers, Home's context-card
bullets, and the onboarding hero circles. Removed two labels that
contradicted the visible text (`GetStartedStep`, `LetsTryItStep`), where
a skipping user saw "Enter Relora" and heard "See your example". The
onboarding progress dots are now one element announcing "Step 2 of 5".
Settings' repeated "Open" buttons gained an opt-in `spokenActionLabel`
rather than a generic rule, which would have produced "Sync now Sync
now". Buttons that report progress in their visible text now keep a
fixed spoken name.

**Dynamic Type**

No fixed height or width anywhere now wraps text; the five that remain
are on circles and a meter bar. Two glyphs stay deliberately unscaled
with the reason recorded in place: the record button's mic (a fixed
circle would clip it) and Home's reminder badge (pinned to a toolbar,
and the count is spoken in full anyway). The real find was
`SettingsView.actionRow`, where a title, a description and a bordered
button share one line — at accessibility sizes it becomes a column of
syllables. It now stacks past `isAccessibilitySize`. `ViewThatFits` was
the obvious tool and is wrong for it: these labels wrap, so the
horizontal arrangement always "fits", it just fits badly.

**Reduce Motion**

Already centralised in `Motion.swift`; this was an audit for escapes,
and it found two, both in `OnboardingComponents.swift` (raw springs on
the progress dots and the pill selection). Both now name a
`ReloraAnimation`. A full sweep confirms no feature reads the trait
itself. `VoiceLevelMeter` still does, correctly and with its reasoning
written down: its motion is the content, so there is no curve to drop —
it collapses to a single bar instead. The toast needed nothing; its
transition is driven by a `reloraAnimation` that nils under the trait,
so it snaps.

**Dark mode**

Every ratio recorded in `Palette.swift` was recomputed from the hex
values against WCAG 2.1 and every one matches. **No dark value needed
changing.** Minimums on dark: `ink` 11.15, `accentText` 5.47, `success`
5.79, `mutedInk` 5.19, `danger` 4.93, `onAccent` on brand fills 5.23,
`tertiaryInk` 3.56 (large text only, which is its documented rule).
Composited values check out too: the dark hairline and
`accentTintBorder` land at 1.299 and 1.298, so the palette's claim that
they weigh the same is true. The light palette was not touched; its
known AA failures stay flagged below for Andrew.

**Third-party tells found and fixed**

- `RemindersView`'s rows were `Button`s that pushed a contact. They are
  now `NavigationLink`s like Home's, which is what draws the disclosure
  chevron. A tappable list row with no chevron is the tell.
- `RemindersView` had no `.refreshable` while Home did. Same contract
  now: sync, then reload whether or not the sync landed.
- `SetNewPasswordView` drew its own card chrome — four literal corner
  radii and a hand-written shadow — and is now on `reloraSurface` /
  `reloraBorder`. It was also the one sheet in the app with no way out
  but a swipe, which mattered most on the expired-link path, where the
  screen tells you the link is dead and offers nothing to press.
- AuthGate's "Forgot password?" was underlined text. Underlines mark
  links on the web and nothing on iOS.

**Judgment calls left for the manager, not made**

- Settings puts a small bordered button on the right of each row instead
  of making the row itself tappable, which is not how iOS Settings
  behaves. Restructuring the screen is past polish.
- `ContactDetailView` has no `.refreshable`. It is a pushed detail
  screen that already observes content changes live, so this reads as
  correct, but Home and Reminders now both refresh and it does not.
- Inline form errors (`ContactEditView`, `AddReminderView`) appear
  without announcing themselves to VoiceOver. Fixing it properly needs
  `AccessibilityNotification` or focus management, and neither can be
  verified here.
- `SetNewPasswordView` hand-builds its text fields where
  `ContactEditView` uses a `Form` and `AuthGateView` uses a `ReloraCard`.
  Only the tokens were fixed; the structure is a redesign.

## M11 manager review (signed off, no fixes needed)

Every claim chased checked out — the first milestone reviewed with zero
manager fixes. Verified directly: `ReminderRowView`'s
`NavigationLink(value:)` resolves against the root stack's registered
`navigationDestination` (Reminders is pushed, not sheeted);
`reloraSurface`/`reloraBorder`/`ReloraRadius`/`warmCard`/
`ReloraAnimation.spring` all exist with the signatures used;
`Package.swift` declares the new `ReloraDesignTests` target;
`ReloraFlowSolver`'s arithmetic hand-traced through five of its ten test
expectations (all correct, including the oversized-item overflow
guard); the onboarding corrections match `styles.ts`/
`OnboardingProgressBar.tsx`/`StepContainer.tsx` verbatim; four dark
contrast pairs independently recomputed (ink/background 13.6, mutedInk/
background 6.3, mutedInk/card 5.8, accentText/card 6.1 — consistent
with "no dark value needed changing"); all 29 `showError` call sites
labeled; `SyncOrchestrator` is environment-injected at the app root, so
the pushed `RemindersView` inherits it. M10's manager additions to
`SetNewPasswordView` (recovery-error banner, `onDisappear` acknowledge)
survived the chrome rework, and the added Close button correctly routes
through the same `handleDisappear`.

Rulings on the four judgment calls left open:

1. **Settings' bordered row buttons stay.** That is the RN screen's own
   shape; making rows tappable is a redesign for Andrew to call after
   v1, not polish.
2. **`ContactDetailView` stays without `.refreshable`.** It observes
   content changes live; pull-to-refresh there would be ornament.
3. **Inline form-error VoiceOver announcements are deferred** to the
   first device pass — `AccessibilityNotification` behavior cannot be
   verified on this machine. Carried on the final report.
4. **`SetNewPasswordView`'s hand-built fields stay.** Tokens are fixed;
   restructuring to `Form`/`ReloraCard` is churn with no user-visible
   gain.

## Design-review flags for the final report (M11 / Andrew)

- Light palette AA findings (kept locked values + usage rules; need
  Andrew's sign-off): `#2F8A57` success fails 4.5:1 as normal text on
  all light surfaces; mutedInk / accentText / danger miss AA on
  `offlineSurface`.
- MARKETING_VERSION 2.0.0 confirmed by Andrew 2026-09-01 (majors are his
  call); `project.yml` already carries it. The Expo app's four version
  files stay untouched: they version EAS builds of `apps/mobile`, which
  ships no new work here, and Android stays on the Expo line.

## Simplify pass (pre-PR, 2026-09-01)

Andrew's standing rule: a non-author reviewer reads the finished diff
before every PR and strips what the work doesn't need. Run on branch
`ios-native-rebuild` against the M0–M11 baseline commit, as four parallel
non-author reviewers with disjoint file sets (Core/Data/Sync, Services,
Design, Features + app target). The manager verified every applied edit
against the working-tree diff and whole-tree greps, not the reports.

**Applied removals (19 by reviewers, all verified):**

- *Core/Data/Sync:* two uncalled `AppDatabase`-scoped wrappers on
  `ContactSearchIndex` (`refreshRow`, `rebuild`); `ScoredCandidate.directNameStrength`
  (assigned `subjectSimilarity` verbatim at its only construction site);
  a test assertion duplicating the line above it; both M0 placeholder
  test files (`scaffoldCompiles`).
- *Services:* `TranscriptAccumulator.hasTurn` and its only (test) caller;
  a needless `@discardableResult`; a vacuous `StopReason` assertion; a
  pipeline test that duplicated its sibling byte-for-byte (its
  coverage-gap caveat moved to the survivor's doc comment); six unused
  fake-double setters.
- *Design:* `ReloraCard`'s never-passed `bordered:` parameter and the
  private `OptionalBorder` modifier it drove.
- *Features:* `ContextCardModel.profileHighlightLimit`; the unread
  `toasts` dependency of `GetStartedViewModel`; the `persistedStep:`
  parameter of the onboarding coordinator's `advance` (every call site
  passed the destination's own raw value — verified against
  `OnboardingStep`'s explicit raw values); an unasserted fake counter.

**Manager follow-ups from the reviewers' flags:**

- **Bug found and fixed:** `ContactSearchIndex.initialize` — the port of
  RN's startup `initializeSearchIndex` — was called by nothing.
  Traced: after a sync pull defers an FTS rebuild, searches (read
  connection) throw on the rebuild's DELETE and silently LIKE-fallback
  until the next local write. `AppBootstrap.start()` now calls it,
  best-effort, matching RN. Credit: the Core/Data/Sync reviewer refused
  to delete the "dead" wrapper precisely because it looked like missing
  wiring.
- `LocalVoiceAccess` (~60 lines, dead since M9's `RevenueCatVoiceAccess`)
  deleted, with the comments naming it as reference rewritten to state
  their content directly; `VoiceQuotaGate.swift`'s now-unused
  `import ReloraData` removed.
- `ReminderDraftError.alertTitle` deleted after checking RN:
  `AddReminderScreen` toasts `showError(title, message)`; native shows an
  inline form error beside the fields, so only `.message` is ported
  (deviation now stated in the source).
- `Spacing.swift`'s "floating-layer metrics deliberately not defined yet"
  note updated — `FloatingLayer.swift` has since shipped them.
- **Second bug found and fixed:** `ReminderNotificationsToggleTests`'
  fixture contact defaulted to a random `ReloraID.new()` while every
  reminder in the file uses `contactID: "c1"` — and the schema enforces
  `FOREIGN KEY(contact_id, user_id) → contacts` with foreign keys on, so
  all five database-backed tests in that file would have thrown at
  `upsert` on the first Mac run. The fixture now defaults to `"c1"`.
  (Flagged by the Features reviewer as cosmetic; the FK made it real.)
- `ContactItemRestoreResult.reminderToReschedule`'s doc comment said
  "only when still `scheduled`" while `restore()` returns the reminder
  regardless of status (as its body comment and
  `restoreDismissedReminderStillReturnsHandle` both state). The doc now
  matches the code.
- One `var reminder` that never mutates in `ReminderRepositoryTests`
  changed to `let` (would have warned on the Mac build).
- `directNameStrength`'s removal kept even though the RN original
  (`voiceCaptureMatching.ts`) carries the same redundancy — the RN
  citation comments still point at the source; we don't port dead weight
  for line-by-line diffability.

**Rejections (~25, each with a stated reason — the proof the pass
looked):** testability seams and single-caller pure-logic splits;
RN-parity copy that cannot be merged without proof from the RN source;
design-token scales kept complete; module doc-comment anchors; and
several removals refused outright as unverifiable compile gambles on a
machine that cannot build (`Equatable` conformances, import trims,
visibility narrowing).

**Flags left for after the first green build** (also in
macos-build-checklist §5f): `ReloraDesign`'s apparently dead `ReloraCore`
dependency in `Package.swift`; `VoiceLevelMeter.loudnessDescription`'s
test-shaped internal visibility with no test. Two reviewer flags resolved
as false alarms: `LiveTranscriptPreview`'s bare `trimmed` (same-module
internal extension in `ContactEditForm.swift`) and `.gentle` (a real
`ReloraAnimation` case).

The skill's post-edit test re-run cannot happen on this machine; the
first Mac build is that verification.

## Fonts (done, M5 relies on it)

DM Sans static instances (400/500/600/700) cut from the upstream
variable font live in `Relora/Fonts/`; `UIAppFonts` is declared in
`Info.plist`. PostScript names match `Typography.swift`'s
`Font.custom` names exactly (`DMSans-SemiBold` included — the static
upstream exports lack it, which is why the faces are instanced).
