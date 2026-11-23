# Setup in detail

## Private App

The private build keeps the upstream Python code, runtime and native helpers in `LocalVoice.app`. It does not install a Homebrew formula, patch another app, or write a LaunchAgent. To build it:

1. Use [`scripts/build-runtime.sh --help`](../scripts/build-runtime.sh) to prepare the relocatable ARM64 runtime archive from local, checksum-pinned inputs. `--check-inputs` checks the archives, wheel lock and license inputs without executing the runtime.
2. Build the [NVIDIA Core ML worker](development-checks.md#nvidia-providers) with `scripts/build-parakeet.sh`. Pass its executable and license to `scripts/build-app.sh`, along with the produced runtime archive and digest, the pinned ctrlSPEAK source archive and a deployment target.
3. Run `scripts/build-app.sh --verify /path/to/LocalVoice.app` on the staged bundle. Signing, notarization and a run on the oldest supported macOS are separate release checks.

The build commands do not fetch inputs. If upgrading from the legacy Homebrew install, quit its menu-bar service before testing the private app; don't run both at once.

The app exposes these actions in its menu:

| Action | What it does |
|---|---|
| **Settings…** | Configures the hotkey, microphone, live preview, microphone standby, and media pause. |
| **Models…** | Shows model source and size, and remembers the language choice for each model that accepts one. Downloads are explicit. Existing verified Hugging Face snapshots are reused in place; only LocalVoice-owned copies can be removed. **Use** starts the new model and leaves the previous selection intact if loading fails. |
| **Permissions…** | Shows Microphone, Accessibility and Input Monitoring as numbered steps that update live. Reads **Finish Setup…** while something is missing. |
| **Launch at Login** | Registers the app with macOS only if enabled. |

The app keeps owned models in `~/Library/Application Support/LocalVoice/Models`. It does not write dictated text to logs or to an existing ctrlSPEAK history database. To uninstall, turn off **Launch at Login**, quit, and move the app to Trash. Model files and preferences are not removed with the app.

If access is missing, the window opens without requesting anything and updates live. The next step is highlighted and holds the default button; the others stay clickable. For Accessibility and Input Monitoring, **Open Settings…** opens the list and a guide panel: drag the app icon in and switch it on; the panel confirms and offers the next step without leaving System Settings. If macOS offers **Quit & Reopen**, choose it; LocalVoice also offers **Reopen** when Input Monitoring is on but not yet in effect, and resumes on the finished window. Test builds are a new identity after every rebuild: rows granted to an earlier build show **Old entry**, and **Re-add…** removes that entry (`tccutil reset`) before adding the app again.

## Local Test App

On Apple Silicon with macOS 15+, Command Line Tools and Python 3.11:

```sh
python3 -B scripts/build-dev-app.py
open build/dev/LocalVoice.app
```

The build downloads development dependencies and pinned upstream source, not model weights. It uses an isolated virtual environment and ad-hoc signing; no Developer ID or Homebrew installer is needed. Keep the app and `build/dev/venv` where the build put them. Add `--worker /path/to/localvoice-parakeet` to reuse an existing worker. This is a local test build, not a redistributable app.

## Legacy Homebrew Installer

`./install.sh --plan` previews the legacy installer without changing anything. `./install.sh --legacy-homebrew` opts into the changes below. Do not run the legacy installer or uninstaller against an independent ctrlSPEAK installation you want to preserve.

1. Installs ctrlSPEAK 1.8.0 and FFmpeg through Homebrew.
2. Builds the native ARM64 recording pill from Swift source.
3. Installs MLX Whisper 0.4.3 and the verified thread/clipboard compatibility patches.
4. Configures Whisper Large V3 Turbo with German as the initial language.
5. Builds `~/Applications/LocalVoice.app`.
6. Walks you through the three macOS permissions, then starts the service.

Install-time options: `CTRLSPEAK_LANGUAGE=de|en|auto` and `CTRLSPEAK_HOTKEY=cmd,2` (modifier `ctrl|cmd|alt|shift`, taps 2–4).

The first launch downloads the 1.61-GB `mlx-community/whisper-large-v3-turbo` model; the pill shows a progress bar with the live rate. Later launches work offline and show no pill at startup.

## The Homebrew trust prompt

Homebrew will not load a formula from a third-party tap until you trust it once. The installer explains this when it happens and asks whether to trust the formula — answer `y` and it continues in the same run. To inspect the formula first, answer `n` and run `brew cat patelnav/ctrlspeak/ctrlspeak`.

## macOS permissions

The installer ends in a guided setup: the app requests **Microphone**, **Accessibility**, and **Input Monitoring** itself, one after the other. Approve the microphone dialog directly; for the other two, macOS opens System Settings with the app **already listed** — flip its switch and the wizard moves on. The pill at the bottom of the screen shows what is still missing, and once everything is granted the service starts by itself.

Run the wizard again later:

```bash
./scripts/setup-permissions.sh
```

Manual fallback: open **System Settings → Privacy & Security**, add `~/Applications/LocalVoice.app` under all three sections with **+**, then run `./scripts/restart.sh`.

**Granted, but not detected?** The pane is showing a stale row from an older build (under ad-hoc signing every rebuild is a new identity). Fix: `./scripts/setup-permissions.sh --reset` clears the app's rows and re-runs the wizard. The installer performs this reset itself when signing ad-hoc; Developer ID rows survive rebuilds and are kept.

## Code signing

The legacy installer signs `LocalVoice.app` ad-hoc by default. A **Developer ID Application** signature lets permissions attach to the team and bundle ID instead of an individual rebuild. To use a specific identity, run `CTRLSPEAK_SIGN_IDENTITY="Developer ID Application: …" ./install.sh --legacy-homebrew`.

## Upgrading

`git pull && ./install.sh --legacy-homebrew`. The legacy installer records the version in `~/.config/ctrlspeak/installed-version`, which is what `./scripts/doctor.sh` compares against this checkout.

One caveat with ad-hoc signing: the version is written into the app bundle's `Info.plist`, the bundle is signed, and its signature *is* its identity as far as macOS permissions are concerned. So a version bump produces a new identity, and the three permissions have to be granted once more — the installer clears the stale rows and re-runs the wizard for you, but it is a minute of clicking per release. A **Developer ID Application** certificate removes this entirely: permissions then attach to your team and bundle id and survive every rebuild. See [Code signing](#code-signing).

## Service, logs, health

```bash
./scripts/restart.sh    # restart the background service
./scripts/doctor.sh     # check installation, signature, service and permission state
```

Logs: `~/Library/Logs/ctrlspeak.log` and `ctrlspeak.error.log`. If the service is loaded but not running, `doctor.sh` asks the app for its permission status and names the fix. After a restart the model takes ~15–20 seconds to load; taps during that window are ignored.

## Uninstalling

```bash
./uninstall.sh --legacy-homebrew # keeps model cache and Homebrew formula
```

Restores legacy backups and clears the app's privacy-pane entries. Logs, the Hugging Face cache and Homebrew are kept by default.

## Homebrew upgrades

A future `brew upgrade ctrlspeak` can replace the patched files. The legacy installer stops when the installed ctrlSPEAK version differs from the verified one.
