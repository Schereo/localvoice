# Adding a language

Whisper Large V3 Turbo already understands ~100 languages — LocalVoice limits
the choice to German and English on purpose, mainly to keep `AUTO` detection
reliable (ranking all 100 languages readily mistakes German for Dutch; a small
set of acoustically distinct languages does not have that problem).

Adding one, say Spanish (`es`), touches four places. Languages are named by
their ISO 639-1 code, the same codes Whisper uses.

## 1. The model gate — `patches/ctrlspeak-1.8.0/models/whisper_mlx.py`

```python
SUPPORTED_LANGUAGES = {"de", "en", "es"}
```

This single set gates transcription *and* defines the candidate pool for
`AUTO`: `detect_language()` compares exactly these languages' probabilities.

## 2. The badge — `src/ctrlspeak-overlay.swift`

```swift
static let languageCycle = ["DE", "EN", "ES", "AUTO"]
```

Clicking the badge cycles this list. In `drawLanguageSelection`, add a display
name for the preview mode (`case "ES": languageName = "Spanish"`). The badge
chip fits labels up to four letters as-is.

## 3. The runtime validation — `patches/ctrlspeak-1.8.0/hotkeys.py`

In `_apply_language`, extend the accepted set:

```python
if language not in {"de", "en", "es", "auto"}:
```

## 4. The installer — `install.sh`

Two guards mention the codes: the `CTRLSPEAK_LANGUAGE` check near the top and
the `SAVED_LANGUAGE` validation inside the generated wrapper script. Add the
new code to both.

## Deploying the change

The full path is `./install.sh` — but that rebuilds the app bundle, and under
ad-hoc signing a rebuild is a new identity, so macOS will ask for the three
permissions again. The lighter path avoids that, because the pill binary and
the Python patches live *outside* the app bundle:

```bash
xcrun swiftc src/ctrlspeak-overlay.swift -o /opt/homebrew/bin/ctrlspeak-overlay
install -m 644 patches/ctrlspeak-1.8.0/models/whisper_mlx.py /opt/homebrew/opt/ctrlspeak/libexec/models/whisper_mlx.py
install -m 644 patches/ctrlspeak-1.8.0/hotkeys.py /opt/homebrew/opt/ctrlspeak/libexec/hotkeys.py
./scripts/restart.sh
```

## Notes

- Keep the `AUTO` pool small and acoustically distinct. Every language you add
  joins the detection ranking; closely related pairs (e.g. Spanish/Portuguese)
  raise the odds of a wrong pick on short or mumbled recordings.
- Transcription quality varies by language — the well-resourced European
  languages, Japanese and Korean perform close to English; low-resource
  languages degrade noticeably, and the Turbo distillation is known to have
  lost some accuracy on a few (Thai and Cantonese among them).
- No model change is needed: the same downloaded weights serve every language.
