# Changelog

All notable changes to LocalVoice are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions refer to LocalVoice itself. The ctrlSPEAK release the patch set is
built against is pinned separately, in `SUPPORTED_CTRLSPEAK_VERSION` in
`install.sh`, and moves on its own schedule.

## [Unreleased]

### Changed

- LocalVoice looks for updates once a day by default instead of asking first;
  the switch under **Settings › General › Updates** turns it off. Copies of
  1.4.0 still ask once before their first check.
- The recording pill answers the hotkey at once: a small circle appears while
  the microphone opens and grows into the pill as soon as it records, instead
  of the pill fading in only after the microphone was ready.
- Inserted text is confirmed by the pill folding into a circle with a green
  check, without the "Text inserted" label. Every pill now leaves by folding
  back into a point instead of fading out; the other outcomes keep their text.
- The website's Homebrew command sits in its own box with a copy button.

### Removed

- The language badge on the recording pill and the `compact` setting that hid
  it. LocalVoice.app never showed the badge; it was left over from the legacy
  install. The language is chosen per model in Settings.

## [1.4.0] — 2026-11-27

### Added

- LocalVoice updates itself. A new version puts a dot on the menu bar icon,
  leads the menu with **Update to LocalVoice x.y.z…** and shows up under
  **Settings › General › Updates**; installing replaces the app in place and
  reopens it, with permissions, models and settings kept. Most updates are a
  delta patch of a few MB instead of the 540-MB disk image. LocalVoice asks
  once, on the second launch after setup, before it checks GitHub on its own
  (once a day); **Check for Updates…** looks right away. Built on
  [Sparkle](https://sparkle-project.org) 2.10.1; updates are signed with an
  EdDSA key and the Developer ID. The release workflow publishes the feed and
  patches from the last two releases with each build. Coming from 1.3.0 or
  older, install the next release by hand once.
- LocalVoice can be installed with Homebrew:
  `brew install --cask schereo/tap/localvoice`. The cask lives in
  [Schereo/homebrew-tap](https://github.com/Schereo/homebrew-tap), and the
  release workflow moves it to each new release.

### Changed

- Settings is one window with a sidebar: General, Dictation, Recording and
  Models. The Model Library moved into it as the Models section; **Models…**
  in the menu bar opens Settings there, and opening LocalVoice again returns
  to the section shown last.
- Vocabulary is greyed out while the model in use ignores it (Parakeet,
  Nemotron). The row says so, names a model that reads the list, and its
  **Choose Model…** button opens the Models section. The saved words stay.

- The recording pill appears about 0.1–0.15 s after the hotkey instead of
  ~0.4–0.5 s. A hidden pill is started ahead of time (no CPU while it waits)
  and shown the moment the microphone is live (~20 ms instead of a fresh
  process launch). It still never appears before capture does, so a slow
  Bluetooth microphone cannot eat the first words. Its fade-in is 80 ms
  instead of 180 ms.
- Recording starts about 0.2 s sooner. The microphone process used to be
  started (Python plus PortAudio) on every hotkey tap; a standby process is now
  prepared ahead of time and only opens the device when you start dictating.
  It holds no stream while waiting, so the microphone indicator stays off. The
  log records how long each open took (`Microphone open after … ms`).
- Whisper with the language on Auto transcribes about twice as fast: ~0.35 s
  instead of ~0.65 s per decode with Turbo, the same as with a fixed
  language. Detecting German or English used to run the audio encoder (most
  of a decode) a second time; now the first window is encoded once and that
  encoding serves both the detection and the transcription. The live preview
  gets the same saving every second.
- Stopping right after a sentence often needs no decode at all. About a
  quarter second into every pause, the open phrase is transcribed ahead of
  time (with or without the live preview). If only quiet audio follows (no
  speech by VAD, low level), that text is the phrase's transcript, both for
  the silence cut after a one-second pause and at stop; otherwise the
  phrase is decoded as before. In a real-time benchmark with Whisper Turbo
  (14 s of speech), stop to text went from 485/560/228 ms to 367/185/6 ms
  when stopping 0.3/0.6/1.2 s after the last word. The log says when a
  transcript is reused.
- Pausing and resuming Spotify or Music (`pause-media`) no longer holds up
  recording or insertion: both run osascript on their own thread, in order.
  The pause overlaps with opening the microphone, and capture still begins
  only once the player has stopped (at most 0.5 s), so music from the
  speakers does not open the dictation.
- The first paste after a service start is ~0.25 s faster (the accessibility
  bindings are loaded at startup), and the pause before Cmd+V is 50 ms
  instead of 100 ms.

### Fixed

- The processing pill no longer sits in an oversized grey box when live text
  arrives just before the stop. The shadow restarted from the size the
  interrupted grow was heading for, far larger than the capsule, and the
  window cut it off square; it now starts from where it is on screen. The
  blur mask is also rebuilt when both updates arrive together.

## [1.3.0] — 2026-11-25

### Added

- Dev releases: every merge to `main` runs the checks on a GitHub-hosted
  Apple Silicon runner and publishes a portable test app as a pre-release
  (`v<VERSION>-dev.<run>`). `build-dev-app.py --portable` embeds a pinned
  standalone Python so the app no longer depends on `build/dev/venv`.
- Signed, notarized app releases: pushing a `v<VERSION>` tag builds
  **LocalVoice** (`com.localvoice.app`) and publishes it as the GitHub release.
  Dev and release builds are signed with the Developer ID
  (`scripts/sign-app.py`, every Mach-O file with the hardened runtime) and
  notarized (`scripts/notarize-app.sh`), so Gatekeeper opens them without a
  quarantine workaround and macOS permissions survive updates. Releases ship
  as a signed, notarized disk image (`LocalVoice-v<VERSION>-arm64.dmg`):
  open it and drag the app onto Applications.
- Qwen3-ASR 1.7B (8-bit MLX, 2.47 GB) in the Model Library: the most accurate
  open model LocalVoice offers, running on the GPU through mlx-qwen3-asr. It
  takes the vocabulary list as its context prompt, can be pinned to Deutsch or
  English like Whisper, and works with the live transcript preview. Release
  runtimes must lock `mlx-qwen3-asr==0.4.4`.
- The Core ML worker builds against FluidAudio 0.18.4 (was 0.17.7). Parakeet
  and Nemotron keep their pinned model files; checked offline with German and
  English speech, with unchanged load and decode times.

- Settings window redesigned in the style of System Settings: a header with
  the app icon and the current dictation state, grouped cards with a coloured
  symbol per row, and keycaps that show the chosen hotkey gesture. New rows
  for Vocabulary, Show in Menu Bar, Launch at Login (off unless you turn it
  on) and Manage Models, plus an Open Config File link. The Pause Media
  permission state is now part of that row's own description.

- Custom vocabulary (`vocabulary` key): comma-separated names, brands and
  jargon, handed to Whisper as its initial prompt so it reuses their exact
  spelling — verified with synthesized audio containing an invented name.
  Applies from the next recording; Whisper reads at most the last ~224
  tokens of the list. The list is parsed defensively: inline ` # ` comments
  and Whisper special-token strings are stripped, and fullwidth/ideographic
  commas separate entries just like ASCII ones.
- Live transcript in the recording pill (`live-preview = on`, off by
  default): confirmed phrases appear in full ink after each pause, and a
  dimmed guess of the phrase being spoken updates about once a second. The
  capsule grows around up to two lines, newest words always visible. The
  inserted result is unchanged — the preview only shows work the segment
  pipeline was already doing, plus low-priority guess decodes that never
  delay it.

### Added

- A ready screen after setup. When the first model has finished loading after
  the permissions are set up (and the first time on a new install), a window
  plays the whole cycle as an animation with a caption for each step. Insert:
  the configured key is tapped as often as the hotkey needs, the recording
  pill shows a moving waveform, the key is tapped again, and the text types
  itself into a field. Discard: tap, speak, Esc, and the pill shakes and
  disappears.
  Below it, three steps cover how to start, how to insert or discard (Return,
  Esc) and where Models and Settings are, followed by Open Settings… and
  Start Dictating. Under Reduce Motion the scene is one still with a "2×" badge,
  the pill, the inserted text and a one-line caption.
  The model library's own ready note stays quiet while the screen is up.
- A "Ready to dictate" confirmation once a model has finished loading. The
  model library shows a green note above the table that explains how to
  dictate (tap the configured hotkey in any app, tap again to insert the
  text, Esc discards) and that Settings are under the LocalVoice icon in the
  menu bar. It has a Got It button and is announced to VoiceOver. It appears
  only when a model becomes active while the window is open, not for a model
  that was already running. When setup finishes with a model already chosen,
  the permission window's "Ready to dictate" footer gives the same Settings
  hint.

### Changed

- Settings follow the setup windows' design: a heading, then two cards
  ("Dictation": Hotkey, Microphone; "While Recording": Live Preview,
  Microphone Standby, Pause Media). Each row has a title, a one-line
  explanation of what the option does and its control on the right, and the
  on/off options are switches instead of checkboxes. The window sizes to its
  content.
- Settings explain media pause's Automation prompt before it appears. Under
  "Pause media during dictation" a line says that macOS will ask once to let
  LocalVoice control Spotify and Music. Turning the option on asks right away
  for the players that are open, so the dialog no longer appears in the middle
  of the first dictation. The line then shows the answer ("Allowed for
  Spotify", or an Open Settings… shortcut to Privacy & Security › Automation
  if it was declined, or Allow… if still unanswered).
- The permission window is rebuilt in the model library's style and walks
  through setup instead of listing three equal buttons. Microphone,
  Accessibility and Input Monitoring are numbered rows in one card. The next
  step is highlighted and holds the only default button, and the others stay
  clickable. Each row shows its state in words ("Not set up", "Waiting…",
  "Reopen needed", "Old entry") and turns into a green "Allowed" when
  granted. The window updates live, polling every half second while you are
  in System Settings. The floating panel beside System Settings explains the
  current step, offers the draggable app, confirms the grant and offers the
  next step without leaving Settings. When everything is on, the window says
  what happens next (choose a model, starting, ready, or dictation didn't
  start). Input Monitoring that is on but not yet in effect offers Reopen, and
  System Settings' Quit & Reopen resumes on the finished window instead of
  leaving an orphaned service behind. Test builds remember which build each
  grant belonged to: rows granted to an earlier build show "Old entry", and
  Re-add removes the stale entry before adding the app again. The menu item
  reads "Finish Setup…" until everything is granted, then "Permissions…".
- The model library is one table, like a settings pane: a column each for
  languages and size, a one-line description per model, and a single button
  per row (Download, Cancel, Use) with a checkmark on the model in use. A
  download shows in its row ("Downloading, 38 of 483 MB (8 %)") on a tinted
  background; unavailable models stay listed, dimmed, with the reason in the
  languages column. The dictation language moves to the foot of the table and
  applies to the active model; models that detect the language themselves say
  so instead of offering a choice. Removing a downloaded model is a trash
  button beside Use, or the row's context menu. Models used in place from the
  Hugging Face cache say "Shared cache" under their size, and progress or
  error messages replace the subtitle above the table so they stay in view.

- Quieter result pills: regular-weight 12.5 pt text instead of semibold
  14 pt, a smaller status icon, and a capsule that hugs its text. The
  transcription state drops its spinner and "Transcribing" label — a small
  capsule with the pulsing dot row is all a one-second state needs.
- The language pill wears the same quiet styling as the result pills —
  small icon, regular-weight text, a capsule sized to its content — instead
  of the abandoned bold look.
- Transcription conditions on previously decoded text again (Whisper's
  default): the vocabulary bias now carries past the first 30-second window
  of a long take, reinforced by the correctly spelled text itself. Safe now
  that the temperature-fallback ladder resets the prompt after any
  high-temperature retry, which is what kept this disabled before.

### Fixed

- Memory no longer creeps up while the service sits in the background: MLX's
  GPU buffer cache is emptied after every transcription. Measured after three
  weeks of uptime, the service held 5.2 GB for a 1.5-GB model; it now stays
  at about 1.8 GB, with no measurable change in decode speed.
- A decoder loop ("TN, TN, TN, ..." to the token cap) no longer lands in
  the inserted text. Whisper flags such a window as too repetitive and
  retries at higher temperatures, but when every retry fails, mlx_whisper
  returns the last attempt as if it had succeeded — typically for a
  one-second breath between sentences whose language detection was a
  coin toss. Such a window is now decoded again from scratch — only its
  time span, without the previous text and without the vocabulary prompt,
  the two things a loop latches onto. That recovers what was said after the
  loop started, which the loop had eaten, instead of dropping the segment
  and the real words in front of it. If the retry loops too, any word or
  short phrase repeated four or more times in a row collapses to a single
  copy; nothing is discarded.
- The pill now morphs between sizes as one motion. The capsule used to snap
  to its final size while only the window animated, which read as a jump, a
  sideways slide, then another jump on every stop.
- With a `vocabulary` configured, near-silent audio could make the decoder
  emit the word list over and over — and paste it. Three layers now stand in
  the way: the standard temperature-fallback ladder (its compression-ratio
  retry is what breaks greedy decoding's loops), dropping segments the model
  itself scores as probable non-speech, and an echo suppressor that collapses
  stuttered vocabulary words and refuses a transcript consisting of nothing
  but the word list read back.

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
- A watchdog restarts the service when a command makes no progress for 90
  seconds, showing a pill on the way out. `os._exit` is the only exit that
  works with threads stuck in a kernel mutex; the LaunchAgent brings the
  service back seconds later.

### Changed

- Microphone capture runs in its own process. CoreAudio's HAL deadlocks in the
  stream teardown path, and a mutex wedged inside our own process cannot be
  broken from Python — every earlier mitigation worked around that rather than
  removing it. Releasing the microphone is now killing a child process, which
  the kernel always honours immediately. The indicator goes out the moment a
  recording ends, and opening is bounded: the child reports `ready` or
  `open-failed`, and the parent raises after five seconds instead of hanging.
- Hotkey callbacks only enqueue; a worker thread runs the commands one at a
  time and in order. The callbacks run on pynput's `CGEventTap`, so anything
  blocking there used to take key handling down with it — while the process
  stayed alive and `KeepAlive` never fired, leaving dictation dead behind a
  healthy-looking service.
- The installer records what it deployed in
  `~/.config/ctrlspeak/installed-version`, and `doctor.sh` compares that
  instead of the app bundle's version. The bundle only changes when it is
  rebuilt, while most of LocalVoice lives outside it, so an up-to-date install
  could report as stale. The stamp sits outside the bundle deliberately:
  writing inside a signed bundle changes its signature, and under ad-hoc
  signing that means losing the macOS permissions. ([#7])

### Removed

- The `Detected DE` line the pill showed after auto-mode recordings. The
  transcript itself already says which language came out; the detected
  language still lands in the log.
- The bounded teardown join and the PortAudio device-list refresh from 1.0.1.
  Both existed to survive a deadlock and a stale device list inside the
  process that owned the stream. A fresh capture process per recording
  re-runs `Pa_Initialize` and cannot deadlock the parent, so both are
  superseded rather than dropped.

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

[Unreleased]: https://github.com/Schereo/localvoice/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/Schereo/localvoice/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/Schereo/localvoice/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/Schereo/localvoice/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/Schereo/localvoice/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/Schereo/localvoice/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Schereo/localvoice/releases/tag/v1.0.0
[#1]: https://github.com/Schereo/localvoice/pull/1
[#2]: https://github.com/Schereo/localvoice/pull/2
[#3]: https://github.com/Schereo/localvoice/pull/3
[#4]: https://github.com/Schereo/localvoice/pull/4
[#5]: https://github.com/Schereo/localvoice/pull/5
