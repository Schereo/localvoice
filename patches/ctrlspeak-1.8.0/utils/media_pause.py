"""
Pause other audio while dictation records.

When a recording starts, the media players that are actually playing are
paused; when it ends, exactly those are resumed. The playing check matters:
blindly toggling play/pause would *start* music for anyone who had none
running. Spotify and Music expose their player state over Apple Events, which
also means macOS asks once for the Automation permission ("LocalVoice wants
to control Spotify") on first use.

Browser tabs are out of scope: reaching them would need the private
MediaRemote framework, which recent macOS releases restrict.
"""

import logging
import subprocess

logger = logging.getLogger("ctrlspeak.media_pause")

# Scriptable players with a queryable "player state". Extend as needed.
_PLAYERS = ("Spotify", "Music")
_PLAYER_BUNDLES = {
    "com.spotify.client": "Spotify",
    "com.apple.Music": "Music",
}

# Apps this module paused for the current recording session, to be resumed
# when it ends. Only touched from the hotkey worker thread.
_paused_apps = []


def _running_players():
    """Return the subset of _PLAYERS currently running, without spawning osascript."""
    try:
        from AppKit import NSWorkspace

        running = {
            str(app.bundleIdentifier())
            for app in NSWorkspace.sharedWorkspace().runningApplications()
            if app.bundleIdentifier()
        }
        return [name for bundle_id, name in _PLAYER_BUNDLES.items() if bundle_id in running]
    except Exception:
        # Outside AppKit (e.g. unit tests without PyObjC), fall back to asking osascript.
        return list(_PLAYERS)


def _pause_script(players):
    return "\n".join(
        ["set pausedApps to {}"]
        + [
            f'''if application "{app}" is running then
    tell application "{app}"
        if player state is playing then
            pause
            set end of pausedApps to "{app}"
        end if
    end tell
end if'''
            for app in players
        ]
        + ["return pausedApps"]
    )


def _osascript(script, timeout):
    """Run a script; the timeout covers a pending Automation permission
    prompt, which blocks the Apple Event until the user decides."""
    return subprocess.run(
        ["/usr/bin/osascript", "-e", script],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def pause_playing():
    """Pause every known player that is currently playing; remember which."""
    global _paused_apps
    _paused_apps = []

    players = _running_players()
    if not players:
        return

    try:
        result = _osascript(_pause_script(players), timeout=8)
    except subprocess.TimeoutExpired:
        logger.warning(
            "Pausing media players timed out — likely waiting on the "
            "Automation permission dialog; answer it and dictate again."
        )
        return
    except OSError as exc:
        logger.warning(f"Could not run osascript: {exc}")
        return

    if result.returncode != 0:
        logger.warning(f"Could not pause media players: {result.stderr.strip()}")
        return

    names = [name.strip() for name in result.stdout.strip().split(",")]
    _paused_apps = [name for name in names if name in _PLAYERS]
    if _paused_apps:
        logger.info(f"Paused for dictation: {', '.join(_paused_apps)}")


def paused_any():
    """Whether the last pause_playing() stopped any player."""
    return bool(_paused_apps)


def resume_paused():
    """Resume exactly the players pause_playing() stopped. No-op otherwise."""
    global _paused_apps
    apps, _paused_apps = _paused_apps, []

    for app in apps:
        try:
            _osascript(f'tell application "{app}" to play', timeout=8)
        except (subprocess.TimeoutExpired, OSError) as exc:
            logger.warning(f"Could not resume {app}: {exc}")

    if apps:
        logger.info(f"Resumed after dictation: {', '.join(apps)}")
