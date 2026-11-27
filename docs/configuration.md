# Configuration reference

Use **Settings…** in the LocalVoice menu for the hotkey, microphone,
vocabulary, live preview, standby, media pause, the menu bar icon, and launch
at login. Set the dictation language per model in its **Models** section. Apart from
launch at login, which macOS keeps, these choices are stored in one
plain-text file:

```
~/.config/localvoice/config
```

The service creates it on first start. For advanced edits, click **Open
Config File…** at the bottom of Settings or run
`open -t ~/.config/localvoice/config`.

**Edits apply within a couple of seconds, no restart needed.** The service
watches the file: hotkey and mic-standby changes take effect immediately.

## Format

`key = value`, one per line. Lines starting with `#` are comments; unknown
keys are ignored. Invalid values fall back to the default rather than breaking
anything.

```ini
# Example: double-tap Cmd, open the microphone only for dictation
hotkey = cmd,2
mic-standby = off
```

## Keys

| Key | Values | Default | Effect |
|---|---|---|---|
| `hotkey` | `<modifier>,<taps>` | `ctrl,3` | The recording toggle gesture |
| `language` | `de` · `en` · `auto` | `de` | Legacy installs only: transcription language |
| `language.<model-id>` | `auto` · `de` · `en` | `auto` | Dictation language for Whisper, Nemotron or Qwen3-ASR |
| `mic-standby` | `on` · `off` | `off` | Keep the microphone open while idle |
| `microphone` | `built-in` · `system` · name | `built-in` | Which microphone records |
| `menubar` | `on` · `off` | `on` | Show the menu bar icon |
| `pause-media` | `on` · `off` | `off` | Pause Spotify/Music while recording |
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

LocalVoice.app defaults to **Automatic**. Whisper chooses between German and
English; Nemotron, Qwen3-ASR and Parakeet use their own automatic modes.
Choices for Whisper, Nemotron and Qwen3-ASR are stored per model (for example,
`language.whisper-turbo-q4 = de`) and apply to the next dictation. Parakeet
does not accept a language hint. The old global `language` key is used only
by legacy installs and remains untouched.

Legacy installs still support:

- `de` / `en` — transcribe everything as German / English.
- `auto` — Whisper detects the language per recording, deliberately restricted
  to the German/English pair (the full 99-language ranking readily mistakes
  German for Dutch).

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
  `microphone = Shure MV7`. Settings lists the devices currently
  attached; the setting stores the *name*, so it keeps pointing at the same
  physical device across unplugs and replugs.

A setting that matches nothing warns in the log and falls back to the system
default, so dictation keeps working. Changes apply from the next recording
(or immediately in standby mode).

### `menubar`

`on` (default) shows the LocalVoice icon in the menu bar, with Settings, Models,
permission setup, restart, and quit.
`off` hides the icon; like everything here it takes effect within seconds.
Settings has the same switch. With the icon hidden, open LocalVoice again
to get back to Settings.

### `pause-media`

`on` pauses media players when a recording starts and resumes them
the moment it stops. Only players that were actually *playing* are paused,
and only those are resumed — music that was not running is never started.
Covered players: Spotify and Apple Music (scriptable over Apple Events;
browser tabs are not reachable this way). macOS asks once per player for
the Automation permission ("LocalVoice wants to control Spotify"). Turning
the option on in Settings asks right away for the players that are open, and
the line under the option shows whether each is allowed, with a shortcut to
Privacy & Security › Automation if it was declined. A player that was closed
at that moment is asked about the first time it plays while you dictate.

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

Qwen3-ASR receives the same list as its *context*, the prompt it was trained
to take domain terms from. Parakeet and Nemotron ignore the list. While one of
them is in use, Settings greys **Vocabulary** out, names a model that reads
it, and leaves the saved words untouched.

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

## Migration from pre-1.2 versions

Older versions kept single-value files under `~/.config/ctrlspeak` (`hotkey`,
`language`, `mic-standby`). On its first start, version 1.2 folds their values
into the new config file; until then they are still honoured as a fallback.
`~/.config/ctrlspeak` itself remains in use for the service's internal state
(installed version, the single-instance lock).
