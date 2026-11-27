"""The command channel between the LocalVoice app and this service.

When the app starts the service it owns the global shortcuts itself (a native
event tap and Carbon hotkeys, which can swallow Esc and Enter), and sets
LOCALVOICE_HOTKEYS=app. The service then runs no keyboard listener of its
own. Its stdin is one end of a Unix socket pair, carrying a line protocol in
both directions (see docs/how-it-works.md):

    app -> service   toggle | finish | discard | quit
    service -> app   ready | recording 1 | recording 0

"ready" is sent once the service accepts commands; the app drops gestures
made before it, so a tap while the model loads does not start a recording
seconds later.

Unknown commands are ignored, so either side can learn new ones first. EOF
means the app is gone, as with the stdin lifeline: the service stops.

Run standalone (no LOCALVOICE_HOTKEYS), the service keeps its pynput
listener as before.
"""

import logging
import os
import queue
import socket
import threading

logger = logging.getLogger("ctrlspeak.app_control")

_outbox = queue.Queue()
_started = False
_channel = None
_commands = None


def enabled():
    """Whether the app owns the shortcuts and drives the service over stdin."""
    return os.environ.get("LOCALVOICE_HOTKEYS") == "app"


def publish_recording(active):
    """Tell the app whether a recording is collecting audio (never blocks)."""
    if _started:
        _outbox.put(f"recording {1 if active else 0}\n".encode("ascii"))


def handle(line, commands):
    """Run the handler for one received line; return the command name or None."""
    name = line.strip().decode("ascii", "replace")
    handler = commands.get(name)
    if handler is None:
        if name:
            logger.debug("Ignoring unknown app command %r.", name)
        return None
    try:
        handler()
    except Exception:
        logger.exception("App command '%s' failed.", name)
    return name


def listen(on_eof, fd=0):
    """Start reading `fd` (a socket) so EOF is heard from the first moment.

    Called early in startup: the app can quit while the model is still
    loading, and the service must stop then too. Lines arriving before
    `start` installs the commands are dropped (the app sends none before
    "ready" anyway). With fd 0, stdin is pointed at /dev/null afterwards, so
    helper processes (the capture child, osascript) do not inherit the socket
    and keep it open past the service's exit. Raises OSError if `fd` is not a
    socket.
    """
    global _channel
    if _channel is not None:
        return
    duplicate = os.dup(fd)
    try:
        channel = socket.socket(fileno=duplicate)
    except OSError:
        os.close(duplicate)
        raise
    channel.setblocking(True)
    if fd == 0:
        try:
            null = os.open(os.devnull, os.O_RDONLY)
            os.dup2(null, 0)
            os.close(null)
        except OSError:
            logger.warning("Could not detach stdin from the command channel.")
    _channel = channel

    def receive():
        try:
            with channel.makefile("rb") as stream:
                for line in stream:
                    if _commands is not None:
                        handle(line, _commands)
        except OSError:
            pass
        on_eof()

    threading.Thread(target=receive, name="AppControlReader", daemon=True).start()


def start(commands, on_eof, fd=0):
    """Serve commands from the app on `fd` and tell it the service is ready.

    `commands` maps command names to callables that return promptly (they
    enqueue, like the pynput callbacks did). `on_eof` runs once the app
    closes its end; it is ignored if `listen` already runs. Raises OSError
    if `fd` is not a socket.
    """
    global _started, _commands
    listen(on_eof, fd)
    channel = _channel

    def send():
        while True:
            message = _outbox.get()
            try:
                channel.sendall(message)
            except OSError:
                return

    _commands = commands
    _started = True
    _outbox.put(b"ready\n")
    threading.Thread(target=send, name="AppControlWriter", daemon=True).start()
