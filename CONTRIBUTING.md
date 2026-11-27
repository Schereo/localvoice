# Contributing to LocalVoice

Thanks for wanting to help! LocalVoice is a small project with a clear shape —
this page tells you where things live and how to work on them.

## Reporting bugs

Please include:

- the LocalVoice version (Settings › General, or the app's Get Info)
- the last ~30 lines of `~/Library/Application Support/LocalVoice/service.log`
- what **Permissions…** in the menu shows
- your macOS version and Mac model

## How the project is laid out

| Path | What it is |
|---|---|
| `src/ctrlspeak-overlay.swift` | The pill UI — a standalone AppKit process driven by a line protocol on stdin. |
| `src/ctrlspeak-launcher.swift` | The native launcher inside `LocalVoice.app`, including the permission wizard (`--setup`). |
| `src/localvoice-updater.swift` | In-app updates through [Sparkle](https://sparkle-project.org); a stub in builds without Sparkle. |
| `src/ctrlspeak-icon.swift` | Generates the app icon at install time. |
| `patches/ctrlspeak-1.8.0/` | Files that replace their [ctrlSPEAK](https://github.com/patelnav/ctrlspeak) counterparts when the app is built. |
| `scripts/` | Building, signing and releasing the app (`build-app`, `build-dev-app`, `build-runtime`, `sign-app`, …), `check.sh`, and `preview-overlay.sh`. |

## Working on the pill UI

You never need to record to see your changes:

```bash
./scripts/preview-overlay.sh [preview|recording|permission|download|language]
```

compiles `src/ctrlspeak-overlay.swift` into a temporary directory and drives
that build, so it always shows your current source.

The pill speaks a line protocol on stdin — `state <mode>`, `level <0..1>`,
`progress <0..1>` (negative = indeterminate), `detail <text>`, `quit` — so you
can also puppet it directly from a shell.

## Working on the patches

Keep diffs against upstream ctrlSPEAK as small as possible: the patch set is
re-verified against one exact upstream version (see `UPSTREAM_VERSION` in
`scripts/build-app.py`), and every extra divergence makes the next version bump harder.
New functionality that does not need to live inside upstream files should be a
new module (like `overlay.py` or `model_download.py`).

To try a change in the app, build a test app with `python3 -B scripts/build-dev-app.py`
(see [setup](docs/setup.md#local-test-app)); `./scripts/check.sh` runs the tests and
every native build without launching anything.

## Pull requests

- One topic per PR, with a commit message that explains *why*.
- `./scripts/check.sh` passes.
- UI changes: include a screenshot (the preview script makes this easy).

## License

MIT. By contributing you agree that your contributions are licensed under the
same terms. Upstream attribution lives in [NOTICE.md](NOTICE.md).
