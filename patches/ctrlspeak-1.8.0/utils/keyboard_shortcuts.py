import threading
from pynput import keyboard
import subprocess
import sys
import time
from rich.console import Console
from rich.panel import Panel
from utils.permission_manager import check_keyboard_permissions

# The activation hotkey is a repeated tap on one modifier key. Which modifier
# and how many taps comes from the LocalVoice config file, e.g. "hotkey =
# cmd,2" for a double-tap on Command. Modifiers only: a plain letter would
# fire while typing.
from utils import localvoice_config

_MODIFIER_KEYS = {
    "ctrl": {keyboard.Key.ctrl, keyboard.Key.ctrl_l, keyboard.Key.ctrl_r},
    "cmd": {keyboard.Key.cmd, keyboard.Key.cmd_l, keyboard.Key.cmd_r},
    "alt": {keyboard.Key.alt, keyboard.Key.alt_l, keyboard.Key.alt_r},
    "shift": {keyboard.Key.shift, keyboard.Key.shift_l, keyboard.Key.shift_r},
}

# macOS virtual key code for the comma key (kVK_ANSI_Comma), so Cmd+, is
# recognised even when the event carries no character.
_COMMA_VIRTUAL_KEY = 43


def load_hotkey_config():
    """Read (modifier, taps) from the config, falling back to ctrl,3."""
    return localvoice_config.hotkey()


def _is_comma(key):
    return (
        getattr(key, "char", None) == ","
        or getattr(key, "vk", None) == _COMMA_VIRTUAL_KEY
    )


class KeyboardShortcutManager:
    """
    A class to manage keyboard shortcuts and hotkeys
    """
    def __init__(self):
        self.hotkey_listener = None
        self.shortcuts = {}
        self.is_running = True
        self.console = Console()

        # For repeated-tap detection on the configured modifier
        self.tap_modifier, self.tap_count_required = load_hotkey_config()
        self.last_key_time = 0
        self.ctrl_tap_count = 0
        self.ctrl_tap_timeout = 0.5  # seconds between taps
        self.triple_tap_callback = None
        self.key_listener = None

        # Esc/Enter/Cmd+, handling while a recording session is active. The
        # querying callable decides "active"; the listener stays passive
        # otherwise.
        self.recording_active_check = None
        self.recording_cancel_callback = None
        self.recording_finish_callback = None
        self.recording_open_config_callback = None

        # Alt+Esc exit and Cmd+, tracking, folded into the single listener
        # (see register_shortcut for why there is only one).
        self._alt_down = False
        self._cmd_down = False
        self.exit_callback = None

    @property
    def hotkey_description(self):
        """Human-readable activation gesture, e.g. "double-tap Cmd"."""
        names = {2: "double", 3: "triple", 4: "quadruple"}
        labels = {"ctrl": "Ctrl", "cmd": "Cmd", "alt": "Option", "shift": "Shift"}
        return f"{names[self.tap_count_required]}-tap {labels[self.tap_modifier]}"

    def register_recording_keys(self, is_recording, on_cancel, on_finish, on_open_config=None):
        """While is_recording() is true: Esc cancels, Enter finishes, and
        Cmd+, opens the LocalVoice configuration file."""
        self.recording_active_check = is_recording
        self.recording_cancel_callback = on_cancel
        self.recording_finish_callback = on_finish
        self.recording_open_config_callback = on_open_config
    
    def check_permissions(self):
        """Check and request necessary accessibility permissions for keyboard control"""
        return check_keyboard_permissions(verbose=True)
    
    def register_shortcut(self, key_combination, callback):
        """
        Register a keyboard shortcut
        
        Args:
            key_combination (str): Key combination in pynput format (e.g., '<alt>+`')
            callback (function): Function to call when shortcut is pressed
        """
        # The exit shortcut is handled inside the one key listener instead of
        # a second GlobalHotKeys listener. Two pynput listeners initialise
        # macOS Text Input Services concurrently from their own threads,
        # which modern macOS answers with abort() — the service then dies in
        # a crash loop right after startup.
        if key_combination == '<alt>+<esc>':
            self.exit_callback = callback
            return

        self.shortcuts[key_combination] = callback
    
    def register_triple_ctrl_tap(self, callback):
        """
        Register a callback for when Ctrl is tapped three times in succession
        
        Args:
            callback (function): Function to call when triple-tap is detected
        """
        self.triple_tap_callback = callback
    
    def _on_key_press(self, key):
        """
        Internal handler for key press events: repeated-tap detection on the
        configured modifier, plus Esc/Enter while a recording is active.
        """
        recording = False
        if self.recording_active_check is not None:
            try:
                recording = bool(self.recording_active_check())
            except Exception:
                recording = False

        if key in (keyboard.Key.alt, keyboard.Key.alt_l, keyboard.Key.alt_r):
            self._alt_down = True
        if key in _MODIFIER_KEYS["cmd"]:
            self._cmd_down = True

        if key == keyboard.Key.esc and self._alt_down and self.exit_callback:
            self.ctrl_tap_count = 0
            return self.exit_callback()

        # pynput cannot swallow events, so Esc, Enter and Cmd+, also reach
        # the frontmost app; they are only interpreted here during a recording.
        if recording:
            if key == keyboard.Key.esc and self.recording_cancel_callback:
                self.ctrl_tap_count = 0
                return self.recording_cancel_callback()
            if key == keyboard.Key.enter and self.recording_finish_callback:
                self.ctrl_tap_count = 0
                return self.recording_finish_callback()
            if self._cmd_down and self.recording_open_config_callback and _is_comma(key):
                self.ctrl_tap_count = 0
                return self.recording_open_config_callback()

        if key in _MODIFIER_KEYS[self.tap_modifier]:
            current_time = time.time()

            # If it's been too long since the last tap, reset the counter
            if current_time - self.last_key_time > self.ctrl_tap_timeout:
                self.ctrl_tap_count = 1
            else:
                self.ctrl_tap_count += 1

            self.last_key_time = current_time

            # Enough taps in a row: trigger the callback
            if self.ctrl_tap_count == self.tap_count_required and self.triple_tap_callback:
                self.ctrl_tap_count = 0  # Reset counter
                return self.triple_tap_callback()
        else:
            # Any other key voids the sequence: Cmd+C quickly followed by
            # Cmd+V is two modifier presses, not two taps. Without this,
            # short tap counts on common modifiers misfire constantly.
            self.ctrl_tap_count = 0

        return True  # Continue listening
    
    def _on_key_release(self, key):
        """
        Internal handler for key release events
        """
        if key in (keyboard.Key.alt, keyboard.Key.alt_l, keyboard.Key.alt_r):
            self._alt_down = False
        if key in _MODIFIER_KEYS["cmd"]:
            self._cmd_down = False
        return True
    
    def start_listening(self):
        """Start listening for registered shortcuts and triple-tap"""
        # Start the regular hotkey listener if shortcuts are registered
        if self.shortcuts:
            self.hotkey_listener = keyboard.GlobalHotKeys(self.shortcuts)
            self.hotkey_listener.start()
        
        # Start the key listener for triple-tap detection
        if self.triple_tap_callback:
            self.key_listener = keyboard.Listener(
                on_press=self._on_key_press,
                on_release=self._on_key_release
            )
            self.key_listener.start()
        
        return True
    
    def stop_listening(self):
        """Stop listening for shortcuts"""
        if self.hotkey_listener:
            self.hotkey_listener.stop()
        
        if self.key_listener:
            self.key_listener.stop()
            
        self.is_running = False
    
    def join(self):
        """Join the hotkey listener thread"""
        if self.hotkey_listener:
            self.hotkey_listener.join()
        
        if self.key_listener:
            self.key_listener.join()

def check_keyboard_monitoring_permissions():
    """
    Standalone function to check if the application has keyboard monitoring permissions.
    
    Returns:
        bool: True if permissions are granted, False otherwise
    """
    console = Console()
    console.print("[bold]Checking keyboard monitoring permissions...[/bold]")
    
    # Multiple tests to verify permissions
    tests_passed = 0
    tests_total = 3
    
    # Test 1: Basic listener creation
    try:
        console.print("Test 1: Creating keyboard listener...")
        test_listener = keyboard.Listener(on_press=lambda k: None)
        test_listener.start()
        time.sleep(0.5)  # Give it a moment to fail if it's going to
        
        if test_listener.is_alive():
            tests_passed += 1
            console.print("[green]✓[/green] Keyboard listener created successfully")
        else:
            console.print("[bold red]✗[/bold red] Keyboard listener creation failed")
        
        test_listener.stop()
    except Exception as e:
        console.print(f"[bold red]✗[/bold red] Error creating keyboard listener: {e}")
        _show_permission_request_panel(console)
        return False
    
    # Test 2: Try to programmatically generate keyboard events
    try:
        console.print("Test 2: Testing keyboard event simulation...")
        
        # Create a test event to track if keyboard events are received
        event_received = threading.Event()
        
        def on_press_test(key):
            event_received.set()
            return False  # Stop listener
        
        # Create a listener that will respond to generated events
        test_listener = keyboard.Listener(on_press=on_press_test)
        test_listener.start()
        
        # Try to create a keyboard controller and generate an event
        try:
            controller = keyboard.Controller()
            # Press a harmless key
            controller.press(keyboard.Key.shift)
            controller.release(keyboard.Key.shift)
            
            # Wait for the event to be received
            if event_received.wait(timeout=1.0):
                tests_passed += 1
                console.print("[green]✓[/green] Keyboard event simulation successful")
            else:
                console.print("[yellow]⚠[/yellow] Keyboard event simulation failed")
        except Exception as e:
            console.print(f"[yellow]⚠[/yellow] Keyboard controller error: {e}")
        finally:
            if test_listener.is_alive():
                test_listener.stop()
    except Exception as e:
        console.print(f"[yellow]⚠[/yellow] Keyboard event test error: {e}")
    
    # Test 3: Check permissions on macOS specifically
    if sys.platform == "darwin":
        console.print("Test 3: Checking macOS accessibility permissions...")
        try:
            # Check if the app is in the list of apps with accessibility access
            # This requires sudo, so it might time out if run as normal user
            cmd = [
                "sudo", "sqlite3", 
                "/Library/Application Support/com.apple.TCC/TCC.db", 
                "SELECT allowed FROM access WHERE service='kTCCServiceAccessibility' AND client=?",
                sys.executable
            ]
            
            proc = subprocess.run(
                cmd, 
                capture_output=True, 
                text=True, 
                timeout=1  # Short timeout in case it waits for password
            )
            
            if proc.returncode == 0 and proc.stdout.strip() == "1":
                tests_passed += 1
                console.print("[green]✓[/green] macOS TCC database confirms permissions")
            elif proc.returncode == 0 and proc.stdout.strip() == "0":
                console.print("[bold red]✗[/bold red] macOS TCC database shows permission denied")
            else:
                console.print("[yellow]⚠[/yellow] Unable to check macOS TCC database (try running with sudo)")
                
                # If we couldn't check the database, we need an alternative test
                console.print("Running alternative test...")
                tests_passed += 0.5  # Half credit for passing the basic test earlier
        except (subprocess.SubprocessError, FileNotFoundError):
            console.print("[yellow]⚠[/yellow] Unable to query macOS permission database")
            tests_passed += 0.5  # Half credit for passing the basic test earlier
    else:
        # Non-macOS platform, assume the basic test is sufficient
        tests_passed += 1
    
    # Calculate permission confidence and make decision
    permission_confidence = tests_passed / tests_total
    
    if permission_confidence >= 0.7:  # At least 2/3 tests passing
        console.print("[bold green]✓ Keyboard monitoring permissions are granted.[/bold green]")
        return True
    elif permission_confidence >= 0.3:  # At least 1/3 tests passing
        console.print("[bold yellow]⚠ Keyboard permissions partially verified.[/bold yellow]")
        console.print("The application may have limited keyboard monitoring capabilities.")
        _show_permission_request_panel(console)
        # Continue anyway but warn user
        return True
    else:
        console.print("[bold red]✗ Keyboard monitoring permissions are not granted.[/bold red]")
        _show_permission_request_panel(console)
        return False

def _show_permission_request_panel(console):
    """Helper function to show the permission request panel"""
    console.print(Panel.fit(
        "[bold red]Keyboard monitoring permissions required[/bold red]\n\n"
        "ctrlSPEAK needs Accessibility permissions to detect keyboard shortcuts.\n"
        "Without this permission, the app cannot detect when you triple-tap Ctrl.\n\n"
        "[yellow]Opening System Settings → Privacy & Security → Accessibility...[/yellow]\n"
        "Please add and enable this application in the list.",
        title="Permission Required",
        border_style="red"
    ))
    
    # Open System Settings to the right place
    subprocess.run(["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
    
    console.print("\n[bold]After granting permission:[/bold]")
    console.print("1. Make sure the app is checked in the list")
    console.print("2. You may need to restart the application")
    console.print("3. If using from a terminal, try running with 'sudo'") 