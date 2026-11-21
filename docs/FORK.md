# How StillCore LTR differs from StillCore

StillCore LTR is a fork of StillCore (upstream repository `homm/StillCore`).
LTR stands for Long Term Report. The fork keeps all features of the original and
adds recorded history with consumption reports.

This page lists every intended difference. Anything not listed here should
match upstream. The last merged upstream version is **StillCore 2.0.0**.


## For users

### Added

- **History recording.** The app records metrics while it runs. The battery
  helper records them every 30 seconds while the app is closed. Data is stored
  in SQLite: minute buckets for 14 days, hour buckets for five years.
- **Reports.** Open them with **Reports...** in the menu bar menu, the toolbar
  button, or `Cmd-R`. Reports cover a day, a month, a quarter or a year. They
  show energy in Wh (CPU, GPU, ANE, rest of chip, outside the chip), average and
  peak system power, CPU and GPU usage and temperature, battery discharge, time
  on battery and data coverage.
- **Report export.** Print, PDF and CSV.
- **Recording controls.** Turn recording off or delete the history at the
  bottom of the report window.

### Removed

- **Automatic updates.** LTR has no Sparkle, no update feed and no
  **Check for Updates...** menu item. Get new versions from
  [the LTR releases page](https://github.com/GregoryPletnev/StillCoreLTR/releases).

### Changed

- **Name and icon.** The app is `StillCoreLTR.app`, shown as "StillCore LTR".
  The icon is the LTR icon with the "LTR" mark, not upstream's icon.
- **Chip summary in the header.** It reads `8P+2E CPU · 16-core GPU` instead of
  upstream's `4E 8P 16G`.
- **Side-by-side install.** LTR and the original can be installed at the same
  time. They do not share helpers, settings or data.


## For developers

### Identity

| Item                         | StillCore (upstream)                          | StillCore LTR                                       |
|------------------------------|-----------------------------------------------|-----------------------------------------------------|
| Product / app bundle         | `StillCore.app`                               | `StillCoreLTR.app` (Xcode scheme is still `StillCore`) |
| Bundle id (Release)          | `com.github.homm.StillCore`                   | `com.ftech.StillCoreLTR`                            |
| Bundle id (Debug)            | `com.github.homm.StillCore.Debug`             | `com.ftech.StillCoreLTR.Debug`                      |
| Battery tracker agent label  | `com.github.homm.StillCore.BatteryTracker` (same for Debug and Release) | `<bundle id>.BatteryTracker`, so Debug and Release are separate |
| PowerMetrics daemon label    | `com.github.homm.StillCore.PowerMetrics`      | `com.ftech.StillCoreLTR.PowerMetrics`               |
| Helper registrations defaults suite | `com.github.homm.StillCore.HelperRegistrations` | `com.ftech.StillCoreLTR.HelperRegistrations` |
| Data directory               | `~/Library/Application Support/com.github.homm.StillCore` | `~/Library/Application Support/com.ftech.StillCoreLTR` |
| Version line                 | 1.x, 2.x                                      | Restarted at 1.0.0                                  |
| Release tags                 | `v2.0.0`                                      | `ltr-v1.1.0`                                        |
| Disk image                   | `StillCore.dmg`                               | `StillCoreLTR.dmg`                                  |
| Updates                      | Sparkle + `docs/appcast.xml`                  | None; GitHub releases only                          |

### Fork-only files

- `StillCore/MetricsHistoryRecorder.swift`, `StillCore/MetricsHistoryService.swift`:
  in-app recording.
- `StillCore/Report*.swift`: the report window, charts, tables, printing and export.
- `BatteryTrackerHelper/HelperHistoryRecorder.swift`: recording while the app
  is closed.
- `BatteryTrackingShared/MetricsHistory*.swift`, `BatteryTrackingShared/SQLiteDatabase.swift`:
  storage and aggregation shared by the app and the helper.
- `.github/workflows/release.yml`, `CHANGELOG.md`, `docs/RELEASING.md`, this file.

### Upstream files with fork changes

| File | Change |
|------|--------|
| `StillCore/StillCoreApp.swift` | Starts history recording; adds the Reports menu item, toolbar button and `Cmd-R`; removes Sparkle; LTR window title, chip summary and About text. |
| `StillCore/MenuPresentationController.swift` | Activation policy goes through `AppActivationPolicy`, so the report window and the floating window do not hide each other's Dock icon. |
| `StillCore/HelperService.swift` | Fingerprints the app executable by its real name (`StillCoreLTR`), not a hard-coded `StillCore`. |
| `BatteryTrackerHelper/BatteryTrackerEngine.swift`, `main.swift` | The engine gets a history callback; `main.swift` connects it to `HelperHistoryRecorder`. This keeps the engine buildable without MacmonSwift for `make test`. |
| `BatteryTrackingShared/BatterySession.swift` | Agent label and data directory come from the bundle id. |
| `PowerMetricsShared/PowerMetricsProtocol.swift`, `PowerMetricsLaunchDaemon/*.plist` | LTR daemon label. |
| `StillCore.xcodeproj/project.pbxproj` | Product name, bundle ids, version, no Sparkle package, "Configure LaunchAgent" build phase that sets the agent label per configuration. The phase must stay in the `StillCore` target's `buildPhases` list; a merge can drop it silently. |
| `StillCore-Info.plist` | `CFBundleDisplayName`, no `SU*` Sparkle keys. |
| `Makefile` | `PRODUCT := StillCoreLTR`, `ADHOC=1` for unsigned CI builds. |
| `Tests/PowerMetricsChecks.swift` | Expects the per-configuration agent label and LTR identifiers. |
| `README.md` | Own README for LTR. Keep it when you merge; take only new feature descriptions from upstream. |
| `AGENTS.md` | LTR names. |
| `LICENSE` | Adds the FTECH copyright line; the upstream line stays. |
| `Licenses/` | No `Sparkle.txt`. |
| `docs/appcast.xml`, `.github/workflows/appcast.yml` | Removed. |
| `docs/index.html` | Removed: the upstream product page. On a merge, resolve modify/delete conflicts by keeping it deleted. |
| `StillCore/Assets.xcassets/AppIcon.appiconset` | LTR icon (`image.png`, 512×512, source in `source.svg`). Upstream removed it in 2.0. |
| `scripts/build-assets.sh` | Compiles only `Assets.xcassets`. Upstream's `StillCore/AppIcon.icon` stays in the repository but is not used. |
| `assets/Assets.car`, `assets/AppIcon.icns` | Compiled from the LTR icon. If upstream changes them, keep ours and run `make assets` again. |

### App icon

The icon comes from `StillCore/Assets.xcassets/AppIcon.appiconset`. The app does
not compile asset catalogs at build time; it copies the precompiled
`assets/Assets.car` and `assets/AppIcon.icns`. After you change the icon or any
image in `Assets.xcassets`, run `make assets` and commit both files.

`make assets` installs the `scar` tool, which needs Rust 1.87 or newer. `scar`
only makes `Assets.car` smaller. Without it, you can run the `actool` command
from `scripts/build-assets.sh` and copy `Assets.car` and `AppIcon.icns` from its
output directory to `assets/`.


## Syncing with upstream

```sh
git remote add upstream https://github.com/homm/StillCore.git
git config remote.upstream.tagOpt --no-tags   # upstream v* tags clash with LTR versions
git fetch upstream
git switch -c merge-upstream-<version>
git merge upstream/main
```

Expect conflicts in `project.pbxproj`, `StillCoreApp.swift`, `Makefile`,
`README.md`, `Package.resolved`, `docs/index.html`, `assets/` and
`scripts/build-assets.sh`. After the merge:

1. Search for new upstream identifiers and rename them to `com.ftech.StillCoreLTR`:
   `git grep -n 'com.github.homm'`.
2. Search for a reintroduced Sparkle: `git grep -n -i 'sparkle\|SUFeed\|appcast'`.
3. Search for a hard-coded app name: `git grep -n 'MacOS/StillCore'`.
4. Check that the "Configure LaunchAgent" phase is still in the `StillCore`
   target: `grep -c 'Configure LaunchAgent' StillCore.xcodeproj/project.pbxproj`
   must print 3.
5. Build the fork-only files. They use the `macmon` `Metrics` API directly
   (`MetricsHistoryRecorder.swift`, `HelperHistoryRecorder.swift`), and upstream
   can remove helpers that only LTR uses. Run `make test` and `make dmg ADHOC=1`.
6. Update the "last merged upstream version" at the top of this page and add a
   `CHANGELOG.md` entry.
