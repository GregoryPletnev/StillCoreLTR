# StillCore LTR

**LTR stands for Long Term Report.** This is the long term reporting build of
StillCore: it keeps everything the original does and adds recorded history, so
you can look back at power use over a day, a month, a quarter or a year instead
of only at the last few minutes. See [History and Reports](#history-and-reports).

StillCore is built for continuous Apple Silicon monitoring with low overhead. It stays in the macOS menu bar, quietly tracks what the Mac is doing, and is ready when something suddenly feels off: the laptop gets warm, battery drain jumps, or a background task briefly spikes power usage.

It’s designed for everyday monitoring rather than deep profiling. It is built on top of [macmon](https://github.com/vladkens/macmon), which provides the core Apple Silicon metrics.


## Main features:

- System and chip power with stacked CPU, GPU and Neural Engine readings.
- CPU and GPU frequency and usage on the combined chart.
- Temperature charts.
- Top processes by CPU and GPU usage, memory or CPU power, with controls to quit them or limit their power use.
- Adjustable update interval from 100 ms to 10 seconds.
- Customizable menu bar metrics, a battery icon or percentage, and an optional always-open window.
- Battery drain tracking with active and sleep time since unplugging.
- Detailed battery charge statistics.
- Switch between Automatic and Power Save modes for the current power source.
- **LTR:** recorded history with consumption reports by day, month, quarter and year, with tables, charts, printing and PDF or CSV export.

<p align="center">
<img width="466" src="docs/app.png" alt="StillCore LTR app screenshot">
</p>


## Download

Prebuilt downloads are available on the GitHub releases page:
https://github.com/GregoryPletnev/StillCoreLTR/releases

StillCore LTR is a fork of [homm/StillCore](https://github.com/homm/StillCore).
Releases of the original are published separately, on its own releases page.
See [How LTR differs from StillCore](docs/FORK.md) for the full list of differences.

The two can be installed side by side: LTR ships as `StillCoreLTR.app` under its
own bundle identifier, with its own helpers and its own stored data. StillCore LTR
has no automatic updates, so check the releases page for new versions.

Requires an Apple Silicon Mac with macOS 14 or newer.


## Features

<img width="420" align="right" src="docs/power-and-activity.png" alt="Power charts with a marker on a spike">

### Power and Activity

Compare total system power with chip power and see how much the CPU, GPU, and Neural Engine contribute. Use the chart marker to see what was happening when power spiked.

<br clear="all">


<img width="420" align="right" src="docs/processes.png" alt="Top Processes sorted by CPU power">

### Top Processes

Sort processes by CPU usage, GPU usage, memory, or CPU power to find what’s using the most resources. Filter by application, process name, or PID. Quit a process or apply a background policy from the list.

<br clear="all">


<img width="400" align="right" src="docs/battery.png" alt="Battery popover during an unplugged session">

### Battery Charge and Drain

See how much charge remains and how much you’ve used since unplugging. The battery popover also shows how long your Mac was awake and asleep during that session.

macOS can report 100% below full capacity. StillCore can show charge above that threshold, so you can see it drop after unplugging while macOS still reads 100%.

<br clear="all">


<img width="248" align="right" src="docs/menu.png" alt="Menu bar metrics">

### Menu Bar and Floating Window

Choose which metrics appear in the menu bar so you can check them at a glance. Detach the main window to keep the charts visible while you work.

<br clear="all">


## History and Reports

StillCore records what it measures so you can look back at it later.

Open **Reports...** from the menu bar icon, or press `Cmd-R`. Pick a day, month,
quarter or year, then step through periods with the arrows. Each report shows:

- Energy in watt-hours, split into CPU, GPU, ANE, the rest of the chip, and
  everything outside it.
- Average and peak system power.
- Average CPU and GPU utilisation and temperature.
- Battery discharge and how long the Mac ran unplugged.
- Coverage, that is how much of the period was actually recorded.

Use **Print** for paper or a system PDF, **PDF** to export the same pages to a
file, or **CSV** to get every figure for a spreadsheet.

### How recording works

Two processes write the history, and neither needs the other:

- The app records at its current update interval while it runs.
- The battery helper records once every 30 seconds while the app is closed, so
  a report does not go blank when you quit StillCore.

Measurements are stored in one minute buckets and rolled up into hours. Minute
buckets are kept for 14 days and hour buckets for five years, which comes to a
few megabytes per year. The database lives next to the battery tracker state:

```
~/Library/Application Support/com.ftech.StillCoreLTR/metrics-history.sqlite
```

Recording can be turned off, and the history deleted, at the bottom of the
report window.


## Why I Built It

I often work on a laptop and want to understand what is happening with energy usage. I used MX Power Gadget for this, but later found that it reports misleadingly low power for itself while consuming a lot of CPU power in practice[^mx-power-gadget]. That led me through several monitoring experiments, and eventually to the decision that I could build something better for my own workflow.

I wanted StillCore to stay in the menu bar all day without adding much overhead. In my tests, with StillCore running in the menu bar and updating once a second, chip power matched the idle baseline of 0.17 W. With the window open, it rose to 0.21 W. For comparison, chip power was lower with StillCore updating every 100 ms (0.47 W) than with Activity Monitor updating once a second (0.53 W), with their windows open.

[^mx-power-gadget]: MX Power Gadget uses `powermetrics` for its measurements, but according to this [Habr article in Russian](https://habr.com/ru/articles/858736/), it starts a new `powermetrics` process for each sample. Because `powermetrics` has a relatively expensive startup phase, the utility can consume a few watts in practice even when its own charts show near-zero power.

Here are some cases where StillCore helped me track down unexpected power use.

#### Codex GPU usage

StillCore’s GPU charts showed spikes up to 1.5 W on my M4 Pro while Codex was thinking. After some experimenting, I traced the extra GPU load to a tiny spinner in the sidebar. I [filed an issue](https://github.com/openai/codex/issues/16857) and started hiding the sidebar while Codex worked. The bug has since been fixed.

#### Mission Control on macOS 27

I traced CPU spikes during trackpad gestures to `MenuBarAgent`. It used one CPU core while I moved my fingers to open Mission Control or App Exposé, then dropped as soon as I held them still. I used StillCore to apply a background task policy to the process and limit its impact.

#### Playing Civilization VI over the Atlantic

A transatlantic flight lasts about ten hours. By measuring how much power Civilization VI draws with StillCore, I can tune the game settings so I can play for the whole flight on a single charge. 😆


## Development

Releases are published from tags by GitHub Actions; see [docs/RELEASING.md](docs/RELEASING.md).
To merge a new upstream version, follow [Syncing with upstream](docs/FORK.md#syncing-with-upstream).

### Build From Source

Building from source requires Xcode with Swift 6 support and network access for Swift Package dependencies.

Create a local DMG from source:

```sh
make dmg
```

This creates the Release `StillCoreLTR.dmg`.

Remove build artifacts:

```sh
make clean
```


### Local Development

Development builds use `CONFIGURATION=Debug` by default.

Install repository-managed Git hooks once per checkout:

```sh
make install-hooks
```

Make commands:

```sh
# Build and run from the terminal
make run

# Build and run the Release configuration
make run Release

# Build and open the app bundle
make open-app

# Profile a Release build with Instruments Time Profiler
make profile
```


### Local Metrics Core Development

Use `LOCAL=1` to develop or test StillCore with local changes to `macmon`.

Additional requirements:

- Rust toolchain with Cargo
- Local checkouts of `macmon` and `macmon-bindings` next to this repository

Clone the sibling repositories and build the local `macmon` xcframework:

```sh
pushd ..
git clone https://github.com/homm/macmon.git
git clone https://github.com/homm/macmon-bindings.git
make -C macmon xcframework
popd
```

Build and open StillCore against the local metrics core:

```sh
make -C ../macmon xcframework
make open-app LOCAL=1
```

`LOCAL=1` uses `StillCore.local.xcworkspace`, expects `../macmon/dist/CMacmon.xcframework`,
and uses the sibling `../macmon-bindings` checkout.


## License

StillCore and StillCore LTR are released under the MIT License. The metrics core is built on [macmon](https://github.com/vladkens/macmon), sensor tables adapted from [Stats](https://github.com/exelban/stats). StillCoreLTR.app bundles the license notices for [macmon](Licenses/macmon.txt), [Stats](Licenses/Stats.txt), and [DGCharts](Licenses/DGCharts.txt).
