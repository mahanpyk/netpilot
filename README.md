# NetPilot Desktop

Split routing for developers on dual networks (Wi‑Fi for internet + LAN for intranet).

**Platform (v1):** macOS 14+  
**Windows:** deferred  
**Docs for agents:** [`HANDOFF.md`](HANDOFF.md) · [`AGENTS.md`](AGENTS.md)

## What it does

1. Lists active network interfaces (Wi‑Fi, Ethernet, …).
2. Lets you add destinations: hostname, URL (hostname only), IPv4, or CIDR.
3. Applies specific routes so those destinations leave via the chosen LAN interface — without changing macOS service order.
4. Scans saved URLs for related HTML/JavaScript hosts and adds them as expandable, independently switchable Sub-rules on the same interface.

## Requirements

- Flutter **3.47.4 stable** / Dart **3.13.3** (minimum versions in `pubspec.yaml`)
- Xcode 15+ / macOS 14+ for running the app
- Apple Development Team (same Team ID on app + helper) for privileged helper install

## Setup

Upgrade an existing Flutter installation to the latest stable release first
(see the [official upgrade guide](https://docs.flutter.dev/install/upgrade)):

```bash
flutter channel stable
flutter upgrade
flutter --version
```

Then install the project's locked dependencies:

```bash
flutter pub get
open macos/Runner.xcworkspace   # set Signing Team on Runner + NetPilotHelper
flutter run -d macos
```

## Tests & analyze

```bash
flutter analyze
flutter test
flutter build macos
```

## Privileged helper

Route changes need a signed helper (`com.netpilot.netpilotDesktop.helper`) embedded at build time (`macos/scripts/embed_helper.sh`) and installed via `SMAppService`. Approve **Login Items / Background Items** if prompted. Without a valid Team ID signature, inventory and UI still work; apply/reconcile may fail until signing is configured.

If corporate Pub mirror fails:

```bash
PUB_HOSTED_URL=https://pub.dev flutter pub get
```

## Agent / contributor note

Before changing structure or contracts, read `HANDOFF.md`. Keep it updated when you change them.
