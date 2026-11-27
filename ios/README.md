# Notifdex iOS Companion — Phase 1 & Phase 2 Hybrid Sync

This directory holds an isolated native SwiftUI iOS application (`NotifdexiOS`) that links the shared local Swift package `NotifdexCore` (`..`) while remaining excluded from macOS Command Line Tools builds (`"ios"` in `Package.swift` `exclude:`):

```text
iOS 27 Notification Automation (Shortcuts)
  → Notifdex → Capture Notification (AppIntent, background + alwaysAllowed)
  → CaptureService (dedicated serial ingestQueue, dynamic per-app toggle & pause checks)
  → Shared NotifdexCore CaptureStore (schema v12 WAL SQLite, synchronous = NORMAL on iOS,
      FileProtectionCompleteUntilFirstUserAuthentication)
  → Optional Opt-In CloudKit Private DB (iCloud.com.notifdex.shared, zone NotifdexSyncZone)
  → NotifdexiOS 5-Tab App (Inbox, Today, People, Notes, Setup) & macOS App Center
```

## Architecture

- **`NotifdexCore` (shared Swift package)** — Schema v12 (`Sources/NotifdexCore/sync.sql`), `HybridSync.swift` (opt-in pairing/revocation, filtered Mac → iOS projection, monotonic LWW workflow sync, tombstones, `HybridInboxProjection` provenance collapsing, `MacForwardingHealthAnalyzer`), and `CloudKitSyncTransport.swift` (entitlement-guarded private CloudKit zone `NotifdexSyncZone`). Modeled in [`spec/HybridSync.tla`](../spec/HybridSync.tla).
- **`ios/NotifdexiOS/Core/CaptureService.swift`** — Authoritative ingestion pipeline implementing [`spec/IOSCapture.tla`](../spec/IOSCapture.tla) on top of shared `NotifdexCore.CaptureStore` (with non-destructive migration of Phase 1 `ios-capture.db` rows). Uses a dedicated `.userInitiated` serial `ingestQueue` for writes and lock-free WAL reads for UI so Shortcuts bursts commit well below Apple's background timeout.
- **`ios/NotifdexiOS/Intents/CaptureNotificationIntent.swift`** — Exposes **Notifdex → Capture Notification** inside Apple's Shortcuts app with explicit typed parameters (`app: String`, `title: String?`, `subtitle: String?`, `body: String?`), `supportedModes = .background`, and `authenticationPolicy = .alwaysAllowed`.
- **`ios/NotifdexiOS/UI/`** — Native SwiftUI 5-tab companion:
  - **Inbox**: All / Unread / Flagged / Saved filters, provenance badges (`iPhone`, `iPhone via Mac`, `Mac`), swipe & detail workflow actions, Person linking, and follow-up scheduling.
  - **Today**: Due / overdue follow-ups and completion controls.
  - **People**: Relationship profiles, linked timelines, and shared People notes.
  - **Notes**: Personal notes with one-level folders and Unfiled.
  - **Setup & Settings**: Multi-app Shortcuts status, dynamic per-app toggles, opt-in CloudKit Sync (**Enable & Pair**, **Sync Now**, device list & one-tap **Revoke**), simulated test capture (`manual_test`), and bounded intent execution debug log.
- **`ios/NotifdexiOS/NotifdexiOS.entitlements`** — Declares `CloudKit` and container `iCloud.com.notifdex.shared` (matched on macOS by `Resources/NotifdexMac.entitlements` when building with `NOTIFDEX_PROVISIONING_PROFILE`).

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
- **Opt-in CloudKit Sync (Phase 2):** Private iCloud sync (`iCloud.com.notifdex.shared`, zone `NotifdexSyncZone`) is off by default until paired in **Settings** (iOS) and **Recovery → iOS & iCloud Sync** (macOS). Hidden/muted Mac alerts stay local and never sync to iCloud or iPhone.
- **macOS `usernotificationsd -10814` forwarding drops (#98):** If macOS Notification Center stops showing forwarded alerts for an iPhone-only app (such as Gmail or X) while iOS Shortcuts still captures them, check **System Settings → Notifications → Allow notifications from iPhone**; updating the app in the iPhone App Store or **Offload & Reinstall** (preserving app data) forces `replicatord` → `appplaceholdersyncd` to emit a fresh remote placeholder record.

## Physical-Device Acceptance Checklist (iPhone 17 / iOS 27.2)

- [x] App installs, launches, and exposes **Notifdex → Capture Notification** in Shortcuts with `App`, `Title`, `Subtitle`, and `Body`.
- [x] Single combined multi-app Notification automation triggers **Notifdex → Capture Notification** for **Messages**, **X**, and **Gmail** and persists records into the Inbox.
- [x] **Messages** and **X** transition from *Selected · Awaiting Shortcut* to **Active via Shortcuts** upon real delivery.
- [x] Locked-screen delivery verified with **X** (persisted while locked via `.alwaysAllowed` + `FileProtectionCompleteUntilFirstUserAuthentication`).
- [x] Bidirectional CloudKit Private DB sync verified live between iPhone 17 (`com.notifdex.ios`) and signed Mac mini build (`com.notifdex.mac`, dirty-digest skip verified on second sync).
- [x] Shortcuts burst timeout fixed (lock-free WAL UI reads + dedicated serial `ingestQueue` + `PRAGMA synchronous = NORMAL` on iOS; 25-alert concurrent burst XCTest completes in ~0.02s).
- [ ] Verify real notification capture for **WeChat** via Shortcuts automation.
- [ ] Verify dynamic toggle-off in **Capture** logs `SKIPPED` in **Settings → Recent Intent Executions** without deleting prior alerts.
- [ ] Track/RCA occasional multi-minute trigger delay (observed once on early X alert: ~3 min lag; subsequent Gmail/X alerts were near-instant).
