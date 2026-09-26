# NetPilot Desktop

![NetPilot icon](macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png)

**Route selected destinations through a chosen network interface while keeping your usual default connection.** NetPilot is a Flutter desktop app for people connected to two networks at once, such as Wi-Fi for the internet and Ethernet for a company intranet.

[![Tagged test release](https://github.com/mahanpyk/netpilot/actions/workflows/release.yml/badge.svg)](https://github.com/mahanpyk/netpilot/actions/workflows/release.yml) · [Changelog](CHANGELOG.md) · [Test releases](https://github.com/mahanpyk/netpilot/releases) · [Report an issue](https://github.com/mahanpyk/netpilot/issues)

> **Project status:** NetPilot is under active development. The downloadable macOS test DMG supports destination rules but does **not** include per-app routing. Windows packages build in CI, but installation and live routing still need acceptance testing on real Windows machines. These are test builds, not production releases.

## Features

| Feature | What it does |
| --- | --- |
| Destination rules | Route a hostname, HTTP(S) URL, IPv4 address, or CIDR range through a selected Wi-Fi or Ethernet interface. A URL rule routes by hostname/IP, not by URL path. |
| URL dependency discovery | On Save, scan a public page's HTML, inline JavaScript, same-origin JavaScript files, and redirects for additional hosts. Show them as independently switchable sub-rules that inherit the parent interface. |
| Network inventory | Show active interfaces, IPv4 addresses, gateways, DNS servers, and the default route. |
| Route diagnostics | Show resolution, route application, conflicts, and helper errors in the app and terminal (`[NetPilot]`). Refresh DNS and reapply existing rules without rescanning the page. |
| Browser reconnect | After route changes, refresh affected Safari/Chromium networking services on macOS so open tabs can establish new connections over the updated route. Windows has a corresponding implementation awaiting live testing. |
| Per-app routing (development) | Source code for macOS Transparent Proxy and Windows WFP-based routing of selected apps over a physical interface. This is **not available in the macOS test DMG** and has not passed the required signed/live integration gates. |

NetPilot currently routes **IPv4** traffic. It does not inspect TLS, route by URL path, or provide a VPN. If two sites use the same destination IP, a system-wide destination route cannot send those sites through different interfaces. The dependency scanner uses static analysis; it does not execute JavaScript or scan pages requiring a login.

## Download and try it

Download the latest assets from [GitHub Releases](https://github.com/mahanpyk/netpilot/releases). Check each release's changelog and `SHA256SUMS.txt` before testing.

### macOS 14+

1. Download `NetPilot-Rules-Test-*.dmg`, install the app, and open it.
2. In **Settings → Privileged helper**, choose **Install / Repair** and approve the background item if macOS asks. Route changes require this signed helper.
3. In **Networks**, confirm that the intended interface is active. In **Rules**, choose **Add rule**, enter a destination such as `intranet.example.com` or `10.0.0.0/8`, select the interface, then **Save & apply**.
4. Inspect the rule's status and the **Diagnostics** panel. Use **Refresh DNS & apply** if a hostname's address changes.

The DMG is signed with an Apple Development certificate, not Developer ID notarized. macOS may require approval in **System Settings → Privacy & Security** on another Mac. App Routing is intentionally unavailable in this package.

### Windows 10 22H2 / Windows 11 (x64)

The Windows installer, MSI, portable ZIP, and matching driver test certificate are published for **controlled testing only**. The WFP driver is test-signed; Test Mode, certificate trust, and a reboot are required. Use a disposable VM or test machine and follow the [Windows build and installation guide](windows/README.md) and [two-adapter integration checklist](windows/IntegrationTests/WFP_GATE.md). A successful CI build does not establish that the driver or routes work on your machine.

## Build from source

### macOS

Requirements: Flutter **3.47.4+** (Dart **3.13.3+**), Xcode 15+, and macOS 14+. Install Flutter using the [official guide](https://docs.flutter.dev/get-started/install), then run:

```bash
flutter pub get
open macos/Runner.xcworkspace
flutter run -d macos
```

Configure the same Apple Development Team for the Runner and privileged helper in Xcode before testing route changes. An unsigned local build can show the UI and networks, but it cannot validate privileged routing or activate the per-app System Extension. The extension requires approved Network Extension/System Extension entitlements and a suitable provisioning profile; see the [macOS signed integration gate](macos/IntegrationTests/APP_ROUTING.md).

### Windows

Requirements: Visual Studio 2022 with Desktop C++, Windows SDK and WDK, CMake, Flutter 3.47.4+, and WiX v4. Follow [windows/README.md](windows/README.md) for developer setup, test signing, build commands, and installer creation. The Flutter Runner stays unelevated; only the installed Windows service and WFP driver perform privileged operations.

## Verify changes

Run the Flutter checks on your development platform:

```bash
flutter pub get
flutter analyze
flutter test
```

On macOS, `flutter build macos --debug` checks the desktop build. On Windows, follow the [Windows guide](windows/README.md) for native CTest, driver, signing, and installer checks. Real route and per-app egress behavior must also be tested on a machine with two usable network interfaces; CI compilation alone is insufficient.

## How it works

NetPilot stores destination and app rules in the current user's application-support directory. The Flutter UI resolves destinations and reconciles desired routes when rules or interfaces change. On macOS, route mutations go through a signed `SMAppService`/XPC helper; on Windows they go through a validated named pipe to a LocalSystem service. The app does not run arbitrary shell commands from rule input. [HANDOFF.md](HANDOFF.md) documents the native contracts, persistence formats, and current integration gates.

URL scans run when a URL rule is saved. They have limits on redirects, script downloads, request duration, and total data. A failed scan leaves the parent destination rule in place and reports the warning. Refreshing DNS does not rescan the page. When multiple rules request the same IP on different interfaces, NetPilot reports a conflict instead of silently choosing one.

The main Flutter code lives in [`lib/`](lib/), with Flutter tests in [`test/`](test/). Platform-specific code and integration instructions live in [`macos/`](macos/) and [`windows/`](windows/). [HANDOFF.md](HANDOFF.md) is the technical map for contributors.

## Releases

Pushing an annotated version tag triggers the [release workflow](.github/workflows/release.yml). It runs Flutter checks and builds both platform packages, then creates a GitHub prerelease only if both jobs succeed. Release notes are generated from commits since the previous version tag; rerunning the tag workflow updates its assets and notes.

The curated [changelog](CHANGELOG.md) records the significant changes and
release status for each test version. Update its **Unreleased** section when
making user-visible changes, then move those entries under the next tag.

Maintainers must set `MACOS_CERT_P12_BASE64` and `MACOS_CERT_P12_PASSWORD` as GitHub Actions repository secrets before tagging. The P12 must contain the Apple Development identity used to sign the macOS app and helper. Keep certificates, private keys, and passwords out of Git. Once the intended changes are on `main`, create and push an annotated tag:

```bash
git tag -a v1.0.2-test.1 -m "NetPilot test build"
git push origin v1.0.2-test.1
```

The current workflow produces **test prereleases**. macOS packages are not Developer ID notarized, and Windows packages use a per-run test driver certificate.

## Contributing and reporting issues

Issues and pull requests are welcome. Before changing native contracts, models, file layout, or capabilities, read [AGENTS.md](AGENTS.md) and [HANDOFF.md](HANDOFF.md); update the handoff in the same change when those contracts change. Keep commits descriptive because release changelogs are generated from their subjects. Include relevant Flutter/native tests and describe what was verified on real hardware.

For a routing bug, [open an issue](https://github.com/mahanpyk/netpilot/issues) with the OS version, NetPilot release, destination type, selected interface, expected and actual behavior, and the app's Diagnostics or `[NetPilot]` terminal lines. Remove private hostnames, IPs, and credentials before posting public logs.

If dependency installation fails behind a corporate Pub mirror, retry with `PUB_HOSTED_URL=https://pub.dev flutter pub get`.

## License

NetPilot Desktop is licensed under the [MIT License](LICENSE). Third-party
dependencies retain their own licenses.
