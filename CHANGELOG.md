# Changelog

Versions of StillCore LTR. The release workflow publishes the section that
matches the tag, so keep the heading format `## [x.y.z] - YYYY-MM-DD`.

For differences from the original StillCore, see [docs/FORK.md](docs/FORK.md).


## [1.1.0] - 2026-11-21

Based on StillCore 2.0.0.

### New from upstream StillCore 2.0

- Top processes by CPU, GPU, memory or CPU power. Filter by application,
  process name or PID; quit a process or apply a background policy.
- CPU power through a separate on-demand helper.
- Chip power as stacked CPU, GPU and Neural Engine areas.
- Battery drain in mAh, charge above 100%, and battery details without a
  tracking session.
- Compact toolbar in the floating window; `--floating` opens it on launch.
- `Cmd-K` clears chart history.
- Implausibly low CPU and GPU temperatures are filtered out.
- Lower sampling overhead.
- New app icon.

### LTR

- The new CPU power helper uses LTR identifiers, so it does not interfere
  with an installed original StillCore.
- Fixed helper registration in `StillCoreLTR.app`: the helper check looked for
  an executable named `StillCore`.
- History recording uses the new macmon 0.10 metrics in the app and in the
  battery helper.
- Debug and Release builds use separate battery tracker labels again.
- New README and About text.

### Known issues

- The icon does not have the LTR mark in this version.


## [1.0.0] - 2026-09-06

First StillCore LTR release, based on StillCore 1.3.

- Recorded history and consumption reports by day, month, quarter and year,
  with print, PDF and CSV export.
- History keeps recording through the battery helper while the app is closed.
- Own bundle id (`com.ftech.StillCoreLTR`), installs beside the original.
- No automatic updates.
