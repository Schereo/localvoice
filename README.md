<div align="center">
  <img src="assets/icon.png" width="110" alt="LocalVoice icon">

  # LocalVoice

  **Free, fully local dictation for Apple Silicon Macs.**

  Tap a key, speak, and the text lands wherever your cursor is —
  transcribed by Whisper Large V3 Turbo, running entirely on your Mac.

  ![macOS](https://img.shields.io/badge/macOS-13%2B-black)
  ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M5-black)
  ![License](https://img.shields.io/badge/license-MIT-green)
  ![Local](https://img.shields.io/badge/cloud-none-blue)

  <img src="assets/pill-recording.png" width="330" alt="LocalVoice recording pill">
</div>

## Why LocalVoice

Dictation apps like superwhisper or MacWhisper are polished — but their larger, more accurate local models sit behind a paid tier. LocalVoice runs **Whisper Large V3 Turbo**, the same class of model, for free: every part of it is open source, and after the one-time model download nothing ever leaves your Mac. No account, no subscription, no cloud.

Under the hood it builds on [ctrlSPEAK](https://github.com/patelnav/ctrlspeak) and adds a native frosted-glass pill UI, a guided installer, automatic language detection, and a configurable hotkey.

## Features

- **Fully local** German and English speech-to-text — audio never leaves the machine
- **Configurable hotkey**: a double, triple or quadruple tap on Ctrl, Cmd, Option or Shift
- **Language modes** `DE`, `EN`, and `AUTO` (detects the spoken language per recording)
- **Native pill UI** with a live waveform, adaptive light/dark frost, and content-fitted morphing
- **Esc cancels, Enter inserts** while recording
- **Smart insertion**: pastes into the focused field, or keeps the transcript on the clipboard when nothing can take text
- **Guided setup**: macOS permission prompts pre-list the app — no hunting for hidden paths
- **First-run download pill** with live progress; later launches work offline
- **LaunchAgent autostart** and a clean `uninstall.sh`

<div align="center">
  <img src="assets/pill-download.png" width="360" alt="Model download pill">
  &nbsp;&nbsp;
  <img src="assets/pill-success.png" width="200" alt="Success pill">
</div>

## Requirements

- Apple Silicon Mac (M1 or newer)
- A current macOS version
- [Homebrew](https://brew.sh)
- Xcode Command Line Tools: `xcode-select --install`
- Roughly 3 GB of free space for the local model and dependencies

## Installation

```bash
git clone https://github.com/Schereo/localvoice.git
cd localvoice
./install.sh
```

The installer:

1. Installs ctrlSPEAK 1.8.0 and FFmpeg through Homebrew.
2. Builds the native ARM64 recording pill from Swift source.
3. Installs MLX Whisper 0.4.3 and the verified thread/clipboard compatibility patches.
4. Configures Whisper Large V3 Turbo with German as the initial language.
5. Builds `~/Applications/LocalVoice.app`.
6. Walks you through the three macOS permissions, then starts the service.

Homebrew will not load a formula from a third-party tap until you trust it once. The installer explains this when it happens and asks whether to trust the formula — answer `y` and it continues in the same run. To inspect the formula before deciding, answer `n` and run `brew cat patelnav/ctrlspeak/ctrlspeak`.

Install-time options: `CTRLSPEAK_LANGUAGE=de|en|auto` and `CTRLSPEAK_HOTKEY=cmd,2` (modifier `ctrl|cmd|alt|shift`, taps 2–4).

The first launch downloads the 1.61-GB `mlx-community/whisper-large-v3-turbo` model; the pill shows a progress bar with the live rate while this runs. Later launches work offline and show no pill at startup.

## macOS permissions

The installer ends in a guided setup: the app requests **Microphone**, **Accessibility**, and **Input Monitoring** itself, one after the other. Approve the microphone dialog directly; for the other two, macOS opens System Settings with the app **already listed** — flip its switch and the wizard moves on. The pill at the bottom of the screen shows what is still missing, and once everything is granted the service starts by itself.

To run the wizard again later:

```bash
./scripts/setup-permissions.sh
```

Manual fallback: open **System Settings → Privacy & Security**, add `~/Applications/LocalVoice.app` under all three sections with **+**, then run `./scripts/restart.sh`.

**Granted, but not detected?** The pane is showing a stale row from an older build (under ad-hoc signing every rebuild is a new identity). Fix: `./scripts/setup-permissions.sh --reset` clears the app's rows and re-runs the wizard. The installer performs this reset itself when signing ad-hoc; Developer ID rows survive rebuilds and are kept.

## Usage

| Key | Action |
|---|---|
| Hotkey tap (default: triple-tap **Ctrl**) | Start recording / stop and insert |
| **Enter** (while recording) | Stop and insert |
| **Esc** (while recording) | Discard the recording |
| Badge click (`DE` / `EN` / `AUTO`) | Cycle the language mode |

The transcript is pasted wherever the cursor is. If the focused element clearly cannot take text, nothing is typed — the transcript stays on the clipboard and the pill says `Copied to clipboard`.

Enter and Esc are only interpreted while a recording runs, and macOS delivers them to the frontmost app as well — in fields where Enter submits (chat boxes), prefer the hotkey to stop.

### Hotkey

Configured in `~/.config/ctrlspeak/hotkey` as `<modifier>,<taps>`:

```bash
echo "cmd,2" > ~/.config/ctrlspeak/hotkey && ./scripts/restart.sh
```

Any other key pressed between taps voids the sequence, so `Cmd+C` quickly followed by `Cmd+V` never triggers a double-tap. If your chosen gesture collides with a system shortcut (macOS binds *press Cmd twice* to Siri, for example), change either side — Siri's binding lives in System Settings → Apple Intelligence & Siri.

### Language

`AUTO` asks Whisper to detect the language, deliberately restricted to the German/English pair — the full 99-language ranking readily mistakes German for Dutch. After insertion the pill names what was detected. Detection costs one extra pass over the first 30 seconds of audio, so fixing the language stays marginally faster.

## Service, logs, health

```bash
./scripts/restart.sh    # restart the background service
./scripts/doctor.sh     # check installation, signature, service and permission state
```

Logs: `~/Library/Logs/ctrlspeak.log` and `ctrlspeak.error.log`. If the service is loaded but not running, `doctor.sh` asks the app for its permission status and names the fix.

## Uninstalling

```bash
./uninstall.sh                              # keeps model cache and Homebrew formula
./uninstall.sh --remove-model --remove-brew # removes everything
```

Restores ctrlSPEAK's original files from the backups the installer made and clears the app's privacy-pane entries via `tccutil`.

## How it works

- macOS attributes permissions to the *responsible process* — the root of the process tree. LocalVoice ships a real app bundle (`LocalVoice.app`, a native launcher) as that root, so all three permissions attach to one stable identity instead of a Python interpreter or bash. With a **Developer ID Application** certificate in the keychain the installer signs with it automatically and the identity survives rebuilds; otherwise it signs ad-hoc.
- The pill is a separate Swift process driven over a line protocol on stdin (`state`, `level`, `progress`, `detail`, `quit`). Recording sessions stream real RMS levels from ctrlSPEAK — no second microphone stream. On a cold model cache the service wrapper opens the pill immediately through a FIFO that the Python side later adopts, so the first launch never looks hung.
- Download progress is measured from the Hugging Face blob directory and displayed as a modelled counter (Xet materialises files in large chunk batches; the pill advances at the estimated rate and never jumps or runs backward).
- A rolling ~0.45 s onset buffer bridges both the activation gap and Silero VAD's onset latency, so the first word of a recording is not swallowed.
- The app appears everywhere as **LocalVoice** (`com.localvoice.app`). The engine underneath is ctrlSPEAK, installed and patched via Homebrew — which is why its config lives in `~/.config/ctrlspeak` and the helper binaries keep their `ctrlspeak-*` names.

## Contributing

Issues and pull requests are welcome.

- **Bug reports**: include the output of `./scripts/doctor.sh` and the last lines of `~/Library/Logs/ctrlspeak.log`.
- **UI work**: every pill state can be previewed without recording via `./scripts/preview-overlay.sh [preview|recording|permission|download|language]`.
- **Patches**: files under `patches/ctrlspeak-1.8.0/` replace their upstream counterparts at install time (originals are backed up). Keep diffs against upstream as small as possible.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the longer version.

## Credits & license

Built on [ctrlSPEAK](https://github.com/patelnav/ctrlspeak) by Nav Patel (MIT), [MLX Whisper](https://github.com/ml-explore/mlx-examples) by Apple, and [Whisper Large V3 Turbo](https://huggingface.co/mlx-community/whisper-large-v3-turbo) by OpenAI / the MLX community.

MIT — see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
