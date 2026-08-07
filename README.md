# Local Voice-to-Text for Apple Silicon Macs

A fully local dictation setup built around [ctrlSPEAK](https://github.com/patelnav/ctrlspeak), MLX Whisper Large V3 Turbo, and a custom native macOS recording pill.

Triple-tap **Control** to start recording, speak, then triple-tap **Control** again. The transcript is generated locally and pasted into the active text field.

## What this setup adds

- Fully local German and English speech-to-text after the initial model download
- Forced DE/EN decoding with a persistent language toggle
- Global triple-Control shortcut
- A persistent English recording pill with a real, microphone-responsive waveform
- Animated `Transcribing`, `Text inserted`, and `No speech detected` states
- Startup status in the same pill: missing macOS permissions and first-run model download progress
- Automatic clipboard insertion without changing the active app
- LaunchAgent autostart after login
- Apple Silicon and M-series optimization through MLX

No audio or transcript is sent to a cloud service. ctrlSPEAK keeps a local transcription history by default.

## Requirements

- Apple Silicon Mac (M1 or newer; tested on M5)
- A current macOS version
- [Homebrew](https://brew.sh)
- Xcode Command Line Tools: `xcode-select --install`
- Roughly 3 GB of free space for the local model and dependencies

## Installation

Clone this repository on the other Mac and run:

```bash
git clone https://github.com/Schereo/ctrlspeak-mac-local.git
cd ctrlspeak-mac-local
chmod +x install.sh scripts/*.sh
./install.sh
```

The installer:

1. Installs ctrlSPEAK 1.8.0 and FFmpeg through Homebrew.
2. Builds the native ARM64 recording pill from Swift source.
3. Installs MLX Whisper 0.4.3 and the verified thread/clipboard compatibility patches.
4. Configures Whisper Large V3 Turbo with German as the initial language.
5. Builds `~/Applications/ctrlSPEAK.app`.
6. Walks you through the three macOS permissions, then starts the service.

Homebrew will not load a formula from a third-party tap until you trust it once. If the installer stops there, it prints the exact command to review and trust the formula, then run it again.

The first launch downloads the 1.61-GB `mlx-community/whisper-large-v3-turbo` model and can take a few minutes. The pill shows a `Downloading model` progress bar while this runs, so a slow first start is visibly distinguishable from a hang. Later launches work offline and show no pill at startup.

## Required macOS permissions

The installer ends in a guided setup: the app requests **Microphone**, **Accessibility**, and **Input Monitoring** itself, one after the other. Approve the microphone dialog directly; for the other two, macOS opens System Settings with **ctrlSPEAK already listed** — flip its switch and the wizard moves on. The recording pill at the bottom of the screen shows what is still missing, and once everything is granted the service starts by itself.

To run the wizard again later (after skipping it, or when a grant broke):

```bash
./scripts/setup-permissions.sh
```

Manual fallback: open **System Settings → Privacy & Security**, add `~/Applications/ctrlSPEAK.app` under all three sections with **+**, then run `./scripts/restart.sh`.

**Granted, but the wizard does not notice?** The pane is showing a stale row. Under ad-hoc signing every rebuild gives the launcher a new identity; a "ctrlSPEAK" row left over from an older build looks identical but grants to the old binary, so flipping it does nothing. Fix:

```bash
./scripts/setup-permissions.sh --reset
```

This clears ctrlSPEAK's privacy-pane rows and re-runs the wizard, whose prompts then create fresh rows that match the installed binary. The installer does this reset itself before the wizard (only when signing ad-hoc — Developer ID rows survive rebuilds by design), so this mainly concerns grants made outside the install flow.

If you installed an earlier version, remove the leftover `python3.11` and `bash` entries from those lists. They are no longer used.

<details>
<summary>Why the permissions used to be granted to Python</summary>

macOS grants TCC permissions to the *responsible process*, which is the root of the process tree rather than whichever binary calls the API. Earlier versions launched a shell script from the LaunchAgent, so that root was `/bin/bash` — ctrlSPEAK's own error message even said to grant Accessibility "to bash, not Python".

The alternative, granting them to `/opt/homebrew/var/ctrlspeak/venv/bin/python3.11`, has two problems. That path is a symlink into a versioned Cellar directory, so the grant breaks on every `brew upgrade python@3.11`. And Input Monitoring in particular will not reliably accept a loose executable at all, which is why it often could not be selected.

ctrlSPEAK now ships as a real app bundle whose launcher is the root of that tree, so all three permissions attach to one stable identity.

</details>

Permissions are read once at startup, so after granting anything manually a restart (`./scripts/restart.sh`) is required — the wizard does this for you.

If a permission is still missing at startup, ctrlSPEAK shows a `Permissions required` pill naming what it could not get, then exits. Because the service runs as a LaunchAgent with no window, that pill is the only on-screen sign of the failure; `./scripts/doctor.sh` asks the app for its permission status and names the fix.

## Usage

1. Triple-tap **Control**.
2. The `RECORDING` pill appears and its waveform follows the microphone level.
3. Speak normally.
4. Triple-tap **Control** again.
5. The pill changes to `Transcribing`, then `Text inserted`.
6. The result is pasted wherever the cursor was positioned.

Click the language badge in the recording pill to switch between forced German (`🇩🇪 DE`) and English (`🇬🇧 EN`) transcription. The change applies to the current recording and is retained after restarts. The pill remains non-activating, so the cursor stays in the app where the text will be inserted.

Preview the UI without recording:

```bash
./scripts/preview-overlay.sh [preview|permission|download|language]
```

Check the installation:

```bash
./scripts/doctor.sh
```

## Language

German is the default. Click the badge in the recording pill to cycle through three modes:

| Badge | Behaviour |
|---|---|
| `🇩🇪 DE` | Always decode as German |
| `🇬🇧 EN` | Always decode as English |
| `🌐 AUTO` | Detect German or English per recording |

The choice applies to the current recording and survives restarts. No separate global language shortcut is registered, avoiding conflicts with foreground applications.

In `AUTO` the pill names the language it picked once the text is inserted, so the decision is visible rather than guessed at. Detection is deliberately restricted to German and English: Whisper ranks all 99 languages it knows and readily returns Dutch or Afrikaans for German speech, which then decodes as nonsense. Comparing only these two probabilities keeps a wrong guess from leaving the pair.

`AUTO` costs one extra pass over the first 30 seconds of audio before transcription. Fixing the language stays marginally faster, so it remains the default.

To pick the initial mode on a fresh installation:

```bash
CTRLSPEAK_LANGUAGE=auto ./install.sh
```

Accepts `de`, `en`, or `auto`. The recording pill itself is always in English.

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

## Code signing

The installer signs `ctrlSPEAK.app` ad-hoc by default. If a **Developer ID Application** certificate is in your keychain, it is picked up automatically instead — then the permissions attach to your team and bundle ID and survive any rebuild of the launcher.

To install one (requires an Apple Developer account): Xcode → Settings → Accounts → your team → *Manage Certificates…* → **+** → *Developer ID Application*. Then re-run `./install.sh`. Because the signing identity changes, macOS treats the app as new — grant the three permissions once more afterwards.

A specific identity can be forced with `CTRLSPEAK_SIGN_IDENTITY="Developer ID Application: …" ./install.sh`.

## Uninstalling

```bash
./uninstall.sh
```

Removes the service, the app bundle, the pill, the wrapper, and the patches — restoring ctrlSPEAK's original files from the backups `install.sh` made. The model cache and the Homebrew formula are kept by default:

```bash
./uninstall.sh --remove-model --remove-brew
```

macOS permissions cannot be revoked from a script. Remove the `ctrlSPEAK` entries under System Settings → Privacy & Security yourself if you want a completely clean state.

## Homebrew upgrades

A future `brew upgrade ctrlspeak` can replace the patched Python files. Re-run `./install.sh` afterward. The installer deliberately stops when the installed ctrlSPEAK version differs from the verified version, rather than applying incompatible patches silently.

## Technical notes

The waveform does not open a second microphone stream. ctrlSPEAK already calculates RMS audio levels; a small controller thread sends those values to the native AppKit pill over a pipe. The window is nonactivating, ignores mouse events, stays across Spaces, and does not take focus from the current text field.

The pill is driven by a line protocol on stdin: `state <mode>`, `level <0..1>`, `progress <0..1>` (negative means indeterminate), `detail <text>`, and `quit`. The recording session in `hotkeys.py` owns its own pill because it streams levels; the startup states go through `StatusOverlay` in `overlay.py`.

`ctrlSPEAK.app` contains a small native launcher that spawns the wrapper as a child and waits, forwarding termination signals so `launchctl bootout` brings the whole tree down. It deliberately does not `exec`: that would replace its own image, and the responsible process would become the shell again. It holds no configuration either — paths come from `Contents/Resources/launch.conf`, so the binary stays byte-identical across machines.

The bundle is signed ad-hoc, which is the identity TCC keys the permissions to. Reinstalling on the same Mac keeps the permissions you already granted, because the signature only changes when the launcher, the icon, or `launch.conf` does.

Download progress is measured from the Hugging Face blob directory rather than from hub internals. Partial files carry an `.incomplete` suffix and are counted, so the bar reflects bytes actually written to disk. If the repository size cannot be fetched, the bar falls back to an indeterminate sweep instead of reporting a wrong percentage.

Modified ctrlSPEAK files remain under the upstream project's MIT license. See [NOTICE.md](NOTICE.md).
