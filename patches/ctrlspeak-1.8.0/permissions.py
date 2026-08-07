"""Permission gate that also reports its result in the native pill.

ctrlSPEAK runs as a LaunchAgent, so a missing permission would otherwise only
show up in the log file: the process exits before the UI is ever drawn. The
pill gives that failure somewhere visible on screen.
"""

import logging
import sys
import subprocess
import time
from rich.panel import Panel
import state
from overlay import StatusOverlay, close_startup_pill
from utils import permission_manager

logger = logging.getLogger("ctrlspeak.permissions")

# ctrlSPEAK exits straight after a failed check, so the pill needs its own
# dwell time or it would vanish before it could be read.
PILL_LINGER_SECONDS = 8.0


def _detect_missing_permissions():
    """Check quietly up front so the pill can name every gap at once.

    The verbose checks below exit at the first failure, which would leave the
    user fixing one permission only to be stopped by the next one.
    """
    missing = []

    try:
        if not permission_manager.check_microphone_permissions(verbose=False, console=state.console):
            missing.append("Microphone")
    except Exception as exc:
        logger.warning(f"Could not determine microphone permission state: {exc}")
        missing.append("Microphone")

    try:
        if not permission_manager.check_keyboard_permissions(verbose=False, console=state.console):
            missing.append("Accessibility")
    except Exception as exc:
        logger.warning(f"Could not determine accessibility permission state: {exc}")
        missing.append("Accessibility")

    return missing


def _run_permission_checks():
    """Original ctrlSPEAK permission flow, including its console output."""
    try:
        state.console.print("\n[bold]Step 1 of 2: Checking microphone access...[/bold]")
        if not permission_manager.check_microphone_permissions(verbose=True, console=state.console):
            state.console.print(Panel.fit(
                "[bold red]Microphone access required[/bold red]\n\n"\
                "ctrlspeak needs microphone access to record your speech.\n"\
                "Without this permission, the app cannot transcribe audio.\n\n"\
                "[yellow]Opening System Settings → Privacy & Security → Microphone...[/yellow]\n"\
                "Please add and enable this application in the list.",
                title="Permission Required",
                border_style="red"
            ))
            subprocess.run(["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"])
            state.console.print("\nPlease restart the application after granting permission.")
            sys.exit(1)
        else:
            state.console.print("[bold green]✓ Microphone access is granted.[/bold green]")
    except Exception as e:
        state.console.print(f"[bold red]Error accessing microphone: {e}[/bold red]")
        sys.exit(1)

    state.console.print("\n[bold]Step 2 of 2: Checking keyboard monitoring permissions...[/bold]")
    if not permission_manager.check_keyboard_permissions(verbose=True, console=state.console):
        state.console.print("\nPlease restart the application after granting permission.")
        sys.exit(1)

    state.console.print("\n[bold green]All required permissions are granted! Starting ctrlSPEAK...[/bold green]")

    return True


def check_permissions():
    """Check and request necessary permissions, mirroring the state in the pill."""
    missing = _detect_missing_permissions()

    if not missing:
        return _run_permission_checks()

    logger.warning(f"Missing macOS permissions: {', '.join(missing)}")

    # A cold-cache start may have a "Downloading model" startup pill waiting
    # for a download that will never begin; replace it with the real problem.
    close_startup_pill()

    overlay = StatusOverlay("permission", state.source_lang).start()
    overlay.set_detail(" · ".join(missing))

    try:
        return _run_permission_checks()
    finally:
        time.sleep(PILL_LINGER_SECONDS)
        overlay.close()
