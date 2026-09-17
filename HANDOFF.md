# NetPilot Desktop — Handoff

> **Keep this file current.** Any agent or developer that changes architecture, file layout, native contracts, models, or capabilities must update this document in the same change. See [`AGENTS.md`](AGENTS.md).

## Product goal

NetPilot helps developers who are connected to **Wi‑Fi (internet)** and **company LAN (intranet)** at the same time. Default macOS service order may send all traffic via Wi‑Fi, so intranet hosts become unreachable. NetPilot lets the user:

1. See currently active network interfaces.
2. Define destination rules (hostname / URL / IP / CIDR).
3. Force those destinations out the chosen LAN interface via specific routes — without flipping service order.

## Scope (MVP / v1)

| In scope | Out of scope (for now) |
|---|---|
| macOS 14+ | Windows |
| IPv4 | IPv6 |
| Hostname, URL (hostname only), IPv4, CIDR | URL path-based routing |
| Route reconcile via privileged helper | TLS MITM / HTTPS path inspection |
| Local rule persistence | Cloud sync / accounts |
| Simple desktop UI | Tray-only / menubar-only app |

## Architecture overview

```text
Flutter UI
  → NetPilotController / DestinationParser / RouteReconciler
  → MethodChannel + EventChannel
       → NetworkInventoryService (SystemConfiguration)
       → HelperXPCClient → NetPilotHelper (SMAppService / NSXPC)
            → /sbin/route (fixed argv only)
```

```mermaid
flowchart LR
    FlutterUI[Flutter UI] --> RuleController[NetPilotController]
    RuleController --> DestinationResolver[DestinationParser + resolveHost]
    RuleController --> PlatformBridge[NetworkPlatform]
    PlatformBridge --> NetworkInventory[NetworkInventoryService]
    PlatformBridge --> XPCClient[HelperXPCClient]
    XPCClient --> PrivilegedHelper[NetPilotHelper]
    PrivilegedHelper --> RouteTable[macOS route table]
```

## Repository map

```text
netpilot_desktop/
├── AGENTS.md
├── HANDOFF.md
├── README.md
├── pubspec.yaml
├── lib/
│   ├── main.dart
│   ├── app/
│   │   ├── netpilot_app.dart
│   │   └── theme.dart
│   ├── core/
│   │   ├── models/
│   │   │   ├── network_interface_info.dart
│   │   │   └── routing_rule.dart
│   │   ├── platform/
│   │   │   └── network_platform.dart
│   │   └── utils/
│   │       ├── destination_parser.dart
│   │       └── route_reconciler.dart
│   └── features/
│       ├── home/
│       │   └── home_page.dart
│       ├── network_interfaces/
│       │   └── presentation/interface_card.dart
│       └── routing_rules/
│           ├── data/rules_repository.dart
│           ├── domain/netpilot_controller.dart
│           └── presentation/
│               ├── rule_editor_sheet.dart
│               └── rule_tile.dart
├── test/
│   ├── destination_parser_test.dart
│   ├── route_reconciler_test.dart
│   ├── netpilot_controller_test.dart
│   └── widget_test.dart
└── macos/
    ├── scripts/
    │   ├── embed_helper.sh          # Build-phase: compile + embed helper
    │   └── patch_pbxproj.py         # Sanity check for native file refs
    ├── NetPilotHelper/
    │   ├── main.swift
    │   ├── HelperDelegate.swift
    │   ├── Info.plist
    │   ├── NetPilotHelper.entitlements
    │   └── com.netpilot.netpilotDesktop.helper.plist
    ├── Runner/
    │   ├── MainFlutterWindow.swift  # Registers NetPilotPlugin
    │   ├── NetPilotPlugin.swift
    │   ├── NetworkInventoryService.swift
    │   ├── HelperXPCClient.swift
    │   ├── NetPilotShared/
    │   │   ├── NetPilotXPCProtocol.swift
    │   │   ├── RouteSpec.swift
    │   │   └── RouteManager.swift
    │   └── *entitlements            # App Sandbox OFF for MVP networking/helper
    └── RunnerTests/
        ├── RunnerTests.swift
        └── RouteManagerTests.swift
```

## Data models

### NetworkInterfaceInfo

| Field | Type | Notes |
|---|---|---|
| id | String | BSD name |
| name | String | SC user-defined name |
| interfaceName | String | BSD name |
| kind | `wifi` \| `ethernet` \| `other` | Heuristic |
| ipv4Addresses | `List<String>` | |
| gateway | `String?` | |
| dnsServers | `List<String>` | |
| isDefaultRoute | bool | Primary IPv4 default |
| isActive | bool | Has IPv4 |

### DestinationKind

`hostname` | `url` | `ipv4` | `cidr`

URL → hostname only (path/query discarded). Parser checks URL scheme **before** CIDR slash.

### RoutingRule / DesiredRoute

See `lib/core/models/routing_rule.dart`. Desired routes carry `tag = netpilot:<ruleId>`.

## Persistence

- App support dir / `netpilot_rules.json` via `path_provider`
- `FileRulesRepository` / `MemoryRulesRepository` (tests)

## Platform contracts

### MethodChannel: `com.netpilot.netpilotDesktop/network`

| Method | Args | Result |
|---|---|---|
| `listInterfaces` | — | `List<Map>` |
| `resolveHost` | `{ host, interfaceId? }` | `{ ips: List<String> }` |
| `getHelperStatus` | — | `{ installed, enabled, status, message? }` |
| `installHelper` | — | status map (+ `ok` when possible) |
| `reconcileRoutes` | `{ desired: List<RouteSpec> }` | `{ ok, added, removed, errors }` |

### EventChannel: `com.netpilot.netpilotDesktop/networkEvents`

Emits `{ type: 'interfacesChanged' }` on SCDynamicStore changes.

### XPC (app ↔ helper)

- Mach service: `com.netpilot.netpilotDesktop.helper`
- Protocol methods: `ping`, `listManagedRoutes`, `reconcileDesired`
- Launchd plist name: `com.netpilot.netpilotDesktop.helper.plist`
- Helper binary path in app: `Contents/MacOS/NetPilotHelper`
- Plist embedded at: `Contents/Library/LaunchDaemons/`

**Security:** Destination must be IPv4 CIDR; gateway optional IPv4; interface BSD-like name; tag must start with `netpilot:`. Fixed `/sbin/route` argv only. Managed inventory persisted under `/Library/Application Support/NetPilot/managed_routes.json`.

## Privileged helper build

Runner build phase **Embed NetPilot Helper** runs `macos/scripts/embed_helper.sh`, which `swiftc`-compiles helper sources into the app bundle and copies the launchd plist. Install at runtime via `SMAppService.daemon(plistName:)`.

Requires matching Team ID signatures on app + helper for real privileged install. Without signing, inventory + UI work; apply may fail until Login Items / signing are configured.

## Signing & entitlements

- App: `com.netpilot.netpilotDesktop`
- Helper: `com.netpilot.netpilotDesktop.helper`
- Deployment target: **macOS 14.0**
- App Sandbox disabled in Debug/Release entitlements for MVP (network inventory + helper install)

## UI map

- Home: Interfaces pane + Rules pane
- Add/Edit sheet: destination, label, interface, resolve preview, save & apply
- Helper banner with Install when not enabled

## Testing

```bash
PUB_HOSTED_URL=https://pub.dev flutter pub get   # if corporate mirror fails
flutter analyze
flutter test
flutter build macos --debug
```

XCTest: `RouteSpec` validation + `RouteManager` reconcile argv (`macos/RunnerTests/RouteManagerTests.swift`).

## Known limitations

- Hostname → IP: CDN/shared IPs may mis-route unrelated hosts.
- `resolveHost` uses system DNS (interface-scoped DNS reserved for later).
- Helper install needs code signing + user Login Items approval.
- No path-level URL routing.

## Architecture decisions

| Decision | Choice | Why |
|---|---|---|
| Routing key | IP / CIDR after resolve | OS routes are L3 |
| Privilege | Helper + XPC + SMAppService | Persistent, least privilege |
| Service order | Unchanged | Specific routes override default |
| URL handling | Hostname only | No TLS MITM |
| Helper embed | Build-phase `swiftc` | Avoid fragile extra Xcode target with Flutter/Pods |

## Feature status

| Feature | Status |
|---|---|
| Handoff / agent docs | Done |
| Flutter feature layout | Done |
| Interface inventory (macOS) | Done |
| Rule CRUD + persistence | Done |
| Destination parser + resolve | Done |
| Privileged helper + XPC + embed | Done (signing TBD per machine) |
| Route reconcile | Done |
| Desktop UI | Done |
| Windows | Not started |
| IPv6 | Not started |

## Changelog

- **2026-09-17** — MVP implemented: Flutter UI/controller, macOS inventory plugin, privileged helper embed script, handoff docs. `flutter analyze` / `flutter test` / `flutter build macos --debug` verified.
- **2026-09-17** — Initial handoff drafted; implementation started.
