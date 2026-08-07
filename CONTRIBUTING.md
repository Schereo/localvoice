# Contributing to LocalVoice

Thanks for wanting to help! LocalVoice is a small project with a clear shape —
this page tells you where things live and how to work on them.

## Reporting bugs

Please include:

- the output of `./scripts/doctor.sh`
- the last ~30 lines of `~/Library/Logs/ctrlspeak.log` (and `ctrlspeak.error.log` if it has content)
- your macOS version and Mac model

If the service is loaded but not running, `doctor.sh` already asks the app for
its permission state — that output usually contains the answer.

## How the project is laid out

| Path | What it is |
|---|---|
| `install.sh` / `uninstall.sh` | The whole lifecycle. Everything is installed from here; nothing is hand-placed. |
| `src/ctrlspeak-overlay.swift` | The pill UI — a standalone AppKit process driven by a line protocol on stdin. |
| `src/ctrlspeak-launcher.swift` | The native launcher inside `LocalVoice.app`, including the permission wizard (`--setup`). |
| `src/ctrlspeak-icon.swift` | Generates the app icon at install time. |
| `patches/ctrlspeak-1.8.0/` | Files that replace their [ctrlSPEAK](https://github.com/patelnav/ctrlspeak) counterparts at install time. Originals are backed up as `*.local-voice-backup` and restored on uninstall. |
| `scripts/` | `restart`, `doctor`, `setup-permissions`, `preview-overlay`. |

## Working on the pill UI

You never need to record to see your changes:

```bash
./scripts/preview-overlay.sh [preview|recording|permission|download|language]
```

builds nothing — it drives the installed pill binary. After editing the Swift
source, rebuild and install it with `./install.sh`, or manually:

```bash
xcrun swiftc src/ctrlspeak-overlay.swift -o /opt/homebrew/bin/ctrlspeak-overlay
```

The pill speaks a line protocol on stdin — `state <mode>`, `level <0..1>`,
`progress <0..1>` (negative = indeterminate), `detail <text>`, `quit` — so you
can also puppet it directly from a shell.

## Working on the patches

Keep diffs against upstream ctrlSPEAK as small as possible: the patch set is
re-verified against one exact upstream version (see `SUPPORTED_CTRLSPEAK_VERSION`
in `install.sh`), and every extra divergence makes the next version bump harder.
New functionality that does not need to live inside upstream files should be a
new module (like `overlay.py` or `model_download.py`).

After changing a patch file, deploy it with `./install.sh` (it re-copies all
patches and byte-compiles them) and restart the service.

## Pull requests

- One topic per PR, with a commit message that explains *why*.
- `bash -n` all touched shell scripts; make sure `./scripts/doctor.sh` passes
  after a fresh `./install.sh`.
- UI changes: include a screenshot (the preview script makes this easy).

## License

MIT. By contributing you agree that your contributions are licensed under the
same terms. Upstream attribution lives in [NOTICE.md](NOTICE.md).
