# Usage in detail

## Keys

| Key | Action |
|---|---|
| Hotkey tap (default: triple-tap **Ctrl**) | Start recording / stop and insert |
| **Enter** (while recording) | Stop and insert |
| **Esc** (while recording) | Discard the recording |
| Badge click (`DE` / `EN` / `AUTO`) | Cycle the language mode |

Enter and Esc are only interpreted while a recording runs, and macOS delivers them to the frontmost app as well — in fields where Enter submits (chat boxes), prefer the hotkey to stop.

## Insertion

The transcript is pasted wherever the cursor is. Before pasting, the focused UI element is checked through the Accessibility API; if it clearly cannot take text, nothing is typed — the transcript stays on the clipboard and the pill says `Copied to clipboard`. Apps with incomplete accessibility trees (many Electron apps) keep the normal paste behaviour.

## Hotkey

Configured in `~/.config/ctrlspeak/hotkey` as `<modifier>,<taps>` — modifier `ctrl`, `cmd`, `alt` or `shift`; taps 2–4:

```bash
echo "cmd,2" > ~/.config/ctrlspeak/hotkey && ./scripts/restart.sh
```

Any other key pressed between taps voids the sequence, so `Cmd+C` quickly followed by `Cmd+V` never triggers a double-tap. If your gesture collides with a system shortcut (macOS binds *press Cmd twice* to Siri, for example), change either side — Siri's binding lives in System Settings → Apple Intelligence & Siri.

## Microphone standby

By default the microphone stream is opened when a recording starts and released 60 seconds after the last one — so the macOS mic indicator follows your dictation rather than burning all day, while back-to-back recordings reuse the open stream instead of cycling CoreAudio each time. The trade-off is a moment of extra latency on the first recording after an idle spell, and no pre-tap audio in the onset buffer (the in-recording protection against swallowed first syllables remains).

If you prefer instant starts, enable standby — the stream then stays open while the service runs, and the indicator with it. Idle audio is held only as a rolling 0.45 s in memory and never stored or sent anywhere:

```bash
echo "on" > ~/.config/ctrlspeak/mic-standby && ./scripts/restart.sh
```

`off` (or deleting the file) returns to on-demand. At install time: `CTRLSPEAK_MIC_STANDBY=on ./install.sh`.

## Language modes

German is the default; pick the initial mode at install time with `CTRLSPEAK_LANGUAGE=de|en|auto`.

`AUTO` asks Whisper to detect the language per recording, deliberately restricted to the German/English pair — the full 99-language ranking readily mistakes German for Dutch, which then decodes as nonsense. After insertion the pill names what was detected (`Detected DE`). Detection costs one extra pass over the first 30 seconds of audio, so fixing the language stays marginally faster.

The badge choice applies to the current recording and survives restarts. No separate global language shortcut is registered, avoiding conflicts with foreground applications.

Want a third language? See [adding-a-language.md](adding-a-language.md).
