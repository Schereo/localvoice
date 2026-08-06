# Local Voice-to-Text for Apple Silicon Macs

A private, fully local dictation setup built around [ctrlSPEAK](https://github.com/patelnav/ctrlspeak), MLX Whisper Large V3 Turbo, and a custom native macOS recording pill.

Triple-tap **Control** to start recording, speak, then triple-tap **Control** again. The transcript is generated locally and pasted into the active text field.

## What this setup adds

- Fully local German and English speech-to-text after the initial model download
- Forced DE/EN decoding with a persistent language toggle
- Global triple-Control shortcut
- A persistent English recording pill with a real, microphone-responsive waveform
- Animated `Transcribing`, `Text inserted`, and `No speech detected` states
- Automatic clipboard insertion without changing the active app
- LaunchAgent autostart after login
- Apple Silicon and M-series optimization through MLX

No audio or transcript is sent to a cloud service. ctrlSPEAK keeps a local transcription history by default.

## Requirements

- Apple Silicon Mac (M1 or newer; tested on M5)
- A current macOS version
- [Homebrew](https://brew.sh)
- GitHub CLI: `brew install gh`
- Xcode Command Line Tools: `xcode-select --install`
- Roughly 3 GB of free space for the local model and dependencies

## Installation

Authenticate the other Mac with GitHub, clone this private repository, and run:

```bash
gh auth login
gh repo clone Schereo/ctrlspeak-mac-local
cd ctrlspeak-mac-local
chmod +x install.sh scripts/*.sh
./install.sh
```

The installer:

1. Installs ctrlSPEAK 1.8.0 and FFmpeg through Homebrew.
2. Builds the native ARM64 recording pill from Swift source.
3. Installs MLX Whisper 0.4.3 and the verified thread/clipboard compatibility patches.
4. Configures Whisper Large V3 Turbo with German as the initial language.
5. Installs and starts a per-user LaunchAgent.

The first launch downloads the 1.61-GB `mlx-community/whisper-large-v3-turbo` model and can take a few minutes. Later launches work offline.

## Required macOS permissions

Open **System Settings → Privacy & Security** and add the following executable under all three sections:

- Microphone
- Accessibility
- Input Monitoring

The executable path is:

```text
/opt/homebrew/var/ctrlspeak/venv/bin/python3.11
```

When macOS opens only a Finder dialog, press **Command–Shift–G**, paste that complete path, and press Return.

After granting the permissions, restart the service:

```bash
./scripts/restart.sh
```

## Usage

1. Triple-tap **Control**.
2. The `RECORDING` pill appears and its waveform follows the microphone level.
3. Speak normally.
4. Triple-tap **Control** again.
5. The pill changes to `Transcribing`, then `Text inserted`.
6. The result is pasted wherever the cursor was positioned.

Press **Control–Option–L** between recordings to toggle forced transcription between German and English. The pill confirms `Language: German` or `Language: English`, and its badge shows `DE` or `EN`. The selection is retained after restarts.

Preview the UI without recording:

```bash
./scripts/preview-overlay.sh
```

Check the installation:

```bash
./scripts/doctor.sh
```

## Language

German is the default. Toggle at any time between recordings with:

```text
Control–Option–L
```

To make English the initial language on a fresh installation:

```bash
CTRLSPEAK_LANGUAGE=en ./install.sh
```

The recording pill itself is always in English.

## Service and logs

Restart ctrlSPEAK:

```bash
./scripts/restart.sh
```

Logs are stored locally at:

```text
~/Library/Logs/ctrlspeak.log
~/Library/Logs/ctrlspeak.error.log
~/.config/ctrlspeak/logs/ctrlspeak.log
```

## Homebrew upgrades

A future `brew upgrade ctrlspeak` can replace the patched Python files. Re-run `./install.sh` afterward. The installer deliberately stops when the installed ctrlSPEAK version differs from the verified version, rather than applying incompatible patches silently.

## Technical notes

The waveform does not open a second microphone stream. ctrlSPEAK already calculates RMS audio levels; a small controller thread sends those values to the native AppKit pill over a pipe. The window is nonactivating, ignores mouse events, stays across Spaces, and does not take focus from the current text field.

Modified ctrlSPEAK files remain under the upstream project's MIT license. See [NOTICE.md](NOTICE.md).
