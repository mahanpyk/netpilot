# Destination-rule transfer verification

Date: 2026-11-06. Journeys derived from the request to move saved sites between
NetPilot installations; no separate source plan was supplied.

## Journeys and evidence

| Guarantee | Evidence | Result |
| --- | --- | --- |
| Export and restore site inputs, names, dependencies, switches and explicit pins without transferring cached DNS, applied status or old IDs | `test/rules_transfer_test.dart` | PASS |
| Reject malformed, unsupported, oversized and partly invalid backups as a whole | `test/rules_transfer_test.dart`, `test/rules_transfer_file_test.dart` | PASS |
| Map source networks explicitly, retain existing sites, skip duplicates, refresh DNS and default to paused | `test/rules_transfer_test.dart`, `test/rules_transfer_actions_test.dart` | PASS |
| Optional activation respects disabled parent/child settings | `test/rules_transfer_test.dart` | PASS |
| Canceled import/export and failed reads/writes do not report success | `test/rules_transfer_file_test.dart`, `test/rules_transfer_actions_test.dart` | PASS |
| Persian names survive UTF-8 file transfer | `test/rules_transfer_file_test.dart` | PASS |
| Failed import persistence leaves controller state intact | `test/rules_transfer_test.dart` | PASS |

## TDD record

- RED: `flutter test test/rules_transfer_test.dart` failed compilation because
  `RulesTransfer` and `NetPilotController.importRules` did not exist.
- GREEN: `flutter test --no-pub test/rules_transfer_test.dart` passed all four
  initial tests after implementing the portable codec and controller import.
- UI RED: `flutter test --no-pub test/rules_transfer_actions_test.dart` failed
  compilation because the file adapter and transfer widget did not exist.
- UI GREEN: the same command passed all three widget tests after implementation
  and correcting test pumping around the active progress indicator.
- Expanded targeted validation:
  `flutter test --no-pub test/rules_transfer_test.dart test/rules_transfer_actions_test.dart test/rules_transfer_file_test.dart`
  passed all 14 tests, including additional file and invalid-input scenarios.
- No checkpoint commits, staging, or publication were performed.

## Final verification

- `flutter analyze --no-pub`: no issues.
- `flutter test --no-pub --coverage`: **86 tests passed**.
- `coverage/lcov.info`: codec 66/67 lines (98.5%); file adapter 10/10 (100%);
  transfer UI 86/91 (94.5%); full destination controller 476/558 (85.3%).
- `FLUTTER_SWIFT_PACKAGE_MANAGER=false flutter build macos --debug --no-pub --config-only`
  followed by
  `xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS' -derivedDataPath build/macos CODE_SIGNING_ALLOWED=NO build -quiet`:
  **PASS**. Plugin emits an upstream `allowedFileTypes` deprecation warning.
  CocoaPods integration retained; no Swift Package Manager migration.
- `git diff --check`: PASS. Reviewed changes for validation, privilege boundaries,
  registration, cancellation and mounted checks. Secret-pattern scan of the new
  implementation/tests returned no matches.

Local checks pass. Native file-dialog registration compiles on macOS; actual
file dialogs, a two-device transfer and Windows runtime behavior have not been
exercised. No installed app was replaced and no release was published.

## Settings placement follow-up

Moved the transfer controls to Settings → Site transfer. The existing home
navigation test first failed because Import was still visible in Rules, then
passed after the move. `flutter test --no-pub test/widget_test.dart test/rules_transfer_actions_test.dart`
passes all 10 tests; `flutter analyze --no-pub` reports no issues. The portable
format and controller behavior did not change. No new native build or installed
app update was performed for this UI-only follow-up.

## Prerelease gate (2026-11-07)

Prepared `v1.0.1-test.6`, app version `1.0.1+5`. Revalidated using local Flutter
3.47.9 / Dart 3.13.7 without upgrading dependencies or changing the CI SDK
(Flutter 3.47.4). Analyzer: PASS, all 86 tests with coverage: PASS, unsigned
macOS Debug Xcode build: PASS, diff/secret/tooling review: PASS. Transfer codec
coverage is 67/67 lines (100%), file adapter 10/10 (100%), transfer UI 86/91
(94.5%), destination controller 476/558 (85.3%). Tagged CI must pass both
platforms and verify the signed packages before publication is considered
complete. Real-device acceptance remains separate from the release build gate.


## Published prerelease

`v1.0.1-test.6` was published by successful CI run `42338038278` from tag commit
`2b600efebfe52e4a167403a7c6c8e1d533b8bf1a` (feature commit `d6c4aa2`). macOS,
Windows, and publish jobs all finished successfully. Downloaded the CI artifacts
and the published SHA256SUMS manifest; verified all six release asset digests
against those local files and all five package hashes against the manifest.
The DMG app passed `codesign --verify --deep --strict`, and its Info.plist
reports version `1.0.1`, build `5`. The Windows portable ZIP passed CRC checks
for all 23 entries. Release metadata confirms `isPrerelease=true`,
`isDraft=false`. No installed app/helper was replaced and no live two-device
transfer or Windows runtime acceptance is claimed.

Release: https://github.com/mahanpyk/netpilot/releases/tag/v1.0.1-test.6
CI: https://github.com/mahanpyk/netpilot/actions/runs/42338038278
