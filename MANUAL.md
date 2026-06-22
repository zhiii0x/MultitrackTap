# Multitrack Tap — Manual

English · [繁體中文](MANUAL.zh-TW.md)

A user guide for recording, settings, output, and troubleshooting.
For the project overview see the [README](README.md).

---

## Requirements

- macOS **14.4 (Sonoma)** or later — required for Core Audio process taps
- Apple Silicon or Intel

## Install

A signed DMG and a Homebrew cask are planned. For now, build from source:

```bash
git clone https://github.com/zhiii0x/MultitrackTap.git
cd MultitrackTap

# Run the core unit tests (optional)
swift test

# Build and assemble the .app, then launch it
cd app
./make-app.sh
open "Multitrack Tap.app"
```

> The app must run from the assembled `.app` bundle (not a bare `swift run`) so
> macOS can attribute the audio-recording permission to it.

## First launch & permissions

Multitrack Tap needs two permissions, requested the first time you record a
matching source:

| Permission | Needed for | Where to grant |
|---|---|---|
| **Microphone** | recording the mic | System Settings → Privacy & Security → **Microphone** |
| **System Audio Recording** | recording system audio and any app | System Settings → Privacy & Security → **Screen & System Audio Recording** |

A source whose permission is missing shows a small amber **Allow** button in
place of its level meter — click it to grant (or to open the right Settings pane
if previously denied). Recording only the microphone needs no system-audio
permission.

> **Important — quit and reopen after granting System Audio Recording.** macOS
> applies this permission only to a *freshly launched* app. If you grant it while
> Multitrack Tap is already running, the app list stays empty and taps stay silent
> until you **⌘Q and reopen** — the app shows a one-click **Quit & Reopen** button
> when this is the case. You only need to do this once per Mac, right after the
> first grant.

> **Developer note:** `make-app.sh` signs **ad-hoc** by default, and macOS keys
> the System Audio Recording grant to the code signature — so it resets on every
> rebuild. For local development, sign with a stable identity to keep the grant:
> `SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./make-app.sh` (or a
> self-signed code-signing certificate).

## Recording

The main window:

1. **Output folder** — where recordings are saved (default `~/Recordings`).
   Use **Choose…** to change it. Each recording lands in its own timestamped
   subfolder, so sessions never overwrite each other.
2. **Sources** — the **Microphone**, **System audio**, and one row per app
   currently producing audio. Tick the sources you want. Each shows a live level
   meter so you can confirm it's active before recording.
3. **Record** — click **Record** (or press **⌘R**) to start. While recording,
   an elapsed clock and a breathing red dot show the live state, and the source
   list is locked. Click **Stop** (or **⌘R**) to finish.

You can also start/stop from the **menu-bar icon** without opening the window.

**Per-source resilience:** if a selected source can't be tapped at start (for
example, an app quit just beforehand), it is skipped and the rest keep
recording — an amber note shows which source was left out. Recording only aborts
if no source can be tapped.

## Settings (⌘,)

- **Sample rate** — 44.1 / 48 / 88.2 / 96 kHz. Every stem is captured (or
  resampled) to this rate and the Reaper project uses it, so all tracks line up.
- **Bit format** — 16-bit, 24-bit, or **32-bit float** (default; no clipping).
- **Generate Reaper project** — also write a ready-to-open `.rpp` next to the
  stems.
- **Reveal in Finder after recording** — open the output folder when you stop.

## Output

Each recording folder contains:

- **One WAV stem per source**, named by source (e.g. `Microphone.wav`,
  `Firefox.wav`, `System audio.wav`), all **zero-aligned** so they start at the
  same instant.
- **`project.rpp`** (if enabled) — open it in [REAPER](https://www.reaper.fm/)
  and every track is named and aligned at time 0. You can also drag the WAV
  stems straight into any DAW or video editor.

## Recordings history (⌘0)

The **Recordings** window lists past sessions with their date, duration, stem
count, format, and a button to reveal each in Finder. Removing an entry does not
delete the files on disk.

## Crash recovery

WAV headers are flushed periodically while recording, and on the next launch any
recording that was interrupted (crash / force-quit) has its stem headers
repaired automatically — so an interrupted session still leaves valid, playable
WAV files.

## Troubleshooting

- **A source keeps showing "Allow" / no system audio is captured** — the System
  Audio Recording permission isn't granted. Click **Allow**, or grant it in
  System Settings → Privacy & Security → Screen & System Audio Recording. (Devs:
  see the ad-hoc-signing note above — rebuilding resets the grant.)
- **Granted System Audio Recording, but the app list is empty / nothing records**
  — macOS applies the grant only to a freshly launched app. **Quit (⌘Q) and
  reopen** Multitrack Tap (or use the **Quit & Reopen** button shown in the empty
  list). Required once per Mac, right after the first grant. If it still won't
  take, reset and re-grant: `tccutil reset All com.github.zhiii0x.multitracktap`,
  then reopen and grant again.
- **An app isn't in the Sources list** — only apps *currently producing audio*
  appear. Start playback in the app and press the **Refresh** (↻) button. Apps
  that render audio in helper processes (Chrome/Arc/Electron, browser-based
  meeting tools) are captured by matching all of the app's audio processes.
- **Recording sounds too fast/slow** — fixed: process-tap stems now use the
  output device's true sample rate, so they no longer get mis-tagged. If you
  built an older version, rebuild from `main`.
- **Stems don't line up** — all sources share one host-time reference clock and
  each stem is padded with leading silence to start at project time 0; this is
  validated by the unit tests.

## About

**About Multitrack Tap** (app menu) shows the version and links to the project
and license.

## License & credits

[MIT](LICENSE) © 2026 Zhiii. The Core Audio process-tap and audio-process
enumeration code is adapted from [AudioCap](https://github.com/insidegui/AudioCap)
by Guilherme Rambo ([BSD-2-Clause](THIRD-PARTY-LICENSES.md)).
