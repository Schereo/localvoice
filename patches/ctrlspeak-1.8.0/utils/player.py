"""
Sound player utility for playing audio feedback.

Uses macOS AppKit NSSound directly instead of PortAudio/sounddevice.
PortAudio's Pa_CloseStream can wedge in a 100%-CPU busy loop on macOS when
playback streams collide with CoreAudio capture, leaking a pinned CPU core per
beep. NSSound plays the bundled WAV files natively through CoreAudio without
loading libportaudio or libsndfile.
"""
import logging
import os
import threading

logger = logging.getLogger("sound_player")


class SoundPlayer:
    """Class for playing sound effects."""

    def __init__(self):
        self.sounds = {}
        self.base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        self._sounds_loaded = False
        self._lock = threading.Lock()

    def _load_sounds(self):
        if self._sounds_loaded:
            return
        with self._lock:
            if self._sounds_loaded:
                return
            try:
                from AppKit import NSSound
            except Exception as exc:
                logger.warning("Native sound playback unavailable (%s).", type(exc).__name__)
                self._sounds_loaded = True
                return

            paths = {
                "start": os.path.join(self.base_dir, "on.wav"),
                "stop": os.path.join(self.base_dir, "off.wav"),
            }
            for name, path in paths.items():
                if not os.path.exists(path):
                    logger.error("Sound file not found: %s", path)
                    continue
                try:
                    sound = NSSound.alloc().initWithContentsOfFile_byReference_(path, True)
                    if sound is not None:
                        self.sounds[name] = sound
                        logger.debug("Loaded %s for %s sound", os.path.basename(path), name)
                except Exception as exc:
                    logger.error("Error loading sound %s (%s).", name, type(exc).__name__)

            self._sounds_loaded = True

    def play(self, sound_name):
        """Play a sound by name ('start' or 'stop') without blocking."""
        self._load_sounds()
        sound = self.sounds.get(sound_name)
        if sound is None:
            return
        try:
            # Copy so rapid start/stop beeps never cut each other off or race on
            # one NSSound instance's internal state.
            instance = sound.copy()
            if instance is not None:
                instance.play()
            else:
                sound.stop()
                sound.play()
        except Exception as exc:
            logger.error("Error playing sound %s (%s).", sound_name, type(exc).__name__)


# Singleton instance
player = SoundPlayer()


def play_start_beep():
    """Play the start recording beep."""
    player.play("start")


def play_stop_beep():
    """Play the stop recording beep."""
    player.play("stop")
