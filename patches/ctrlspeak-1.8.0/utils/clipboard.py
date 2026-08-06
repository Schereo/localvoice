"""
Clipboard operations module for ctrlSPEAK.
"""
import time
import subprocess

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

def paste_from_clipboard():
    """Simulate Command+V to paste from clipboard"""
    # Create keyboard controller
    from pynput import keyboard
    kb = keyboard.Controller()

    # Small delay to ensure clipboard is ready
    time.sleep(0.1)

    # Simulate Command+V to paste
    with kb.pressed(keyboard.Key.cmd):
        kb.press('v')
        kb.release('v')
