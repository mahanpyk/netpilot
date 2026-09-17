# NetPilot Desktop

Split routing for developers on dual networks (Wi‑Fi for internet + LAN for intranet).

**Platforms:** macOS 14+; Windows 10 22H2/11 x64 development implementation
**Docs for agents:** [`HANDOFF.md`](HANDOFF.md) · [`AGENTS.md`](AGENTS.md)

## What it does

1. Lists active network interfaces (Wi‑Fi, Ethernet, …).
2. Lets you add destinations: hostname, URL (hostname only), IPv4, or CIDR.
3. Applies specific routes so those destinations leave via the chosen LAN interface — without changing macOS service order.
4. Scans saved URLs for related HTML/JavaScript hosts and adds them as expandable, independently switchable Sub-rules on the same interface.
5. Pins selected macOS applications or Windows Win32 EXEs and reviewed helpers
   to a physical interface with block/fallback behavior.

## Requirements

- Flutter **3.47.4 stable** / Dart **3.13.3** (minimum versions in `pubspec.yaml`)
- Xcode 15+ / macOS 14+ for running the app
- Apple Development Team (same Team ID on app + helper) for privileged helper install
- Windows: Visual Studio 2022, Windows SDK/WDK, CMake, WiX v4, and Test Mode for
  test-signed driver development

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

For Windows setup, test signing, build, installer, and the required two-adapter
acceptance gate, see [`windows/README.md`](windows/README.md) and
[`windows/IntegrationTests/WFP_GATE.md`](windows/IntegrationTests/WFP_GATE.md).
The Windows Runner remains unelevated; route/WFP changes are accepted only by
the installed LocalSystem service over its validated named-pipe API.

## Privileged helper

Route changes need a signed helper (`com.netpilot.netpilotDesktop.helper`) embedded at build time (`macos/scripts/embed_helper.sh`) and installed via `SMAppService`. Approve **Login Items / Background Items** if prompted. Without a valid Team ID signature, inventory and UI still work; apply/reconcile may fail until signing is configured.

If corporate Pub mirror fails:

```bash
PUB_HOSTED_URL=https://pub.dev flutter pub get
```

## Agent / contributor note

Before changing structure or contracts, read `HANDOFF.md`. Keep it updated when you change them.
