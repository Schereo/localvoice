# How it works

## One app identity for the permissions

macOS attributes TCC permissions to the *responsible process* — the root of the process tree, not whichever binary calls the API. Run a Python script from a LaunchAgent and that root is `/bin/bash`; permissions then have to be granted to bash or to a versioned Homebrew Python path that Input Monitoring often refuses and every Python upgrade breaks.

LocalVoice ships a real app bundle as that root: `LocalVoice.app` contains a small native launcher that spawns the service wrapper as a child and forwards termination signals (it deliberately does not `exec` — that would hand the tree back to the shell). All three permissions attach to one stable identity, shown by name and icon in the privacy panes. The launcher holds no configuration; paths come from `Contents/Resources/launch.conf`, so the binary stays byte-identical across machines.

The same launcher implements the permission wizard (`--setup`): it requests Microphone (AVCaptureDevice), Accessibility (AXIsProcessTrustedWithOptions) and Input Monitoring (IOHIDRequestAccess) itself, which makes macOS pre-list the app in each pane. It must be launched through LaunchServices (`open -W`) — started from a shell, macOS would attribute the requests to the terminal.

## The pill

The pill is a standalone Swift/AppKit process driven over a line protocol on stdin: `state <mode>`, `level <0..1>`, `progress <0..1>` (negative = indeterminate), `detail <text>`, `quit`. Recording sessions stream ctrlSPEAK's existing RMS levels to it — no second microphone stream is opened. The window is non-activating, floats across Spaces, and never takes focus from the field the text will land in.

The capsule is frosted with the system's adaptive material, so contrast does not depend on what sits behind it; every chrome color derives from an appearance-aware ink. Result states measure their text and morph the capsule to fit; single-line states use a flatter 44 pt capsule. The rim is drawn as a lit glass edge, and separation comes from a shadow layer whose transparent margin refuses hit-testing, so clicks beside the pill fall through.

## First launch and downloads

On a cold model cache the service wrapper opens the download pill immediately — the Python service needs 20+ seconds of imports before it can report anything — and feeds it through a FIFO that the Python side later adopts: one pill, no gap, no flicker. If the service dies, the pill sees EOF and closes itself.

Download progress is measured from the Hugging Face blob directory. Xet, the hub's storage backend, materialises files in large chunk batches, so the pill shows a modelled counter: it advances at the estimated rate (a 20-second window with an EMA on top), is gently pulled toward each measurement, never runs backward, and never gets more than a few seconds ahead of the evidence.

## The microphone indicator

macOS lights the mic indicator whenever any process holds an open input stream — it cannot distinguish "listening and discarding" from "recording". LocalVoice therefore opens the stream per recording session by default, so the indicator reflects actual recordings. Standby mode (see [usage](usage.md#microphone-standby)) keeps the stream open for instant starts; idle audio then exists only as the rolling 0.45 s onset buffer in memory.

## Why the first word is not swallowed

Two mechanisms used to eat word onsets: audio arriving before the recording flag flips was discarded, and within a recording, chunks only entered the segment buffer once Silero VAD classified them as speech — soft first phonemes were dropped as silence. A rolling ~0.45 s onset buffer bridges both gaps: the callback keeps recent chunks while idle and during unclassified silence, and the moment VAD first flips to speech the roll is prepended to the segment. The start beep plays after recording starts, so it marks "already capturing".

## Naming

The app appears everywhere as **LocalVoice** (`com.localvoice.app`). The engine underneath is [ctrlSPEAK](https://github.com/patelnav/ctrlspeak), installed and patched via Homebrew — which is why its config lives in `~/.config/ctrlspeak` and the helper binaries keep their `ctrlspeak-*` names. Patched files replace their upstream counterparts at install time; originals are backed up and restored on uninstall.
