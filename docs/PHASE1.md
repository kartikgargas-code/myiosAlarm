# Phase 1: Build and physical-device proof

This repository contains a minimal iOS 26 SwiftUI application that requests AlarmKit authorization and schedules one fixed-date system alarm two minutes in the future. Physical behavior is intentionally **not** marked verified.

## Verified API facts

- AlarmKit is available on iOS 26 and later.
- Apple documents one-time fixed schedules, relative weekly schedules, authorization, cancellation, stop, and countdown-based snooze/repeat behavior.
- `NSAlarmKitUsageDescription` must exist and be nonempty or scheduling fails.
- Apple states that AlarmKit alerts override Focus and Silent Mode if necessary. This remains a device-test item for this app.
- This alert-only proof does not use a countdown presentation, so it does not require the Live Activity widget extension that Apple warns is required for countdown presentations.
- No AlarmKit-specific entitlement appears in Apple's documentation or current iOS capability matrix. AlarmKit authorization is a runtime permission. The free-account uncertainty is therefore practical signing/sideloading compatibility, not a documented AlarmKit entitlement restriction.

Sources:

- https://developer.apple.com/documentation/alarmkit
- https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit
- https://developer.apple.com/documentation/bundleresources/information-property-list/nsalarmkitusagedescription
- https://developer.apple.com/help/account/reference/supported-capabilities-ios

## Build in GitHub Actions

1. Put the repository on GitHub. Public repositories receive standard GitHub-hosted runner usage without consuming private-repository minutes; private repositories use the account's included Actions quota.
2. Open **Actions > iOS Build > Run workflow**.
3. Download the `AlarmClock-unsigned-ipa` artifact after the job succeeds.

The workflow uses `macos-15`, selects Xcode 26, generates `AlarmClock.xcodeproj` from `project.yml`, runs unit tests in an iOS 26 simulator, builds for `iphoneos` with signing disabled, and wraps the `.app` as `Payload/AlarmClock.app` in an IPA container. GitHub's published `macos-15` image currently includes Xcode 26.0.1 and the iOS 26.0 iPhone 16 simulator.

The resulting file is unsigned. It cannot be installed directly. A sideloading tool must sign it for the target iPhone.

Local macOS equivalents:

```sh
brew install xcodegen
xcodegen generate
xcodebuild test -project AlarmClock.xcodeproj -scheme AlarmClock \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project AlarmClock.xcodeproj -scheme AlarmClock \
  -configuration Release -sdk iphoneos -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
mkdir -p Payload
cp -R DerivedData/Build/Products/Release-iphoneos/AlarmClock.app Payload/
ditto -c -k --sequesterRsrc --keepParent Payload AlarmClock-unsigned.ipa
```

## Windows 11 installation with a free Apple Account

### Sideloadly path

1. Confirm the iPhone runs iOS 26 or later.
2. Install the Apple Windows components required by Sideloadly's current instructions.
3. Install Sideloadly from https://sideloadly.io/.
4. Connect the iPhone by USB, unlock it, tap **Trust**, and enter the device passcode.
5. Download and unzip the GitHub Actions artifact.
6. Drag `AlarmClock-unsigned.ipa` into Sideloadly, select the iPhone, and sign/install it using the Apple Account intended for personal development. Credentials go only to the signing tool/Apple; never add them to this repository or GitHub Actions.
7. On the iPhone, enable **Settings > Privacy & Security > Developer Mode** if prompted, restart, and confirm Developer Mode.
8. If iOS asks you to trust the developer identity, use the relevant item under **Settings > General > VPN & Device Management**.
9. Open Alarm Clock and perform the checklist below.

Free Personal Team limits documented by Apple currently include up to 10 App IDs, up to 3 devices, up to 3 installed apps per device, and 7-day App ID/device/provisioning validity. Rebuild or re-sign/reinstall at least every seven days. See https://developer.apple.com/help/account/basics/about-your-developer-account.

Sideloadly is a third-party tool. Whether its signing path preserves everything AlarmKit needs must be proven on the device. If installation succeeds but `AlarmManager.schedule` reports a signing/capability error, capture the exact app message and Sideloadly log; that is the stop condition before Phase 2.

### SideStore path

SideStore can refresh apps on-device after its own initial setup, but setup and refresh requirements change. Follow its current official documentation at https://docs.sidestore.io/ and import the same unsigned IPA. Do not place an Apple Account password or anisette data in the repository.

## Physical proof checklist

Record iPhone model and exact iOS version.

1. Launch the app and tap **Request Alarm Access**.
2. Accept the system AlarmKit authorization prompt. Confirm the card says **Authorized**.
3. Tap **Schedule Alarm in 2 Minutes**. Confirm the displayed time is two minutes ahead.
4. Lock the iPhone and wait. Record whether the alarm appears and sounds.
5. Repeat with Silent Mode enabled.
6. Repeat with an active Focus mode.
7. Stop each alarm using the system alarm UI.
8. Force-quit the app after scheduling and repeat the locked-screen test.
9. Report every result; do not infer success from compilation or simulator tests.

The proof uses a fixed absolute `Date`, avoiding a near-midnight bug that can occur if “two minutes ahead” is reduced to hour/minute components. The complete repeating and temporary-occurrence engine belongs to Phase 2 after this gate passes.

## Known limitations at this milestone

- Windows cannot run Xcode, the iOS simulator, or compile AlarmKit locally.
- GitHub's macOS runner cannot test lock-screen sound, Silent Mode, Focus, app termination, or authorization behavior on a real iPhone.
- GitHub Actions does not receive Apple credentials or certificates and produces only an unsigned IPA container.
- Free signing expires after seven days and is not distribution.
- No custom sounds, recurring schedule, snooze, temporary adjustment, persistence, or polished full UI is implemented yet.
- Do not proceed on the assumption that free-account sideloading supports AlarmKit until the physical proof succeeds.
