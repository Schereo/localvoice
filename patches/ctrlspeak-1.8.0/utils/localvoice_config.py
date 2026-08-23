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
}

VALID_LANGUAGES = {"de", "en", "auto"}
VALID_HOTKEY_MODIFIERS = {"ctrl", "cmd", "alt", "shift"}
_TRUTHY = {"on", "true", "1", "yes"}

_TEMPLATE = """\
# LocalVoice configuration.
# Reference: https://github.com/Schereo/localvoice/blob/main/docs/configuration.md
#
# The running service picks up changes within a couple of seconds — no
# restart needed. While the recording pill is on screen, Cmd+, opens this
# file in your text editor.

# Activation hotkey, as <modifier>,<taps>.
# Modifier: ctrl, cmd, alt or shift. Taps: 2-4. Example: cmd,2 = double-tap Cmd.
hotkey = {hotkey}

# Transcription language: de, en or auto (detects German vs English per
# recording). Clicking the pill's language badge cycles this and writes the
# choice back here.
language = {language}

# Compact recording pill: "on" hides the language badge, leaving only the
# dot, waveform and timer. Set the language above instead.
compact = {compact}

# Keep the microphone stream open while idle: instant recording starts, at
# the price of an always-lit macOS microphone indicator.
mic-standby = {mic_standby}
"""


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


def ensure_config_file():
    """Create the config file if it is missing, migrating legacy values.

    Returns the config file path either way.
    """
    if CONFIG_FILE.exists():
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

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    _atomic_write(
        _TEMPLATE.format(
            hotkey=values["hotkey"],
            language=values["language"],
            compact=values["compact"],
            mic_standby=values["mic-standby"],
        )
    )
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
