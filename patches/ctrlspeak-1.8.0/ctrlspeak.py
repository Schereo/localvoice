#!/usr/bin/env python3
"""
ctrlspeak - A speech-to-text utility that runs in the background.
Triple-tap Ctrl to start/stop recording.
"""
import signal
import sys
import os
from utils.tqdm_lock import ensure_tqdm_thread_lock  # lightweight import

# Apply immediately at import time to preempt tqdm's default lock behavior
ensure_tqdm_thread_lock()

import time
import threading
import logging
from rich.console import Console
from rich.panel import Panel

# Add the project root to the Python path
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from cli import parse_args_only
from utils.config import is_first_run, mark_first_run_complete, set_preferred_model

import state
from state import console, KNOWN_MODELS
from logging_config import setup_logging, setup_logging_for_mode
from environment import save_environment_variables, restore_environment_variables

logger = logging.getLogger("ctrlspeak")
MANAGED_MODEL_UNAVAILABLE = 78


def find_cached_models():
    """Scans the Hugging Face cache directory for known ctrlspeak models."""
    cached = set()
    try:
        from huggingface_hub import scan_cache_dir

        cache_info = scan_cache_dir()
        logger.info(f"Scanning Hugging Face cache ({cache_info.size_on_disk_str} total)")

        for repo in cache_info.repos:
            # Only check models (not datasets/spaces) that are in our known set
            if repo.repo_type == "model" and repo.repo_id in KNOWN_MODELS:
                cached.add(repo.repo_id)
                logger.debug(f"Found cached model: {repo.repo_id}")

    except Exception as e:
        logger.error(f"Error scanning Hugging Face cache: {e}", exc_info=state.DEBUG_MODE)
        console.print(f"[yellow]Warning: Could not scan Hugging Face cache ({e})[/yellow]")

    logger.info(f"Found cached models: {cached}")
    return cached


def _load_mic_standby():
    """Read the standby preference; absent everywhere means on-demand (off)."""
    from utils import localvoice_config

    return localvoice_config.as_bool("mic-standby")


# Held for the process lifetime; a with-statement would release it at once.
_instance_lock_handle = None


def _acquire_single_instance_lock():
    """Claim the one-service lock, or report that another instance holds it.

    Two live services — launchd's plus one started by double-clicking the
    app — each run their own hotkey listener and their own pill, and a
    preference saved in one is invisible in the other: language toggles that
    "do not stick" were exactly this. The lock makes the second arrival exit
    instead; released by the kernel on any death, os._exit included.
    """
    global _instance_lock_handle
    import fcntl
    from pathlib import Path

    private_state = os.environ.get("LOCALVOICE_STATE_DIR")
    lock_dir = Path(private_state) if private_state else Path.home() / ".config" / "ctrlspeak"
    lock_path = lock_dir / "service.lock"
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        handle = open(lock_path, "w")
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return False

    handle.write(f"{os.getpid()}\n")
    handle.flush()
    _instance_lock_handle = handle
    return True


def _start_config_watcher():
    """Apply edits to the LocalVoice config file to the running service.

    The config opens in a plain text editor (Cmd+, while the pill is up), so
    the natural flow is edit, save, speak — a restart requirement would turn
    that into edit, save, wonder why nothing changed. Polling the mtime every
    couple of seconds is cheap and avoids an FSEvents dependency.
    """
    import hotkeys
    from utils import localvoice_config
    from utils.keyboard_shortcuts import load_hotkey_config

    def _mtime():
        try:
            return localvoice_config.CONFIG_FILE.stat().st_mtime
        except OSError:
            return None

    def _apply_changes():
        manager = state.keyboard_manager
        modifier, taps = load_hotkey_config()
        if (modifier, taps) != (manager.tap_modifier, manager.tap_count_required):
            manager.tap_modifier = modifier
            manager.tap_count_required = taps
            logger.info(f"Hotkey changed to: {manager.hotkey_description}")

        if not os.environ.get("LOCALVOICE_MODEL_ID"):
            language = localvoice_config.language()
            if language != state.source_lang:
                hotkeys._apply_language(language, persist=False)

        from utils.audio import resolve_input_device

        device = resolve_input_device(localvoice_config.effective("microphone"))
        standby = localvoice_config.as_bool("mic-standby")
        audio = state.audio_manager
        with audio.input_stream_lock:
            # Make the "idle" decision and stream action atomic with Stop,
            # Esc, and opening a new recording.
            if device != audio.input_device:
                logger.info(f"Capture device changed to: {device or 'system default'}")
                if audio.is_collecting or not state.mic_standby:
                    audio.input_device = device
                else:
                    try:
                        audio.restart_input_stream(device)
                    except Exception as exc:
                        logger.warning(f"Could not switch the capture device: {exc}")

            if standby != state.mic_standby:
                state.mic_standby = standby
                logger.info(f"Microphone standby: {'on' if standby else 'off (on-demand)'}")
                try:
                    if standby:
                        audio.open_input_stream()
                    elif not audio.is_collecting:
                        audio.close_input_stream()
                except Exception as exc:
                    logger.warning(f"Could not apply the microphone standby change: {exc}")

    def _watch():
        last_mtime = _mtime()
        while state.main_loop_active:
            time.sleep(2.0)
            mtime = _mtime()
            if mtime is None or mtime == last_mtime:
                continue
            last_mtime = mtime
            try:
                _apply_changes()
            except Exception as exc:
                logger.warning(f"Could not apply the edited configuration: {exc}")

    threading.Thread(
        target=_watch, name="localvoice-config-watcher", daemon=True
    ).start()


def _hide_from_dock():
    """Register this process as a background app before AppKit is touched.

    The service runs from Homebrew's Python.app, whose Info.plist does not
    declare LSUIElement — so the first AppKit use (beeps, paste, the AX
    focus check) registers it as a Foreground app and a "Python" icon
    appears in the Dock for as long as the service lives. Creating the
    shared NSApplication here, with the accessory policy, makes every later
    AppKit consumer reuse it and keeps the process out of the Dock.
    """
    try:
        from AppKit import NSApplication, NSApplicationActivationPolicyAccessory

        NSApplication.sharedApplication().setActivationPolicy_(
            NSApplicationActivationPolicyAccessory
        )
    except Exception as exc:
        logger.debug(f"Could not set the accessory activation policy: {exc}")


def _has_permissions():
    from permissions import check_permissions

    try:
        return check_permissions()
    except SystemExit as exc:
        # The upstream permission flow exits with 1 after showing its
        # settings prompt; launchd must not retry a missing permission.
        if exc.code != 1:
            raise
        return False


def _configure_legacy_model(model_type_arg):
    import torch
    from models.factory import ModelFactory
    from models.registry import get_model_metadata

    state.model_type = ModelFactory.resolve_model_alias(model_type_arg)
    state.device = torch.device("mps") if torch.backends.mps.is_available() else torch.device("cpu")
    logger.debug(f"Using device: {state.device}")

    cached_models = find_cached_models()
    console.print("\n[bold]Model Configuration:[/bold]")
    if model_type_arg.lower() != state.model_type.lower():
        console.print(
            f"  Selected (alias): [cyan]{model_type_arg}[/cyan] -> Resolved: [cyan]{state.model_type}[/cyan]"
        )
    else:
        console.print(f"  Selected: [cyan]{state.model_type}[/cyan]")

    if cached_models:
        selected_meta = get_model_metadata(state.model_type)
        selected_repo_id = selected_meta.repo_id if selected_meta else state.model_type
        other_cached = sorted(list(cached_models - {selected_repo_id}))
        if selected_repo_id in cached_models:
            console.print("  Status: [green]Found in cache[/green]")
        else:
            console.print("  Status: [yellow]Not found in cache (will be downloaded)[/yellow]")

        if other_cached:
            console.print(f"  Other cached models available: {', '.join(other_cached)}")
    else:
        console.print("  [yellow]Cache status unknown (or cache empty/inaccessible)[/yellow]")


def _write_ready_file(filename):
    """Publish this process's PID by renaming a file in the same directory."""
    from pathlib import Path
    from tempfile import NamedTemporaryFile

    path = Path(filename)
    tmp_path = None
    try:
        with NamedTemporaryFile(mode="w", dir=path.parent, prefix=".ready-", delete=False) as tmp:
            tmp_path = Path(tmp.name)
            tmp.write(f"{os.getpid()}\n")
        tmp_path.replace(path)
        tmp_path = None
    finally:
        if tmp_path is not None:
            tmp_path.unlink(missing_ok=True)


def _hotkeys_ready(manager):
    """Wait for pynput's event tap, without hanging if the listener dies."""
    listeners = [
        listener
        for listener in (manager.key_listener, manager.hotkey_listener)
        if listener is not None
    ]
    deadline = time.monotonic() + 5.0

    def wait_for_listener(listener, ready):
        listener.wait()
        ready.set()

    for listener in listeners:
        ready = threading.Event()
        threading.Thread(target=wait_for_listener, args=(listener, ready), daemon=True).start()
        while listener.is_alive() and time.monotonic() < deadline:
            if ready.wait(timeout=0.05):
                break
        if not ready.is_set() or not listener.is_alive():
            return False
    return bool(listeners)


def _setup_managed_logging():
    from logging.handlers import RotatingFileHandler
    from pathlib import Path

    directory = os.environ.get("LOCALVOICE_STATE_DIR")
    if not directory:
        return
    try:
        log = RotatingFileHandler(Path(directory) / "service.log", maxBytes=512_000,
                                  backupCount=2, encoding="utf-8")
    except OSError as exc:
        logger.warning("Could not open the LocalVoice service log: %s", exc)
        return
    log.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    logging.basicConfig(level=logging.INFO, handlers=[log], force=True)


def run_app(args):
    """Run the managed service or the legacy Textual application."""
    from model_loader import ManagedModelUnavailable, get_model, resolve_managed_model

    model_id = os.environ.get("LOCALVOICE_MODEL_ID")
    managed = model_id is not None
    managed_model_path = None
    ready_file = os.environ.get("LOCALVOICE_READY_FILE")
    previous_sigterm = None

    state.startup_time = time.time()
    if not managed:
        setup_logging()

    saved_env_vars = save_environment_variables()

    try:
        if managed:
            def terminate(_signal, _frame):
                raise SystemExit(0)

            previous_sigterm = signal.signal(signal.SIGTERM, terminate)
        if not _acquire_single_instance_lock():
            logger.warning("Another LocalVoice service already holds the lock; exiting this one.")
            console.print("[bold yellow]Another LocalVoice service is already running. Exiting.[/bold yellow]")
            return 0

        state.DEBUG_MODE = args.debug
        if managed:
            _setup_managed_logging()
        else:
            setup_logging_for_mode(state.DEBUG_MODE)

        if managed:
            # Set this before importing the backend or anything that uses Hub
            # constants. The separately launched model library fetch is unaffected.
            os.environ["HF_HUB_OFFLINE"] = "1"
            try:
                managed_model_path = resolve_managed_model(model_id)
            except ManagedModelUnavailable as exc:
                logger.error("Managed model unavailable: %s", exc)
                return MANAGED_MODEL_UNAVAILABLE
            state.model_type = model_id
            logger.info("Verified managed model %s at %s", model_id, managed_model_path)
            if args.check_only:
                console.print("[green]Verified the installed model. Nothing was started.[/green]")
                return 0

        _hide_from_dock()
        if not managed:
            if not _has_permissions():
                logger.warning("Permission check failed.")
                # Missing permissions cannot be fixed by restarting the service.
                return 0
            _configure_legacy_model(args.model)

        if args.check_only:
            console.print("\n[bold cyan]--check-only specified. Exiting now.[/bold cyan]")
            return 0

        state.source_lang = args.source_lang
        state.target_lang = args.target_lang
        from utils import localvoice_config

        # The config file is the user's control surface; make sure it exists
        # (the first run folds the pre-1.2 preference files in). Language
        # preferences still apply to legacy installs, not to the managed app.
        try:
            localvoice_config.ensure_config_file()
        except OSError as exc:
            logger.warning(f"Could not create the configuration file: {exc}")
        state.source_lang = localvoice_config.model_language(model_id) if managed else localvoice_config.language()
        state.target_lang = state.source_lang

        # History configuration
        # Never add transcripts to an independent ctrlSPEAK history database.
        state.history_enabled = not args.no_history and (not managed or bool(args.history_db))
        if args.history_db:
            from pathlib import Path
            state.history_db_path = Path(args.history_db)

        app_state = None
        if not managed:
            if is_first_run():
                mark_first_run_complete()
            set_preferred_model(state.model_type)
            from ui import AppState

            app_state = AppState()
            app_state.selected_model = args.model  # Store the alias, not the full name
        state.app_state_ref = app_state

        restore_environment_variables(saved_env_vars)

        try:
            state.stt_model = get_model(managed_model_path=managed_model_path)
        except Exception as e:
            console.print(f"[bold red]Failed to load STT model: {e}[/bold red]")
            return 1

        from transcription import transcription_worker

        state.transcription_worker_thread = threading.Thread(
            target=transcription_worker,
            args=(state.stt_model, state.transcription_queue, state.transcribed_chunks, state.source_lang, state.target_lang),
            daemon=True,
            name="TranscriptionWorker",
        )
        state.transcription_worker_thread.start()

        # MLX streams are thread-local, so deferred models finish loading in
        # the transcription worker. Avoid starting PortAudio concurrently;
        # doing both GPU/audio initialization at once can abort on macOS.
        if not state.model_loaded:
            logger.info("Waiting for the transcription worker to finish MLX initialization...")
            # Only legacy startup needs to allow time for a model download.
            model_ready_deadline = time.monotonic() + (120.0 if managed else 1800.0)
            while (
                not state.model_loaded
                and state.transcription_worker_thread.is_alive()
                and time.monotonic() < model_ready_deadline
            ):
                time.sleep(0.05)

            if not state.model_loaded:
                logger.error("MLX model initialization did not complete successfully.")
                if managed and not state.transcription_worker_thread.is_alive():
                    return MANAGED_MODEL_UNAVAILABLE
                return 1

        # The upstream permission probe opens an input stream. In managed
        # mode, do not probe it until the verified local weights have loaded.
        # The native launcher passively checks the actual app identity. Do not
        # open the microphone or show upstream permission prompts a second
        # time; hotkey startup and recording still need real OS access.
        if managed and os.environ.get("LOCALVOICE_PERMISSIONS_PREFLIGHT") != "1" and not _has_permissions():
            logger.warning("Permission check failed.")
            return 0

        from utils.keyboard_shortcuts import KeyboardShortcutManager
        from utils.audio import AudioManager, resolve_input_device
        from hotkeys import (
            on_activate,
            is_recording,
            cancel_recording,
            finish_recording,
            open_config,
        )

        state.audio_manager = AudioManager(
            transcription_queue=state.transcription_queue,
            debug_mode=state.DEBUG_MODE,
            app_state=app_state,
        )
        # Pin the configured device rather than silently changing when a
        # Bluetooth headset becomes the system default.
        state.audio_manager.input_device = resolve_input_device(
            localvoice_config.effective("microphone")
        )
        logger.info(
            f"Capture device: {state.audio_manager.input_device or 'system default'}"
        )

        state.keyboard_manager = KeyboardShortcutManager()
        state.keyboard_manager.register_triple_ctrl_tap(on_activate)
        state.keyboard_manager.register_recording_keys(
            is_recording=is_recording,
            on_cancel=cancel_recording,
            on_finish=finish_recording,
            on_open_config=None if managed else open_config,
        )
        state.keyboard_manager.register_shortcut('<alt>+<esc>', exit_app)

        try:
            # Standby opens the stream now; on-demand leaves it to hotkeys.py.
            state.mic_standby = _load_mic_standby()
            logger.info(f"Microphone standby: {'on' if state.mic_standby else 'off (on-demand)'}")
            if state.mic_standby:
                state.audio_manager.open_input_stream()

            if not state.keyboard_manager.start_listening():
                logger.error("Could not start the hotkey listener.")
                return 1

            if ready_file and not _hotkeys_ready(state.keyboard_manager):
                logger.error("Hotkey listener did not become ready.")
                return 1

            _start_config_watcher()
            if ready_file:
                if not state.main_loop_active:
                    return 0
                if not state.transcription_worker_thread.is_alive():
                    logger.error("Transcription worker exited before readiness.")
                    return 1
                try:
                    _write_ready_file(ready_file)
                except OSError as exc:
                    logger.error("Could not publish readiness at %s: %s", ready_file, exc)
                    return 1

            hotkey_hint = state.keyboard_manager.hotkey_description
            console.print(
                Panel.fit(
                    f"[bold cyan]LocalVoice[/bold cyan] - Ready to transcribe.\n"
                    f"[bold]{hotkey_hint}[/bold] to start/stop recording.\n"
                    f"While recording: [bold]Enter[/bold] inserts, [bold]Esc[/bold] cancels.",
                    title="Welcome",
                    border_style="blue",
                )
            )

            # Under the LaunchAgent there is no terminal: stdout and stderr are
            # the log files from the plist, and TERM is set, so Textual believes
            # it can draw. It then repaints full-screen frames into the log
            # forever — a pinned CPU core and ~5 GB of escape sequences a day.
            # The UI is a convenience for running ctrlSPEAK by hand; the service
            # does not need it. Hotkeys, the pill and the transcription worker
            # were all started above and run in their own threads, so headless
            # we only have to keep the process alive until exit_app() flips
            # main_loop_active.
            # Managed model selection belongs to the launcher, not Textual,
            # whose selector can swap to legacy Hub models.
            if not managed and sys.stdout.isatty():
                from ui import CtrlSpeakApp

                app_state.loaded_model = args.model
                if state.audio_manager.input_device is None:
                    import sounddevice as sd

                    app_state.loaded_device = sd.default.device[0] if sd.default.device else None
                else:
                    app_state.loaded_device = state.audio_manager.input_device
                logger.info("Starting Textual UI...")

                # Create and run Textual app
                app = CtrlSpeakApp(
                    app_state=app_state,
                    audio_manager=state.audio_manager,
                    model_type=args.model  # Pass the alias, not the resolved full name
                )

                # Run the app (this blocks until app exits)
                app.run()

                logger.info("Textual UI exited, cleaning up...")
            else:
                logger.info("Running headless without the Textual UI.")
                while state.main_loop_active:
                    time.sleep(0.2)
                logger.info("Headless loop exited, cleaning up...")
        finally:
            state.audio_manager.close_input_stream()

    except KeyboardInterrupt:
        console.print("\n[bold yellow]Ctrl+C detected. Shutting down...[/bold yellow]")
        exit_app()
    finally:
        logger.info("Executing main finally block for cleanup...")
        if previous_sigterm is not None:
            # Do not let a second signal interrupt disposal of the model helper.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)

        if state.keyboard_manager is not None:
            try:
                state.keyboard_manager.stop_listening()
            except Exception as e_kb:
                logger.error(f"Error stopping keyboard manager in finally: {e_kb}")

        if state.audio_manager:
            if state.audio_manager.is_collecting:
                try:
                    state.audio_manager.stop_recording()
                except Exception as e_aud_stop:
                    logger.error(f"Error stopping recording in finally: {e_aud_stop}")
            try:
                state.audio_manager.set_is_running(False)
            except Exception as e_aud_run:
                logger.error(f"Error setting audio manager not running in finally: {e_aud_run}")

        from models.parakeet_coreml import ParakeetCoreMLModel
        if isinstance(state.stt_model, ParakeetCoreMLModel):
            state.stt_model.close()

        worker = state.transcription_worker_thread
        if worker and worker.is_alive():
            state.transcription_queue.put(None)
            worker.join(timeout=3.0)
            if worker.is_alive():
                logger.warning("Finally: Transcription worker thread did NOT join after timeout.")

        if 'saved_env_vars' in locals():
            restore_environment_variables(saved_env_vars)
        if previous_sigterm is not None:
            signal.signal(signal.SIGTERM, previous_sigterm)

        console.print("[bold green]ctrlspeak stopped.[/bold green]")


def exit_app():
    """Initiates the application shutdown sequence."""
    logger.info("Shutdown requested.")
    console.print("[bold yellow]Shutting down ctrlspeak...")

    if state.audio_manager and state.audio_manager.is_collecting:
        logger.info("Stopping active recording during exit...")
        state.audio_manager.stop_recording()

    logger.info("Signaling transcription worker to exit...")
    state.transcription_queue.put(None)

    if state.keyboard_manager is not None:
        logger.info("Stopping keyboard listener...")
        try:
            state.keyboard_manager.stop_listening()
            logger.info("Keyboard listener stop signaled.")
        except Exception as e_stop_kb:
            logger.error(f"Error stopping keyboard listener in exit_app: {e_stop_kb}")

    logger.info("Signaling main loop to exit...")
    state.main_loop_active = False

    logger.info("Exit_app finished signaling components.")


def main():
    """Main application entry point"""
    args = parse_args_only()

    if args.check_compatibility:
        from models.compatibility import CompatibilityChecker
        CompatibilityChecker.print_report()
        sys.exit(0)

    if args.list_models:
        from models.registry import MODEL_REGISTRY
        console = Console()
        console.print("\n[bold]Supported Models:[/bold]")

        # Check what dependencies are available
        nemo_available = False
        transformers_available = False
        mlx_available = False

        try:
            import nemo.collections.asr as nemo_asr
            nemo_available = True
        except ImportError:
            pass

        try:
            import transformers
            transformers_available = True
        except ImportError:
            pass

        try:
            import mlx
            mlx_available = True
        except ImportError:
            pass

        for alias, meta in MODEL_REGISTRY.items():
            status = ""
            note = ""

            if "mlx" in meta.requires:
                if mlx_available:
                    status = " [green]✓ Available[/green]"
                    note = " (Apple Silicon / MLX)"
                else:
                    status = " [red]✗ Requires MLX[/red]"
                    note = " (Apple Silicon / MLX - install MLX dependencies)"
            elif "nemo" in meta.requires:
                if nemo_available:
                    status = " [green]✓ Available[/green]"
                else:
                    status = " [red]✗ Requires NVIDIA support[/red]"
                    note = " (install with: brew reinstall ctrlspeak --with-nvidia)"
            elif "transformers" in meta.requires:
                if transformers_available:
                    status = " [green]✓ Available[/green]"
                else:
                    status = " [red]✗ Requires transformers[/red]"
                    note = " (install with: uv pip install -r requirements-whisper.txt)"
            elif meta.requires == "cohere-mlx":
                if mlx_available:
                    status = " [green]✓ Available[/green]"
                    note = " (Apple Silicon / MLX, ~4.1GB download)"
                else:
                    status = " [red]✗ Requires MLX[/red]"
                    note = " (install with: uv pip install -r requirements-cohere-mlx.txt)"
            elif meta.requires == "cohere":
                if transformers_available:
                    status = " [green]✓ Available[/green]"
                    note = " (CPU-first, ~4.1GB download, multilingual only)"
                else:
                    status = " [red]✗ Requires transformers[/red]"
                    note = " (install with: uv pip install -r requirements-cohere.txt)"
            else:
                status = " [green]✓ Available[/green]"

            console.print(f"  - [cyan]{alias}[/cyan]: {meta.repo_id}{note}{status}")

        # Show installation recommendations
        if not nemo_available:
            console.print(f"\n[yellow]💡 Tip:[/yellow] Install NVIDIA model support with:")
            console.print(f"  [cyan]brew reinstall ctrlspeak --with-nvidia[/cyan]")

        if not transformers_available:
            console.print(f"\n[yellow]💡 Tip:[/yellow] Install Whisper model support with:")
            console.print(f"  [cyan]uv pip install -r requirements-whisper.txt[/cyan]")

        sys.exit(0)

    # Run the Textual UI application
    return run_app(args)


if __name__ == "__main__":
    sys.exit(main())
