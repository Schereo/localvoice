"""
Clipboard operations module for ctrlSPEAK.
"""
import logging
import time
import subprocess

logger = logging.getLogger("ctrlspeak.clipboard")

# pbcopy reaches the pasteboard server over synchronous XPC, and when that
# server wedges the call never returns on its own. Everything here runs on
# pynput's CGEventTap callback, so an unbounded wait freezes dictation
# outright. Five seconds is far longer than a healthy pasteboard needs.
CLIPBOARD_TIMEOUT_S = 5.0

# Focused-element roles that clearly accept keyboard text input.
_TEXT_ROLES = {
    "AXTextField",
    "AXTextArea",
    "AXSearchField",
    "AXComboBox",
}


def copy_to_clipboard(text):
    """Copy text to the clipboard. Returns True when it actually landed.

    A wedged pasteboard server used to hang the whole session here: the
    transcript was finished, pbcopy never returned, and the pill sat on
    "transcribing" until the service was restarted. Failing is fine —
    hanging is not, so this reports the outcome instead of raising into
    the hotkey handler.
    """
    # PyObjC's NSPasteboard backend can silently keep stale contents when
    # called from pynput's listener thread. macOS pbcopy is thread-safe and
    # addresses the active user's general pasteboard directly.
    try:
        subprocess.run(
            ["/usr/bin/pbcopy"],
            input=str(text),
            text=True,
            check=True,
            timeout=CLIPBOARD_TIMEOUT_S,
        )
        return True
    except subprocess.TimeoutExpired:
        logger.error(
            f"pbcopy did not return within {CLIPBOARD_TIMEOUT_S:.0f}s — the macOS "
            "pasteboard server is not responding. Restarting it usually clears "
            "this: killall pboard"
        )
        return False
    except (subprocess.SubprocessError, OSError) as exc:
        logger.error(f"Could not copy to the clipboard: {exc}")
        return False


def _focused_element_accepts_text():
    """Best-effort check whether the focused UI element can take a paste.

    Only a confident "no" suppresses the paste. Apps with incomplete
    accessibility trees (many Electron apps) report nothing useful here, yet
    Cmd+V works fine in them — so every uncertain outcome returns True to
    preserve the old behaviour.
    """
    try:
        from ApplicationServices import (
            AXUIElementCreateSystemWide,
            AXUIElementCopyAttributeValue,
        )

        system_wide = AXUIElementCreateSystemWide()
        error, focused = AXUIElementCopyAttributeValue(
            system_wide, "AXFocusedUIElement", None
        )
        if error != 0 or focused is None:
            return True

        error, role = AXUIElementCopyAttributeValue(focused, "AXRole", None)
        if error != 0 or role is None:
            return True

        if str(role) in _TEXT_ROLES:
            return True

        # Editable web content and custom views rarely use the text roles but
        # do expose a selected text range.
        error, _ = AXUIElementCopyAttributeValue(
            focused, "AXSelectedTextRange", None
        )
        if error == 0:
            return True

        logger.info(f"Focused element role {role} does not accept text; keeping clipboard only")
        return False
    except Exception as exc:
        logger.debug(f"Could not inspect the focused element: {exc}")
        return True


def type_text(text):
    """Type the transcript straight into the focused field.

    The fallback for when the clipboard is unavailable. Universal Clipboard
    resolves remote items on the pasteboard's serial queue, so if the other
    device does not answer, every local pasteboard operation queues behind
    it and pbcopy cannot land — while Handoff, which is worth keeping, is
    exactly what causes that. Synthetic keystrokes need none of it.

    Not the default: typing is slower than a paste, and a few apps drop
    characters from fast synthetic input where Cmd+V is atomic. It runs
    only where the alternative is delivering nothing at all.

    Returns True when the text was typed, False when nothing could take it.
    """
    if not _focused_element_accepts_text():
        return False

    from pynput import keyboard

    kb = keyboard.Controller()
    time.sleep(0.1)
    try:
        kb.type(text)
    except Exception as exc:
        logger.error(f"Could not type the transcript: {exc}")
        return False

    logger.info(f"Typed the transcript directly ({len(text)} chars).")
    return True


def paste_from_clipboard():
    """Paste into the focused text field, if there is one.

    Returns True when Cmd+V was sent, False when no text target was found and
    the transcript stays on the clipboard instead.
    """
    if not _focused_element_accepts_text():
        return False

    # Create keyboard controller
    from pynput import keyboard
    kb = keyboard.Controller()

    # Small delay to ensure clipboard is ready
    time.sleep(0.1)

    # Simulate Command+V to paste
    with kb.pressed(keyboard.Key.cmd):
        kb.press('v')
        kb.release('v')

    return True
