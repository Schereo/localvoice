"""
LocalVoice's user configuration.

Every user-facing preference lives in one key = value file at
~/.config/localvoice/config: the activation hotkey, the transcription
language, the compact pill, and microphone standby. The file is plain text on
purpose — Cmd+, while the recording pill is on screen opens it in the default
text editor, and the running service applies edits within a couple of seconds.

The pre-1.2 single-value files under ~/.config/ctrlspeak (hotkey, language,
mic-standby) are still read as a fallback and their values are folded into the
config file when it is first created, so an upgrade keeps the user's settings.
"""

import logging
import os
from pathlib import Path

logger = logging.getLogger("ctrlspeak.localvoice_config")

CONFIG_DIR = Path(
    os.environ.get("LOCALVOICE_CONFIG_DIR", str(Path.home() / ".config" / "localvoice"))
)
CONFIG_FILE = CONFIG_DIR / "config"

# Where the pre-1.2 preference files live; ~/.config/ctrlspeak stays the home
# of the service's internal state (setup-status, installed-version, lock).
_LEGACY_DIR = Path.home() / ".config" / "ctrlspeak"
_LEGACY_FILES = {"hotkey": "hotkey", "language": "language", "mic-standby": "mic-standby"}

DEFAULTS = {
    "hotkey": "ctrl,3",
    "language": "de",
    "compact": "off",
    "mic-standby": "off",
    "microphone": "built-in",
    "menubar": "on",
    "pause-media": "on",
    "vocabulary": "",
    "live-preview": "off",
}

VALID_LANGUAGES = {"de", "en", "auto"}
VALID_HOTKEY_MODIFIERS = {"ctrl", "cmd", "alt", "shift"}
_TRUTHY = {"on", "true", "1", "yes"}

_HEADER = """\
# LocalVoice configuration.
# Reference: https://github.com/Schereo/localvoice/blob/main/docs/configuration.md
#
# The running service picks up changes within a couple of seconds — no
# restart needed. While the recording pill is on screen, Cmd+, opens this
# file in your text editor.
"""

# One block per key: the comment that documents it plus the assignment. Used
# to write a fresh file, and to append keys a pre-existing config does not
# know yet, so an upgraded install stays self-documenting.
_KEY_BLOCKS = {
    "hotkey": """\
# Activation hotkey, as <modifier>,<taps>.
# Modifier: ctrl, cmd, alt or shift. Taps: 2-4. Example: cmd,2 = double-tap Cmd.
""",
    "language": """\
# Transcription language: de, en or auto (detects German vs English per
# recording). Clicking the pill's language badge cycles this and writes the
# choice back here.
""",
    "compact": """\
# Compact recording pill: "on" hides the language badge, leaving only the
# dot, waveform and timer. Set the language above instead.
""",
    "mic-standby": """\
# Keep the microphone stream open while idle: instant recording starts, at
# the price of an always-lit macOS microphone indicator.
""",
    "microphone": """\
# Which microphone records. "built-in" is the Mac's internal mic — the
# default, because recording through Bluetooth headphones (AirPods) drops
# all their audio into phone-call quality while the mic is open. "system"
# follows the macOS default input; anything else matches a device name,
# e.g. "Shure MV7". The menu bar icon lists what is available.
""",
    "menubar": """\
# Show the LocalVoice icon in the menu bar (on | off).
""",
    "pause-media": """\
# Pause playing media players (Spotify, Music) when a recording starts and
# resume exactly those when it ends. First use asks once for the macOS
# Automation permission per player.
""",
    "vocabulary": """\
# Words the transcriber should know and spell correctly — names, brands,
# jargon. Comma-separated: vocabulary = Ada, ctrlSPEAK, MLX
# The model reads this list before every recording; keep it to the terms
# that actually come up, a few dozen at most.
""",
    "live-preview": """\
# Show the transcript inside the recording pill while you speak: confirmed
# text after each pause, plus a dimmed live guess of the current phrase.
# The live guess re-runs the model about once a second while you talk.
""",
}


def load():
    """Parse the config file into a raw {key: value} dict.

    Unknown keys are kept (harmless, and future versions may know them);
    comments and malformed lines are skipped. A missing file is an empty dict.
    """
    values = {}
    try:
        raw = CONFIG_FILE.read_text(encoding="utf-8")
    except OSError:
        return values

    for line in raw.splitlines():
        entry = line.strip()
        if not entry or entry.startswith("#") or "=" not in entry:
            continue
        key, _, value = entry.partition("=")
        values[key.strip().lower()] = value.strip()
    return values


def _read_legacy(key):
    """Value from the matching pre-1.2 single-value file, or None."""
    name = _LEGACY_FILES.get(key)
    if name is None:
        return None
    try:
        value = (_LEGACY_DIR / name).read_text(encoding="utf-8").strip()
        return value or None
    except OSError:
        return None


def effective(key):
    """Raw value for a key: config file first, then legacy file, then default."""
    value = load().get(key)
    if value:
        return value
    return _read_legacy(key) or DEFAULTS.get(key)


def as_bool(key):
    return str(effective(key)).strip().lower() in _TRUTHY


def language():
    """The configured transcription language, validated."""
    value = str(effective("language")).strip().lower()
    return value if value in VALID_LANGUAGES else DEFAULTS["language"]


def parse_hotkey(raw):
    """Parse '<modifier>,<taps>' into (modifier, taps), or None if invalid."""
    if not raw:
        return None
    modifier, _, taps_text = str(raw).strip().lower().partition(",")
    try:
        taps = int(taps_text)
    except ValueError:
        return None
    if modifier in VALID_HOTKEY_MODIFIERS and 2 <= taps <= 4:
        return modifier, taps
    return None


def hotkey():
    """The configured (modifier, taps) activation gesture, validated."""
    return parse_hotkey(effective("hotkey")) or parse_hotkey(DEFAULTS["hotkey"])


def vocabulary():
    """User-taught words the transcriber should spell correctly, as a list."""
    raw = str(effective("vocabulary") or "")
    return [word.strip() for word in raw.split(",") if word.strip()]


def ensure_config_file():
    """Create the config file if missing; append keys it does not know yet.

    A fresh file starts from the legacy-migrated values; an existing file is
    left untouched except that keys introduced by newer versions are appended
    with their documentation, so the file the user opens always shows every
    available setting. Returns the config file path either way.
    """
    if CONFIG_FILE.exists():
        known = load()
        missing = [key for key in _KEY_BLOCKS if key not in known]
        if missing:
            content = CONFIG_FILE.read_text(encoding="utf-8")
            if content and not content.endswith("\n"):
                content += "\n"
            for key in missing:
                content += "\n" + _KEY_BLOCKS[key] + f"{key} = {DEFAULTS[key]}\n"
            _atomic_write(content)
            logger.info(f"Added new configuration keys: {', '.join(missing)}")
        return CONFIG_FILE

    values = dict(DEFAULTS)
    for key in _LEGACY_FILES:
        legacy = _read_legacy(key)
        if legacy:
            values[key] = legacy.lower()

    # Never bake an invalid migrated value into the fresh template.
    if values["language"] not in VALID_LANGUAGES:
        values["language"] = DEFAULTS["language"]
    if parse_hotkey(values["hotkey"]) is None:
        values["hotkey"] = DEFAULTS["hotkey"]
    values["mic-standby"] = "on" if values["mic-standby"] in _TRUTHY else "off"
    values["compact"] = "on" if values["compact"] in _TRUTHY else "off"

    content = _HEADER
    for key, block in _KEY_BLOCKS.items():
        content += "\n" + block + f"{key} = {values[key]}\n"

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    _atomic_write(content)
    logger.info(f"Created the configuration file at {CONFIG_FILE}")
    return CONFIG_FILE


def set_value(key, value):
    """Persist one key, keeping the rest of the file (comments included)."""
    ensure_config_file()

    lines = CONFIG_FILE.read_text(encoding="utf-8").splitlines(keepends=True)
    replaced = False
    for index, line in enumerate(lines):
        entry = line.strip()
        if not entry or entry.startswith("#") or "=" not in entry:
            continue
        if entry.partition("=")[0].strip().lower() == key:
            lines[index] = f"{key} = {value}\n"
            replaced = True
            break

    if not replaced:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(f"{key} = {value}\n")

    _atomic_write("".join(lines))


def _atomic_write(content):
    temporary_file = CONFIG_FILE.with_name(CONFIG_FILE.name + ".tmp")
    temporary_file.write_text(content, encoding="utf-8")
    os.replace(temporary_file, CONFIG_FILE)
