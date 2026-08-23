# Usage in detail

## Keys

| Key | Action |
|---|---|
| Hotkey tap (default: triple-tap **Ctrl**) | Start recording / stop and insert |
| **Enter** (while recording) | Stop and insert |
| **Esc** (while recording) | Discard the recording |
| **Cmd+,** (while recording) | Open the [config file](configuration.md) in your text editor |
| Badge click (`DE` / `EN` / `AUTO`) | Cycle the language mode |

Enter, Esc and Cmd+, are only interpreted while a recording runs, and macOS delivers them to the frontmost app as well — in fields where Enter submits (chat boxes), prefer the hotkey to stop. Cmd+, leaves the recording running; discard it with Esc if you only came for the settings.

## Insertion

The transcript is pasted wherever the cursor is. Before pasting, the focused UI element is checked through the Accessibility API; if it clearly cannot take text, nothing is typed — the transcript stays on the clipboard and the pill says `Copied to clipboard`. Apps with incomplete accessibility trees (many Electron apps) keep the normal paste behaviour.

## Hotkey

Set in `~/.config/localvoice/config` as `hotkey = <modifier>,<taps>` — modifier `ctrl`, `cmd`, `alt` or `shift`; taps 2–4. `hotkey = cmd,2` is a double-tap on Command. The running service picks the change up within seconds; no restart needed. Full reference: [configuration.md](configuration.md).

Any other key pressed between taps voids the sequence, so `Cmd+C` quickly followed by `Cmd+V` never triggers a double-tap. If your gesture collides with a system shortcut (macOS binds *press Cmd twice* to Siri, for example), change either side — Siri's binding lives in System Settings → Apple Intelligence & Siri.

## Microphone standby

By default the microphone is opened when a recording starts and released the moment it ends, so the macOS indicator tracks your dictation exactly. Capture runs in its own process (see [how it works](how-it-works.md#staying-alive)), which makes the release a `kill` — instant, and immune to the CoreAudio deadlock that a normal teardown can hit. The trade-off is roughly 0.2 s to spin capture up at the start of a recording, and no pre-tap audio in the onset buffer (the in-recording protection against swallowed first syllables remains).

If you prefer instant starts, enable standby — the stream then stays open while the service runs, and the indicator with it. Idle audio is held only as a rolling 0.45 s in memory and never stored or sent anywhere. Set `mic-standby = on` in `~/.config/localvoice/config` (applies within seconds; `off` returns to on-demand). At install time: `CTRLSPEAK_MIC_STANDBY=on ./install.sh`.

## Language modes

German is the default; pick the initial mode at install time with `CTRLSPEAK_LANGUAGE=de|en|auto`.

`AUTO` asks Whisper to detect the language per recording, deliberately restricted to the German/English pair — the full 99-language ranking readily mistakes German for Dutch, which then decodes as nonsense. After insertion the pill names what was detected (`Detected DE`). Detection costs one extra pass over the first 30 seconds of audio, so fixing the language stays marginally faster.

The badge choice applies to the current recording and is written to `language` in the [config file](configuration.md), so it survives restarts — badge and config are the same setting. No separate global language shortcut is registered, avoiding conflicts with foreground applications.

Want a third language? See [adding-a-language.md](adding-a-language.md).

## Compact pill

If you leave the language fixed (usually on `auto`) and don't want the blue badge in the pill, set `compact = on` in the config. The recording pill then shrinks to the dot, the waveform and the timer; language changes happen in the config file instead. The next recording after the edit shows the compact pill.
