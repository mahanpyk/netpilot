# Changelog

Notable changes to NetPilot Desktop are recorded here by version. These are
**test builds**, not production releases. The repository's tagged release notes
also include links to individual commits. Features present in source code are
identified separately from features available in downloadable packages.

## [Unreleased]

## [v1.0.1-test.6] - 2026-11-07

### Added

- Export destination/site rules from Settings → Site transfer to a JSON file
  and import them on another NetPilot installation. Choose local networks during
  import; preserve names,
  dependencies, and LAN IPv4 pins while refreshing DNS. Existing rules remain,
  duplicates are skipped, and imported rules start paused unless enabled in
  the import dialog.

### Release scope

- macOS remains Rules-only, Apple Development signed and unnotarized.
- Windows packages retain the test-signed WFP driver and require Test Mode.
- Backup files cover destination rules; app rules and global settings are
  excluded. LAN hostname mappings require macOS.

### Release status

- Published macOS and Windows test packages after both CI build gates passed
  in [run 42338038278](https://github.com/mahanpyk/netpilot/actions/runs/42338038278).
  All six release assets and the five package SHA-256 checksums were verified;
  the downloaded macOS app passed strict signature verification and reports
  version `1.0.1+5`.
- Live two-device transfer and Windows runtime acceptance remain pending.

## [v1.0.1-test.5] - 2026-11-05

### Added

- On macOS, keep NetPilot available from a menu bar icon after its window is
  closed. Reopen the window or quit the app from the icon.
- Add a saved System Default / Custom Routing mode to suspend or restore all
  custom destination rules without changing each rule's enabled setting.
- Add a macOS Launch at login setting backed by the system login-item service.

### Fixed

- The macOS menu bar icon now appears on launch. Removed an invalid Flutter
  delegate call that interrupted startup, and use the bundled NetPilot icon.
- System Default now skips an unavailable unsigned app proxy and warns clearly
  if the privileged helper cannot remove managed routes.
- Route and hostname cleanup run independently, so a failure in one does not
  prevent the other from being removed.
- Returning to Custom no longer applies pending app-rule edits without
  **Apply & Restart Proxy**.
- Helper Repair waits for the old daemon to stop and retries a transient
  registration failure; Quit waits for an in-progress routing change.
- Routing mode preferences survive an interrupted write and recover from
  malformed JSON.

### Release scope

- The macOS DMG contains destination routing and menu bar controls but does
  not include App Routing. It is Apple Development signed and unnotarized.
- Windows packages remain test-signed and require Test Mode. Windows live
  installation and routing acceptance are still pending.

### Release status

- Published macOS and Windows test packages after both CI build gates passed
  in run `42038065720`. The Release includes SHA-256 checksums and detailed
  notes from this version's changelog. Live Windows acceptance remains pending.

## [v1.0.1-test.4] - 2026-10-17

### Added

- macOS LAN hostname mappings: save a private address returned by the selected
  interface's DNS, or enter an IPv4 override when DNS is missing/incorrect.
  The signed helper manages an owned hosts block while preserving manual entries.

### Fixed

- macOS DNS now honors the selected network interface and runs off the UI thread.
- DNS/helper waits no longer freeze the window. URL scans have overall deadlines
  and are skipped when the parent cannot resolve or its route cannot be applied.
- Dismissing a rule editor during DNS work no longer triggers widget errors.

### Documentation and release process

- Licensed the project under MIT.
- Added this versioned changelog and expanded the GitHub README with setup,
  testing, contribution, and release instructions.
- Release notes are generated from commits between version tags; rerunning a
  successful tag workflow refreshes the existing release notes and assets.

### Release status

- Published macOS and Windows test packages with app version `1.0.1+3` after
  both CI build gates passed in run `39022163155`. Install/repair
  the macOS helper to enable hostname mappings after upgrading. Live browser
  and Windows routing acceptance remain pending.

## [v1.0.1-test.3] - 2026-09-26

### Added

- Route changes now reconnect affected Safari and Chromium networking services
  on macOS, allowing open browser tabs to establish new connections over the
  updated route without closing the whole browser.
- Windows source now verifies destination routes and refreshes affected
  Chromium networking services after route changes. Live Windows acceptance
  is still pending.

### Fixed

- macOS checks the actual interface and gateway for desired routes, repairs
  missing managed routes, and reports verification failures in Diagnostics.
- Windows compiler fixes for process-name handling and case folding.

### Release status

- macOS Rules-only DMG and Windows test packages were published. The macOS DMG
  does not include per-app routing. The Windows WFP driver is test-signed, and
  its installation and live routing have not yet passed the integration gate.

## [v1.0.1-test.2] - 2026-09-21

### Fixed

- Initialize Flutter's macOS generated build configuration on clean CI runners
  before packaging the signed Rules-only DMG.

### Release status

- First complete tagged prerelease with macOS and Windows test assets and
  SHA-256 checksums. Per-app routing remained unavailable in the macOS DMG;
  Windows live installation and routing remained unverified.

## [v1.0.1-test.1] - 2026-09-21

### Added

- Initial macOS destination routing for hostnames, URLs, IPv4 addresses, and
  CIDR ranges, with network inventory and a signed privileged route helper.
- URL dependency discovery and independently switchable sub-rules; route
  deduplication and explicit conflict reporting.
- Dark/light desktop UI, diagnostics, and the Apps, Rules, Networks, and
  Settings sections.
- Development implementations of macOS per-app Transparent Proxy routing and
  Windows destination/per-app routing with a service, WFP driver, and installer.
- Tagged test-release automation for macOS and Windows packages.

### Release status

- **Tag only; no GitHub release was published.** The first tag's Windows build
  and Flutter checks passed, but macOS packaging failed because a clean runner
  lacked Flutter-generated build configuration files. The fix is in
  `v1.0.1-test.2`.

[Unreleased]: https://github.com/mahanpyk/netpilot/compare/v1.0.1-test.5...develop
[v1.0.1-test.5]: https://github.com/mahanpyk/netpilot/compare/v1.0.1-test.4...v1.0.1-test.5
[v1.0.1-test.4]: https://github.com/mahanpyk/netpilot/compare/v1.0.1-test.3...v1.0.1-test.4
[v1.0.1-test.3]: https://github.com/mahanpyk/netpilot/compare/v1.0.1-test.2...v1.0.1-test.3
[v1.0.1-test.2]: https://github.com/mahanpyk/netpilot/compare/v1.0.1-test.1...v1.0.1-test.2
[v1.0.1-test.1]: https://github.com/mahanpyk/netpilot/tree/v1.0.1-test.1
