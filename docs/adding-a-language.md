# Adding a language

Whisper Large V3 Turbo already understands ~100 languages — LocalVoice limits
the choice to German and English on purpose, mainly to keep `AUTO` detection
reliable (ranking all 100 languages readily mistakes German for Dutch; a small
set of acoustically distinct languages does not have that problem).

Adding one, say Spanish (`es`), touches two places. Languages are named by
their ISO 639-1 code, the same codes Whisper uses.

## 1. The model gate — `patches/ctrlspeak-1.8.0/models/whisper_mlx.py`

```python
SUPPORTED_LANGUAGES = {"de", "en", "es"}
```

This single set gates transcription *and* defines the candidate pool for
`AUTO`: `detect_language()` compares exactly these languages' probabilities.

## 2. The runtime validation — `patches/ctrlspeak-1.8.0/utils/localvoice_config.py`

Extend the one set every consumer (the config file, the Settings window)
validates against:

```python
VALID_LANGUAGES = {"de", "en", "es", "auto"}
```

## Trying it

Build a test app with `python3 -B scripts/build-dev-app.py` (see
[setup](setup.md#local-test-app)).

## Notes

- Keep the `AUTO` pool small and acoustically distinct. Every language you add
  joins the detection ranking; closely related pairs (e.g. Spanish/Portuguese)
  raise the odds of a wrong pick on short or mumbled recordings.
- Transcription quality varies by language — the well-resourced European
  languages, Japanese and Korean perform close to English; low-resource
  languages degrade noticeably, and the Turbo distillation is known to have
  lost some accuracy on a few (Thai and Cantonese among them).
- No model change is needed: the same downloaded weights serve every language.
