# Usage in detail

## Keys

| Key | Action |
|---|---|
| Hotkey tap (default: triple-tap **Ctrl**) | Start recording / stop and insert |
| **Enter** (while recording) | Stop and insert |
| **Esc** (while recording) | Discard the recording |
| **Cmd+,** (when LocalVoice is active) | Open LocalVoice Settings |

Enter and Esc are only interpreted while a recording runs. macOS delivers them to the frontmost app as well — in fields where Enter submits, prefer the hotkey to stop.

## Insertion

The transcript is pasted wherever the cursor is. Before pasting, the focused UI element is checked through the Accessibility API; if it clearly cannot take text, nothing is typed — the transcript stays on the clipboard and the pill says `Copied`. Apps with incomplete accessibility trees (many Electron apps) keep the normal paste behaviour.

## Hotkey

Choose a modifier and tap count in **Settings…**. The running service picks the change up within seconds; no restart needed. Full reference: [configuration.md](configuration.md).

Any other key pressed between taps voids the sequence, so `Cmd+C` quickly followed by `Cmd+V` never triggers a double-tap. If your gesture collides with a system shortcut (macOS binds *press Cmd twice* to Siri, for example), change either side — Siri's binding lives in System Settings → Apple Intelligence & Siri.

## Microphone standby

By default the microphone is opened when a recording starts and released the moment it ends, so the macOS indicator tracks your dictation exactly. Capture runs in its own process (see [how it works](how-it-works.md#staying-alive)), which makes the release a `kill` — instant, and immune to the CoreAudio deadlock that a normal teardown can hit. The trade-off is roughly 0.2 s to spin capture up at the start of a recording, and no pre-tap audio in the onset buffer (the in-recording protection against swallowed first syllables remains).

If you prefer instant starts, enable **Microphone Standby** in Settings. The stream then stays open while the service runs, and the indicator with it. Idle audio is held only as a rolling 0.45 s in memory and never stored or sent anywhere.

## Language modes

**Automatic** is the default. In Settings › **Models**, choose **Deutsch** or **English**
for Whisper, Nemotron or Qwen3-ASR if you want to pin a language. The choice is remembered
per model and applies to the next dictation. Parakeet always detects automatically.

## Microphone

By default LocalVoice records through the Mac's **built-in microphone**, even
when Bluetooth headphones are connected — opening an AirPods microphone would
drop all their audio into phone-call quality for the whole recording. Pick a
different device in **Settings…**, or set `microphone` in the config
(`system` for the macOS default input, or a device name like `Shure MV7`).
Details: [configuration.md](configuration.md#microphone).

## Media pause

Recording pauses whatever Spotify or Apple Music is playing and resumes it
the moment you stop — only what was playing comes back, nothing is ever
started. macOS asks once whether LocalVoice may control each player
("LocalVoice wants to control Spotify"); turning the option on in Settings
asks right away for open players and shows the answer under the option.
Disable with `pause-media = off` or in Settings.

## Menu bar

The menu bar icon opens **Settings…**, **Models…** (Settings at its Models
section), and permission setup. It also has restart and quit controls. Hide
it in Settings or with `menubar = off`; with the icon hidden, open LocalVoice
again to reach Settings.

## Live preview

With `live-preview = on`, the recording pill mirrors the transcript as it
forms: phrases the pipeline has finished appear in full ink after each pause,
and a dimmed guess of the phrase being spoken updates about once a second in
between. The capsule grows upward around up to two lines; the oldest words
scroll off behind an ellipsis. Off by default — the guess re-runs the model
about once a second while you talk, which costs battery, and the inserted
result is byte-for-byte the same either way. Details:
[configuration.md](configuration.md#live-preview).

## Vocabulary

Teach the transcriber your names and jargon: add them under **Vocabulary**
in Settings › Dictation, or write `vocabulary = Ada, ctrlSPEAK, MLX` in the config. The words are fed to Whisper or Qwen3-ASR as context before every
recording, which biases it strongly toward their exact spelling. Parakeet and
Nemotron ignore the list; while one of them is in use, Settings greys
**Vocabulary** out and keeps the words for later. Edits apply from the next
recording. Details:
[configuration.md](configuration.md#vocabulary).
