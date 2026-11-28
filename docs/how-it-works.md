# How it works

## One app identity for the permissions

macOS attributes TCC permissions to the *responsible process* — the root of the process tree, not whichever binary calls the API. Run a Python script from a LaunchAgent and that root is `/bin/bash`; permissions then have to be granted to bash or to a versioned Homebrew Python path that Input Monitoring often refuses and every Python upgrade breaks.

LocalVoice ships a real app bundle as that root: `LocalVoice.app` contains a small native launcher that spawns the service wrapper as a child and forwards termination signals (it deliberately does not `exec` — that would hand the tree back to the shell). All three permissions attach to one stable identity, shown by name and icon in the privacy panes. The launcher holds no configuration; paths come from `Contents/Resources/launch.conf`, so the binary stays byte-identical across machines.

The same launcher implements the permission wizard (`--setup`): it requests Microphone (AVCaptureDevice), Accessibility (AXIsProcessTrustedWithOptions) and Input Monitoring (IOHIDRequestAccess) itself, which makes macOS pre-list the app in each pane. It must be launched through LaunchServices (`open -W`) — started from a shell, macOS would attribute the requests to the terminal.

## The pill

The pill is a standalone Swift/AppKit process driven over a line protocol on stdin: `standby` pills also take `arm`, `disarm` and `show`; then `state <mode>`, `level <0..1>`, `progress <0..1>` (negative = indeterminate), `detail <text>`, `final <text>`, `partial <text>`, `quit`. Recording sessions stream ctrlSPEAK's existing RMS levels to it — no second microphone stream is opened. The window is non-activating, floats across Spaces, and never takes focus from the field the text will land in.

The capsule is frosted with the system's adaptive material, so contrast does not depend on what sits behind it; every chrome color derives from an appearance-aware ink. Result states measure their text and morph the capsule to fit; single-line states use a flatter 44 pt capsule. The rim is drawn as a lit glass edge, and separation comes from a shadow layer whose transparent margin refuses hit-testing, so clicks beside the pill fall through.

## The live transcript

With `live-preview` on, the recording pill shows the transcript as it forms. The two protocol commands mirror the two kinds of text: `final` carries the phrases the segment pipeline has finished (full ink — this text will be inserted verbatim), `partial` carries the model's current guess at the phrase being spoken (dimmed, because it may still change). The capsule keeps its chrome in the bottom 44 pt band and grows upward around up to two lines of text, oldest words scrolling off behind an ellipsis; beyond the 56 pt status pill the corner radius is capped, so the grown capsule reads as a rounded card rather than a lozenge.

The guess costs extra decodes, so it is built to never compete with the real pipeline: about once a second, and only while the transcription queue is idle, a snapshot of the still-open segment (at most its last 15 s) is queued as a preview job for the same worker thread the real segments use — MLX streams are thread-local, so there is exactly one decoding thread. Each snapshot is stamped with the segment counter; once the audio manager finalizes that audio into a real segment, the stamp no longer matches and the stale guess is dropped instead of racing the confirmed line. The inserted result is byte-for-byte the same with the preview on or off.

Whisper and Qwen3-ASR receive mono PCM directly from the queue for both preview and final jobs; they do not write temporary audio files.

## First Launch and Downloads

The private app opens the Model Library independently of the dictation service. It lists verified LocalVoice and Hugging Face cache entries without contacting the network. An explicit download writes only the pinned files to staging, reports bytes received, and publishes the directory after verification. Cancelling removes incomplete files. Shared Hugging Face assets are reused in place and cannot be removed from LocalVoice.

Model activation is separate from download. Switching is allowed only between recording sessions; the launcher stops the previous service before loading the candidate and saves the selection only after the hotkey listener is ready. If the candidate fails to start, the launcher attempts to restore the previous model. The service receives a verified local path and does not download weights.

The explicit legacy Homebrew install still starts the Hub download from the service on a cold cache and reports it in the recording pill.

## Updates

Release and dev builds embed [Sparkle](https://sparkle-project.org). The launcher starts it only after setup; from then on it checks GitHub once a day unless that is switched off in Settings, and dictation never waits on it. A found update is a reminder in the menu bar menu and in Settings, not a window. Updates are signed twice: with the EdDSA key the app trusts (`SUPublicEDKey`) and with the same Developer ID as the installed app. Most updates arrive as a delta patch of a few MB that rebuilds the new bundle from the installed one, file by file, after checking that the installed one is unchanged. Details: [setup](setup.md#in-app-updates).

## The microphone indicator

macOS lights the mic indicator whenever any process holds an open input stream — it cannot distinguish "listening and discarding" from "recording". LocalVoice therefore opens the stream per recording session by default, so the indicator reflects actual recordings. Standby mode (see [usage](usage.md#microphone-standby)) keeps the stream open for instant starts; idle audio then exists only as the rolling 0.45 s onset buffer in memory.

## Staying alive

Three rules keep a wedged subsystem from taking dictation down with it.

**The event tap never blocks.** Hotkey callbacks run on pynput's CGEventTap callback, which macOS expects to return promptly. They only enqueue; a worker thread does the work. A wedge in CoreAudio or the pasteboard can no longer freeze the key handling itself.

**A watchdog owns the last resort.** A deadlock leaves the process alive, so launchd's `KeepAlive` never fires — dictation is dead while the service looks healthy. If a command makes no progress for 90 seconds, a watchdog thread shows a pill and calls `os._exit(1)`, the only exit that works with threads stuck in a kernel mutex. The LaunchAgent restarts the service seconds later.

**The microphone lives in its own process.** CoreAudio's HAL deadlocks in the stream teardown path, and a mutex wedged inside our own process cannot be broken from Python — that is what repeatedly killed dictation for good. `mic_capture.py` owns the stream and writes raw frames to the parent over a pipe; silence detection, buffering and the onset roll stay in the parent, unchanged. Releasing the microphone is then a `kill`, which the kernel always honours: immediate, deadlock-proof, and the macOS indicator goes out with the process. Opening is bounded too — the child reports `ready` or `open-failed`, and a timeout raises instead of hanging. Starting that child (Python plus PortAudio, ~0.2 s) used to open every recording; now a standby child is started ahead of time, waits with PortAudio loaded but no stream open (the indicator stays off), and only receives `open <device>` when the hotkey fires. It refreshes PortAudio's device list on open (a few ms), so a microphone connected meanwhile is still found; if the standby child is gone, a new one is started as before.

## Why the first word is not swallowed

Two mechanisms used to eat word onsets: audio arriving before the recording flag flips was discarded, and within a recording, chunks only entered the segment buffer once Silero VAD classified them as speech — soft first phonemes were dropped as silence. A rolling ~0.45 s onset buffer bridges both gaps: the callback keeps recent chunks while idle and during unclassified silence, and the moment VAD first flips to speech the roll is prepended to the segment. The start beep plays after recording starts, so it marks "already capturing".

## Naming

The app appears everywhere as **LocalVoice** (`com.localvoice.app`). The engine underneath is [ctrlSPEAK](https://github.com/patelnav/ctrlspeak). The private app stages its own patched copy and runtime without using Homebrew. Helpers retain their `ctrlspeak-*` names. LocalVoice preferences are in `~/.config/localvoice/config`; the private app keeps its selections, owned models, and bounded service logs under `~/Library/Application Support/LocalVoice`.

## Fast paths in the stop path

**Language detection reuses the encoding.** For Whisper on Auto, the first 30-second window is built exactly as `mlx_whisper.transcribe()` builds it, encoded once, and the German/English choice is read from that encoding. During the following `transcribe()` call the encoder answers that same window from the kept result (`_reused_encoding` in `models/whisper_mlx.py`), so Auto costs one decoder step rather than a second encoder pass — about 0.3 s per decode with Turbo, previews included.

**A decode at every pause.** While recording, a ticker checks the open segment every 50 ms. Once about 0.26 s of quiet audio follows speech (four capture chunks without VAD speech and below the fallback RMS threshold, tracked as `quiet_tail_chunks`), it queues one decode of the whole segment (up to one 28 s Whisper window), live preview or not; with the live preview on, it also queues the usual preview every second. A whole-segment result is remembered with the number of chunks it saw, even if stop froze capture while it was decoding. When the segment ends, by the one-second silence cut or by stop, `AudioManager._queue_segment` checks whether everything after that snapshot was quiet; if so, it queues a `resolved` job carrying the text, which the worker publishes in order without decoding. Any louder chunk, a newer segment or a snapshot of only the tail falls back to the normal decode.

**Media control is off the critical path.** `pause-media` pauses and resumes players through osascript on one serial thread, so the transcription never waits for Apple Events and a resume can never overtake its pause. The pause runs while the microphone opens; capture then waits for it (at most 0.5 s) and drops the pre-roll if a player was stopped, so music from the speakers does not open the dictation.

**The pill is waiting before the hotkey.** `ctrlspeak-overlay standby` builds the window hidden with its animation clock stopped. The service keeps one such pill ready (started at launch and again with every recording). At the hotkey, before the microphone opens, `arm` puts it on screen as a small circle with a quiet breathing dot, so the hotkey gets an answer within a frame. The recording pill itself still waits for the microphone: a Bluetooth input can take seconds to open, and a pill that says "recording" before then would invite words nobody captures. Once capture is live, `show` grows the circle into the pill on a spring, fading the dot, waveform and timer in as it widens. The blur is clipped by the window server through `maskImage`, which neither an animator nor a layer transform reaches, so the grow is stepped by hand: frame, mask and shadow path together, every frame. If the start fails, `disarm` folds the circle away and the pill goes back to waiting. At the end the same motion runs backwards: `state processing` first stops the pill at full size for up to 0.45 s (grey dot, timer stopped) so a quick result can go straight to its own shape; only then does it fold the pill into a circle with a neutral arc running round it, and a result that arrives while it folds waits until the fold has finished and the arc has turned for 0.3 s, `state success` spirals that arc inward into a green check (`state cancelled` draws a red cross), and every pill leaves by collapsing into a point. Without a standby pill, a new overlay process is launched as before.
