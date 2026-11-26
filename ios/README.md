# Notifdex iOS Companion — Phase 1 Notification Capture Prototype

This directory holds an isolated native SwiftUI iOS application (`NotifdexiOS`) that proves the end-to-end iOS 27 notification capture pipeline on a physical iPhone without touching macOS builds or CI:

```text
iOS 27 Notification Automation (Shortcuts)
  → Notifdex → Capture Notification (AppIntent, background + alwaysAllowed)
  → CaptureService (normalization + dynamic per-app toggle & pause checks)
  → NotificationStore (WAL SQLite, FileProtectionCompleteUntilFirstUserAuthentication)
  → NotifdexiOS Inbox / Capture / Settings UI
```

## Architecture

- **`ios/NotifdexiOS/Core/CaptureModels.swift`** — Schema-aligned record types (`CapturedNotification`, `IncomingNotificationPayload`, `CaptureOutcome`, `CaptureSettingsState`, `AppAutomationStatus`, `IntentExecutionLogEntry`). Each device uses a stable `source_id` (`<deviceUUID>:ios_shortcuts`), `capture_channel` (`ios_shortcuts` vs `manual_test`), and `origin` (`iphone`), aligning with `NotifdexCore`'s `observations` schema for Phase 2 hybrid sync.
- **`ios/NotifdexiOS/Core/CaptureNormalizer.swift`** — Trims whitespace and Unicode directional marks (`U+061C`, `U+200E`, `U+200F`), safely normalizes optional `title`/`subtitle`/`body` (including app-only lock-screen redacted alerts), and generates deterministic SHA-256 deduplication keys.
- **`ios/NotifdexiOS/Core/NotificationStore.swift`** — Durable SQLite repository (`WAL`, `synchronous = FULL`, `busy_timeout = 3000ms`) with `FileProtectionType.completeUntilFirstUserAuthentication` so background Shortcuts executions can commit while the iPhone screen is locked (after first boot unlock). Uses a transactional 60-second sliding-window deduplication check inside `BEGIN IMMEDIATE` so rapid retries across minute boundaries stay idempotent while later identical messages remain distinct.
- **`ios/NotifdexiOS/Core/CaptureService.swift`** — Authoritative ingestion pipeline implementing the safety invariants modeled in [`spec/IOSCapture.tla`](../spec/IOSCapture.tla):
  - Never returns `captured` unless SQLite committed durably (`AcknowledgedIsDurable`).
  - Never fabricates Shortcuts verification from in-app toggles (`ToggleNeverFabricatesVerification`).
  - Skips writes cleanly when globally paused or when an app is toggled off in Notifdex, without losing prior records (`SkipAndFailNeverWrite`, `DurableNeverDisappears`).
- **`ios/NotifdexiOS/Intents/CaptureNotificationIntent.swift`** — Exposes **Notifdex → Capture Notification** inside Apple's Shortcuts app with explicit typed parameters (`app: String`, `title: String?`, `subtitle: String?`, `body: String?`), `supportedModes = .background`, and `authenticationPolicy = .alwaysAllowed`.
- **`ios/NotifdexiOS/UI/`** — Native SwiftUI screens:
  - **Inbox**: searchable, app-filterable list with color-coded badges and provenance detail sheet.
  - **Capture**: X, Gmail, WeChat (+ custom apps), dynamic in-app toggles, honest 3-state status (*Active via Shortcuts*, *Selected · Awaiting Shortcut*, *Paused in Notifdex*), `shortcuts://automations` deep link, and setup guide.
  - **Settings**: capture status, counts, last capture time, `source_id`, DB size, simulated test capture (`manual_test`), and bounded intent execution debug log.

## Build, Test, and Run

### Simulator unit & intent-handoff tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ios/NotifdexiOS.xcodeproj -scheme NotifdexiOS \
  -destination "platform=iOS Simulator,name=iPhone 17" test
```

### Build and install on a connected iPhone (Xcode 27.2+)

Open `ios/NotifdexiOS.xcodeproj` in Xcode, select your connected iPhone (signing is configured for Team `HNH4DY9A2T`, bundle ID `com.notifdex.ios`), and press **Run**, or build/install from Terminal:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ios/NotifdexiOS.xcodeproj -scheme NotifdexiOS \
  -destination "platform=iOS,id=<DEVICE_UDID>" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun devicectl device install app --device <DEVICE_UDID> <PATH_TO_NotifdexiOS.app>

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun devicectl device process launch --device <DEVICE_UDID> com.notifdex.ios
```

## Configure iOS 27 Shortcuts Automation (Single Multi-App Flow)

Apple does not provide a public API to silently create or enable Personal Automations, but **iOS 27 allows selecting multiple apps inside one Notification automation**:

1. Open **Shortcuts** → **Automation** → **`+`**.
2. Choose **Notification**.
3. Select all apps you want Notifdex to observe (e.g., **X**, **Gmail**, **WeChat**, **Messages**), leave text filters empty, and select **Run Immediately**.
4. Tap **Next** → **New Blank Automation**.
5. Search for **Notifdex** → add **one** **Capture Notification** action.
6. Map the `Notification` variable's properties to the four explicit parameters:
   - **App** → `Notification.App`
   - **Title** → `Notification.Title`
   - **Subtitle** → `Notification.Subtitle`
   - **Body** → `Notification.Body`
7. Tap **Done** and verify the automation is enabled.

After this one-time setup, toggling an app on/off or pausing inside Notifdex's **Capture** tab controls whether Notifdex persists incoming alerts without reopening Shortcuts.

## Supported Fields & Known iOS Limitations

- **Supported fields:** `App` (required), `Title` (optional), `Subtitle` (optional), `Body` (optional), plus local capture timestamp, device `source_id`, and `ios_shortcuts` channel provenance.
- **No silent automation creation:** Users must authorize the Notification trigger in Shortcuts.
- **Forward-only capture:** Shortcuts triggers fire on newly arriving notifications only; previously delivered Notification Center history is not readable on iOS.
- **Delivery latency variance:** Initial physical-device testing on iPhone 17 (iOS 27.2) observed an occasional ~3-minute delay on an early X alert (`10:52` sent → `10:55` intent execution) while subsequent Gmail and X alerts arrived near-instantly. Follow-up RCA is needed to isolate upstream push delivery vs iOS Shortcuts background scheduling.
- **Lock-screen & hidden previews:** If iOS *Show Previews* is set to *When Unlocked* or *Never*, lock-screen alerts may omit body text. Check **Settings → Recent Intent Executions** after locked/unlocked trials to record exact OS behavior.
- **No sync in Phase 1:** Data stays local in `Application Support/Notifdex/ios-capture.db`. Cross-device sync (Issue #74 / #10) is planned for Phase 2 after physical-device capture reliability is validated.

## Physical-Device Acceptance Checklist (iPhone 17 / iOS 27.2)

- [x] App installs, launches, and exposes **Notifdex → Capture Notification** in Shortcuts with `App`, `Title`, `Subtitle`, and `Body`.
- [x] Single combined multi-app Notification automation triggers **Notifdex → Capture Notification** for **Messages**, **X**, and **Gmail** and persists records into the Inbox.
- [x] **Messages** and **X** transition from *Selected · Awaiting Shortcut* to **Active via Shortcuts** upon real delivery.
- [x] Locked-screen delivery verified with **X** (persisted while locked via `.alwaysAllowed` + `FileProtectionCompleteUntilFirstUserAuthentication`).
- [ ] Verify real notification capture for **WeChat**.
- [ ] Verify dynamic toggle-off in **Capture** logs `SKIPPED` in **Settings → Recent Intent Executions** without deleting prior alerts.
- [ ] Track/RCA occasional multi-minute trigger delay (observed once on early X alert: ~3 min lag; subsequent Gmail/X alerts were near-instant).
