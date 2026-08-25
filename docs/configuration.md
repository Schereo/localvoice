# Configuration reference

All user-facing settings live in one plain-text file:

```
~/.config/localvoice/config
```

The service creates it on first start. Three ways to open it:

- **Cmd+, while the recording pill is on screen** — opens the file in your
  default text editor. The recording keeps running; Esc discards it, Enter
  inserts it, as always.
- `open -t ~/.config/localvoice/config` from a terminal.
- Any editor, any time — it is just a text file.

**Edits apply within a couple of seconds, no restart needed.** The service
watches the file: hotkey, language and mic-standby changes take effect
immediately; `compact` is read by each pill as it appears, so it shows up on
the next recording.

## Format

`key = value`, one per line. Lines starting with `#` are comments; unknown
keys are ignored. Invalid values fall back to the default rather than breaking
anything.

```ini
# Example: double-tap Cmd, auto-detect DE/EN, minimal pill
hotkey = cmd,2
language = auto
compact = on
mic-standby = off
```

## Keys

| Key | Values | Default | Effect |
|---|---|---|---|
| `hotkey` | `<modifier>,<taps>` | `ctrl,3` | The recording toggle gesture |
| `language` | `de` · `en` · `auto` | `de` | Transcription language |
| `compact` | `on` · `off` | `off` | Hide the language badge in the pill |
| `mic-standby` | `on` · `off` | `off` | Keep the microphone open while idle |
| `microphone` | `built-in` · `system` · name | `built-in` | Which microphone records |
| `menubar` | `on` · `off` | `on` | Show the menu bar icon |
| `pause-media` | `on` · `off` | `on` | Pause Spotify/Music while recording |
| `vocabulary` | comma-separated words | empty | Words the transcriber should spell correctly |
| `live-preview` | `on` · `off` | `off` | Show the transcript in the pill while you speak |

### `hotkey`

A repeated tap on a single modifier key: `ctrl`, `cmd`, `alt` or `shift`,
followed by the tap count (2–4). `cmd,2` means double-tap Command. Modifiers
only — a letter key would fire while typing.

Any other key pressed between taps voids the sequence, so `Cmd+C` quickly
followed by `Cmd+V` never triggers a double-tap. If your gesture collides with
a system shortcut (macOS binds *press Cmd twice* to Siri, for example), change
either side — Siri's binding lives in System Settings → Apple Intelligence &
Siri.

### `language`

- `de` / `en` — transcribe everything as German / English.
- `auto` — Whisper detects the language per recording, deliberately restricted
  to the German/English pair (the full 99-language ranking readily mistakes
  German for Dutch).

Clicking the pill's language badge cycles the mode **and writes the choice
back to this file** — badge and config are the same setting. Want a third
language? See [adding-a-language.md](adding-a-language.md).

### `compact`

`on` strips the recording pill down to the dot, the waveform and the timer —
no language badge. Meant for people who leave the language fixed (typically
`language = auto`) and don't need per-recording switching; while compact is
on, the language can still be changed right here in the config.

### `microphone`

Which device records:

- `built-in` (default) — the Mac's internal microphone, regardless of what
  macOS considers the default input. This exists because of Bluetooth
  headphones: the moment their microphone opens, AirPods drop from the
  high-quality A2DP profile into the phone-call profile, so everything you
  are listening to turns to mush *and* you dictate through the worst
  microphone in the room. With `built-in`, connected AirPods stay untouched.
- `system` — follow the macOS default input, whatever it is.
- anything else — a case-insensitive match on the device name, e.g.
  `microphone = Shure MV7`. The menu bar icon lists the devices currently
  attached; the setting stores the *name*, so it keeps pointing at the same
  physical device across unplugs and replugs.

A setting that matches nothing warns in the log and falls back to the system
default, so dictation keeps working. Changes apply from the next recording
(or immediately in standby mode).

### `menubar`

`on` (default) shows the LocalVoice icon in the menu bar: a microphone picker
built from the currently attached devices, the language mode, toggles for the
compact pill and standby, and Open Config / Restart / Quit. Every menu action
is just a write to this config file — menu and file are the same settings.
`off` hides the icon; like everything here it takes effect within seconds.

### `pause-media`

`on` (default) pauses media players when a recording starts and resumes them
the moment it stops. Only players that were actually *playing* are paused,
and only those are resumed — music that was not running is never started.
Covered players: Spotify and Apple Music (scriptable over Apple Events;
browser tabs are not reachable this way). On first use macOS asks once per
player for the Automation permission — "LocalVoice wants to control
Spotify"; approve it, and from then on it is silent.

### `vocabulary`

Names, brands and jargon the transcriber keeps getting wrong, as a
comma-separated list:

```ini
vocabulary = Ada, ctrlSPEAK, MLX, LocalVoice
```

The list is handed to Whisper as its *initial prompt* — the model conditions
on it as if those words had just been said, and then reuses their spelling
when it hears them. It is a strong bias, not a hard guarantee. Edits apply
from the very next recording. Whisper reads at most the last ~224 tokens of
the prompt, so keep the list to the terms that actually come up — a few
dozen at most; beyond that the oldest entries silently fall off.

### `live-preview`

`on` makes the recording pill show what it heard, while you are still
speaking. Two kinds of text appear below the waveform:

- **Confirmed text** — each time you pause for a second, the finished phrase
  is transcribed and joins the line in full ink. This text is final; it is
  exactly what will be inserted.
- **A live guess** — the phrase you are currently saying, re-transcribed
  about once a second and drawn dimmed, because it may still change as you
  finish the sentence.

The pill grows to fit up to two lines and always shows the most recent words
(older text scrolls out to the left). The inserted result is byte-for-byte
the same as with the preview off — the preview only shows work that was
already happening. The live guess costs extra model runs while you speak,
which is why the feature is opt-in; on Apple Silicon the load is modest.
Confirmed phrases always take priority over the guess, so the preview never
delays the actual transcription.

### `mic-standby`

By default the microphone opens when a recording starts and is released the
moment it ends, so the macOS indicator tracks dictation exactly. `on` keeps
the stream open while the service runs: recording starts become instant, at
the price of an always-lit indicator. Idle audio is held only as a rolling
0.45 s in memory and never stored or sent anywhere. Details:
[usage.md](usage.md#microphone-standby).

## Install-time overrides

The installer accepts environment variables and writes them into the config
file: `CTRLSPEAK_LANGUAGE=de|en|auto`, `CTRLSPEAK_HOTKEY=cmd,2`,
`CTRLSPEAK_MIC_STANDBY=on|off` — e.g. `CTRLSPEAK_HOTKEY=cmd,2 ./install.sh`.

## Migration from pre-1.2 versions

Older versions kept single-value files under `~/.config/ctrlspeak` (`hotkey`,
`language`, `mic-standby`). On its first start, version 1.2 folds their values
into the new config file; until then they are still honoured as a fallback.
`~/.config/ctrlspeak` itself remains in use for the service's internal state
(installed version, setup status, the single-instance lock).
