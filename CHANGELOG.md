# Changelog

Notable changes to NetPilot Desktop are recorded here by version. These are
**test builds**, not production releases. The repository's tagged release notes
also include links to individual commits. Features present in source code are
identified separately from features available in downloadable packages.

## [Unreleased]

### Documentation and release process

- Added this versioned changelog and expanded the GitHub README with setup,
  testing, contribution, and release instructions.
- Release notes are generated from commits between version tags; rerunning a
  successful tag workflow refreshes the existing release notes and assets.

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

[Unreleased]: https://github.com/mahanpyk/netpilot/compare/v1.0.1-test.3...main
[v1.0.1-test.3]: https://github.com/mahanpyk/netpilot/compare/v1.0.1-test.2...v1.0.1-test.3
[v1.0.1-test.2]: https://github.com/mahanpyk/netpilot/compare/v1.0.1-test.1...v1.0.1-test.2
[v1.0.1-test.1]: https://github.com/mahanpyk/netpilot/tree/v1.0.1-test.1
