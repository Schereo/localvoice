"""
Clipboard operations module for ctrlSPEAK.
"""
import logging
import time
import subprocess

logger = logging.getLogger("ctrlspeak.clipboard")

# Focused-element roles that clearly accept keyboard text input.
_TEXT_ROLES = {
    "AXTextField",
    "AXTextArea",
    "AXSearchField",
    "AXComboBox",
}


def copy_to_clipboard(text):
    """Copy text to clipboard"""
    # PyObjC's NSPasteboard backend can silently keep stale contents when
    # called from pynput's listener thread. macOS pbcopy is thread-safe and
    # addresses the active user's general pasteboard directly.
    subprocess.run(
        ["/usr/bin/pbcopy"],
        input=str(text),
        text=True,
        check=True,
    )


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
