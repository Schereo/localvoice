# Development Checks

Run `./scripts/check.sh` after a change. It checks shell and Python syntax, runs isolated tests, builds the AppKit code on Apple Silicon, and exercises the Model Library with a fake store. The test runner needs Python 3.9 or later; override it with `LOCALVOICE_CHECK_PYTHON=/path/to/python3` if needed. The check does not open the GUI, contact a model host, request permissions or touch the installed app.

## Model Library Preview

```sh
out="$(mktemp -d)"
xcrun swiftc -parse-as-library -target arm64-apple-macosx13.0 \
  -D MODEL_LIBRARY_PREVIEW src/localvoice-model-library.swift -o "$out/model-library"
"$out/model-library"
```

The preview simulates model actions without using your installed models.

## Settings Preview

```sh
out="$(mktemp -d)"
xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macosx13.0 \
  -D SETTINGS_PREVIEW src/ctrlspeak-launcher.swift src/localvoice-model-library.swift \
  src/localvoice-updater.swift src/localvoice-shortcuts.swift -o "$out/settings-preview"
LOCALVOICE_CONFIG_DIR="$out" SETTINGS_PREVIEW_ICON=assets/icon.png "$out/settings-preview"
```

The preview shows the Settings window on its own. It reads and writes `config` in `LOCALVOICE_CONFIG_DIR`, or in an empty temporary directory if that is unset, never `~/.config/localvoice/config`, and it does not open the microphone. Set `SETTINGS_PREVIEW_SNAPSHOT=/path/name` to render `name.png` offscreen and quit, with `SETTINGS_PREVIEW_APPEARANCE=light|dark`, `SETTINGS_PREVIEW_SCENARIO=off|pending|denied|allowed` for the Pause Media line, `SETTINGS_PREVIEW_STATUS=ready|loading|permissions|off` for the sidebar's state line, `SETTINGS_PREVIEW_PAGE=general|dictation|recording|models` for the section, `SETTINGS_PREVIEW_MODEL=<model id>` for the model in use (`parakeet-v3` shows Vocabulary greyed out), and `SETTINGS_PREVIEW_UPDATES=auto|off|available|none` for the Updates row. The Models section uses the demo library, so its actions are simulated.

## Offline Model Smoke Test

Run with the private app's Python or another Python environment that already has its MLX runtime. The model must already be installed; the script never fetches it. It processes one second of synthetic silence by default, so it needs neither a microphone nor real audio.

```sh
<runtime-python> -I -B scripts/smoke-model.py whisper-turbo-fp16
```

For a quality comparison, pass `--manifest clips.json` and run each model in a separate process. Each entry is `{"path":"sample.wav","language":"de","reference":"Referenztext"}` with `de` or `en` and a path relative to the manifest. The report gives model load time, decode time, peak process/MLX memory and normalized word error rate. It does not print the transcripts. This measures raw inference, not voice activity detection, transcript filtering or the hotkey-to-paste path.

## Release Gate

- Verify and relocate the staged bundle with `scripts/build-app.sh --verify`.
- On a clean Apple Silicon install of the declared minimum macOS, run the signed build. Ensure it does not use Homebrew or enable login launch by default.
- Test denied permissions, deferred onboarding, a missing model, and an interrupted or corrupt download. Confirm an existing cache is reused without a copy.
- Check start/stop, cancellation, insertion and a successful and failed model switch. With networking disabled, restart and dictate using the installed model.
- Check signing and notarization separately. Passing the staging verifier is not a release attestation.

## NVIDIA Providers

Build the Core ML worker with `scripts/build-parakeet.sh`. SwiftPM fetches the pinned build dependencies, not the speech models. Package the resulting executable with `build-app.sh --parakeet-worker ... --parakeet-license ...` and include the package resource bundle if produced. Parakeet v3, Ultra and Nemotron Streaming need macOS 14+; Redux needs macOS 15+. The app's actual minimum is the highest deployment target of its bundled native components.

Run `scripts/check-nvidia.sh --download /path/to/localvoice-parakeet` for the four-model walkthrough with synthetic German and English. This explicitly downloads about 1.95 GB to a disposable store, relocates the worker, then blocks the network for inference. Use `--reuse-store /path/to/Models /path/to/localvoice-parakeet` to skip the downloads.

To test without installing the app, set `LOCALVOICE_MODELS_DIR` to a fresh temporary directory and `LOCALVOICE_PARAKEET_WORKER` to the built worker. Request `download parakeet-v3` (or `parakeet-ultra` / `parakeet-redux`) in `patches/ctrlspeak-1.8.0/localvoice_models.py`, then run:

```sh
python3 -I -B scripts/smoke-parakeet.py parakeet-v3 \
  --worker "$LOCALVOICE_PARAKEET_WORKER" --wav speech-16k-mono.wav --expect "Guten Morgen"
```

Run with network access blocked to verify the offline path. The test uses the app's store and worker bridge, not the microphone or pasteboard. The picker uses automatic language selection when Parakeet is active. To test Nemotron, request `download nemotron-streaming` and use that ID in the same smoke test. It checks for nonempty live results before finalizing. Enable **Live Transcript Preview** in the app to show these results as you speak.
