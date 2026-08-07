# Setup in detail

## What the installer does

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

The installer signs `LocalVoice.app` ad-hoc by default. If a **Developer ID Application** certificate is in your keychain, it is picked up automatically — permissions then attach to your team and bundle id and survive rebuilds. Create one via Xcode → Settings → Accounts → your team → *Manage Certificates…*, then re-run `./install.sh` and grant the permissions once more. Force a specific identity with `CTRLSPEAK_SIGN_IDENTITY="Developer ID Application: …" ./install.sh`.

## Service, logs, health

```bash
./scripts/restart.sh    # restart the background service
./scripts/doctor.sh     # check installation, signature, service and permission state
```

Logs: `~/Library/Logs/ctrlspeak.log` and `ctrlspeak.error.log`. If the service is loaded but not running, `doctor.sh` asks the app for its permission status and names the fix. After a restart the model takes ~15–20 seconds to load; taps during that window are ignored.

## Uninstalling

```bash
./uninstall.sh                              # keeps model cache and Homebrew formula
./uninstall.sh --remove-model --remove-brew # removes everything
```

Restores ctrlSPEAK's original files from the backups the installer made and clears the app's privacy-pane entries via `tccutil`.

## Homebrew upgrades

A future `brew upgrade ctrlspeak` can replace the patched files. Re-run `./install.sh` afterward — it deliberately stops when the installed ctrlSPEAK version differs from the verified one rather than applying incompatible patches silently.
