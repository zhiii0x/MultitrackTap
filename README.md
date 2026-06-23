<div align="center">

<img src="assets/AppIcon-1024.png" alt="Multitrack Tap" width="120">

# Multitrack Tap

**Free, open-source, native macOS multitrack recorder.**

Record your **mic + system audio + each chosen app** to separate, time-synced WAV
stems in one click — and get a **ready-to-open Reaper project**.

English · [繁體中文](README.zh-TW.md)

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![macOS 14.4+](https://img.shields.io/badge/macOS-14.4%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20Core%20Audio-orange?logo=swift)
![CI](https://github.com/zhiii0x/MultitrackTap/actions/workflows/ci.yml/badge.svg)

<br>

<img src="assets/main.png" alt="Multitrack Tap — the main recording window" width="440">

</div>

---

## What it does

Multitrack Tap records every audio source on your Mac as its own clean stem,
in a single click:

- Your **microphone**, the **system audio**, and **each chosen app** (Zoom,
  Discord, a browser tab, a music player, a game) — each captured to its
  **own stem**
- Built on **native Core Audio process taps** (macOS 14.4+) — **no virtual
  audio driver to install**
- Stems are **sample-aligned** and **zeroed to the project start**, so they
  line up perfectly with no manual nudging
- One click also writes a **ready-to-open Reaper project** with every track
  named and aligned — or drag the stems straight into any DAW or video editor

Free and open source, native to macOS.

## Great for

- **Live streaming** — capture game/app audio, system sound, and your mic as
  separate stems while you stream, then re-edit or repurpose the audio cleanly.
- **Podcasts and remote interviews** — your mic, a remote guest (Zoom, Discord,
  Riverside), and a music bed each on their own track, so "guest too loud" or
  "duck the music" becomes a one-minute fix in post.
- **Meetings and calls** — record any conferencing app with each side and the
  system audio on separate tracks for clean recaps, clips, or transcripts.
- **Screencasts and courses** — narration kept separate from app and system
  audio, ready to drop into a DAW or a video editor.

## Features

- Mic + system audio + N per-app stems, captured together and aligned to **one shared reference clock**
- WAV output: **16 / 24 / 32-bit** (32-bit float default — no clipping), at **44.1 / 48 / 88.2 / 96 kHz**
- **One-click Reaper `.rpp`** export — tracks named by source, all aligned at time 0
- Live level meters + a menu-bar quick **Start/Stop**
- Record any combination of sources — each prompts for its own permission, and a source that can't be tapped is skipped while the rest keep recording
- Interruption-resilient — WAV headers are flushed while recording and repaired on next launch, so a crash leaves valid, playable stems

## Requirements

- macOS **14.4 (Sonoma)** or later — required for Core Audio process taps
- Apple Silicon or Intel

## Status

**Pre-release, but usable today** — the recording engine, UI, and Reaper export
work end to end, shipped as a signed + notarized DMG.

## Install

1. Download **Multitrack Tap.dmg** from the [**latest release**](https://github.com/zhiii0x/MultitrackTap/releases/latest).
2. Open it and **drag Multitrack Tap to your Applications folder**.
3. Launch it. On first use, grant **Microphone** and **System Audio Recording**
   (System Settings → Privacy & Security), then **quit and reopen once** so macOS
   applies the System Audio Recording grant.

Signed + notarized with a Developer ID, so it opens with no Gatekeeper warning.
Prefer to build it yourself? See below.

## Build from source

Requires **Xcode 16 or later** (Swift 6).

```bash
git clone https://github.com/zhiii0x/MultitrackTap.git
cd MultitrackTap

# Run the pure-logic core's unit tests
swift test

# Build and assemble the .app bundle
cd app
./make-app.sh
open "Multitrack Tap.app"
```

On first record the app asks for **Microphone** and **System Audio Recording**
permission. With ad-hoc signing the audio-capture grant resets on each rebuild —
set a stable identity to keep it across rebuilds:

```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./make-app.sh
```

See the **[Manual](MANUAL.md)** for recording, settings, output, and troubleshooting.

## How it works

A pure, fully unit-tested Swift package (**`MultitrackCore`**) holds the logic —
WAV writing, timeline alignment, and Reaper export — behind an `AudioTap`
protocol seam. A thin **SwiftUI app layer** provides the real Core Audio process
taps, mic capture, source enumeration, and UI. Every source is stamped against
one shared host-time clock, and `TimelineAligner` prepends leading silence so
each stem starts at project time 0 — that's what keeps the stems lined up.

The Core Audio process-tap and audio-process enumeration code is adapted from
AudioCap — see [Acknowledgements](#acknowledgements).

## Contributing

Issues and PRs are welcome. Keep recording logic in `MultitrackCore` (developed
test-first via `swift test`); hardware and UI live in the app layer.

## Acknowledgements

A special thank-you to **[Guilherme Rambo](https://github.com/insidegui)**. His
open-source **[AudioCap](https://github.com/insidegui/AudioCap)** is what made the
Core Audio process-tap work in this project possible — Multitrack Tap's tap setup
and audio-process enumeration are adapted from it, under the
[BSD-2-Clause license](THIRD-PARTY-LICENSES.md). Thank you, Guilherme.

## License

[MIT](LICENSE) © 2026 Zhiii
