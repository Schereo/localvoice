# Changelog

All notable changes to LocalVoice are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions refer to LocalVoice itself. The ctrlSPEAK release the patch set is
built against is pinned separately, in `SUPPORTED_CTRLSPEAK_VERSION` in
`install.sh`, and moves on its own schedule.

## [Unreleased]

## [1.2.0] — 2026-08-23

### Added

- One configuration file, `~/.config/localvoice/config`, now carries every
  user-facing setting: `hotkey`, `language`, `compact`, `mic-standby`. The
  running service applies edits within a couple of seconds — no restart — and
  values from the old single-purpose files under `~/.config/ctrlspeak` are
  migrated in on first start. Reference: `docs/configuration.md`.
- Cmd+, while the recording pill is on screen opens the config file in the
  default text editor.
- Compact pill: `compact = on` hides the language badge, leaving dot,
  waveform and timer, for people who keep the language fixed (usually on
  `auto`).
- Microphone selection (`microphone` key): `built-in` by default, so
  connected Bluetooth headphones no longer become the dictation mic — opening
  an AirPods microphone drops all its audio into the phone-call profile.
  `system` restores the old follow-the-default behaviour; a device name pins
  any other microphone. Stored as a name, so the choice survives replugs.
- Media pause (`pause-media`, on by default): starting a recording pauses a
  playing Spotify or Apple Music, and stopping resumes exactly what was
  paused — never blind play/pause toggling, so silent players stay silent.
  Uses Apple Events, so macOS asks once per player for the Automation
  permission.
- Menu bar icon, hosted in the launcher process: microphone picker (live
  device list), language mode, compact and standby toggles, open config,
  restart, quit. Every action writes to the config file the service already
  watches — menu and file are the same settings. `menubar = off` hides it.

### Changed

- Quieter result pills: regular-weight 12.5 pt text instead of semibold
  14 pt, a smaller status icon, and a tighter capsule. The transcription
  state drops its spinner and "Transcribing" label — a small capsule with
  the pulsing dot row is all a one-second state needs.

### Removed

- The `Detected DE` line the pill showed after auto-mode recordings. The
  transcript itself already says which language came out; the detected
  language still lands in the log.

### Fixed

- A language choice could appear not to stick: a service started outside
  launchd (for example by double-clicking the app) ran *beside* the launchd
  one, each with its own hotkey listener, pill and language state — a badge
  click saved the choice in one instance while the other kept answering with
  the old language. The service now takes a single-instance lock and a second
  arrival exits immediately; install, restart and uninstall also clear any
  stray instances from before the lock existed.

## [1.1.0] — 2026-08-14

### Added

- The transcript is typed directly into the focused field when the clipboard
  cannot take it, so dictation survives a wedged pasteboard instead of
  delivering nothing. Fallback only — typing is slower than a paste, and some
  apps drop characters from fast synthetic input. The pill distinguishes the
  two, because in such an app it matters which path ran. ([#5])

## [1.0.1] — 2026-08-14

Four freezes over one week, three distinct causes. Three of them share a shape:
an unbounded blocking call on pynput's `CGEventTap` callback thread, where any
wait at all takes dictation down with it.

### Fixed

- The service no longer starts the Textual UI when no terminal is attached.
  Under the LaunchAgent, stdout and stderr are log files and `TERM` is set, so
  Textual believed it could draw and repainted full-screen frames into the log
  in a tight loop — a pinned CPU core from process start and roughly 5 GB of
  escape sequences a day. One log had reached 10.35 GB. Run by hand in a
  terminal, the UI behaves as before. ([#1])
- The microphone teardown runs on its own thread. PortAudio's stop path takes a
  CoreAudio HAL mutex that the device's IO thread can already hold, and the two
  then wait on each other forever — with the pill stuck on "transcribing" and
  the finished transcript never inserted. ([#2])
- A failed microphone open now refreshes PortAudio's device list and retries
  once. `Pa_Initialize` enumerates devices exactly once, so a topology change
  after startup — Continuity, AirPods, a dock, sleep/wake — left the long-lived
  service holding a stale list, and every open failed with `-10851` / `-9986`
  until it was restarted. ([#3])
- The clipboard write is bounded by a timeout and reports failure instead of
  raising. A wedged macOS pasteboard server used to hang `pbcopy` indefinitely,
  and the hotkey thread with it. The paste is skipped when the copy failed,
  since `Cmd+V` would otherwise insert whatever the clipboard held from before.
  ([#4])

## [1.0.0] — 2026-08-07

First release under the LocalVoice name, and the first with the guided
installer and the docs set.

Known broken in this release, fixed in 1.0.1: run as a service, it pins a CPU
core and grows its error log by gigabytes a day.

### Added

- Fully local dictation on Apple Silicon: Whisper Large V3 Turbo via MLX,
  nothing leaves the machine after the one-time model download.
- Native frosted-glass recording pill with live waveform, download progress and
  permission states.
- Guided installer with a permission wizard, a signed app bundle giving the
  process one stable TCC identity, and a matching uninstaller.
- Configurable activation hotkey, `Enter` to insert and `Esc` to discard while
  recording, and a clickable badge cycling German / English / automatic.
- On-demand microphone: the stream opens per recording, so the macOS microphone
  indicator stays honest. Standby mode is opt-in for instant starts.
- Pre-speech onset buffer, so a soft word onset is no longer clipped.
- Clipboard fallback when no focused field can take the text.

[Unreleased]: https://github.com/Schereo/localvoice/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/Schereo/localvoice/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/Schereo/localvoice/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/Schereo/localvoice/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Schereo/localvoice/releases/tag/v1.0.0
[#1]: https://github.com/Schereo/localvoice/pull/1
[#2]: https://github.com/Schereo/localvoice/pull/2
[#3]: https://github.com/Schereo/localvoice/pull/3
[#4]: https://github.com/Schereo/localvoice/pull/4
[#5]: https://github.com/Schereo/localvoice/pull/5
