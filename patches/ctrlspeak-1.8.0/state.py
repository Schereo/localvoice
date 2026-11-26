
import queue
from typing import NamedTuple
from rich.console import Console

# Global variables
startup_time = 0
console = Console()
print = console.print

DEBUG_MODE = False

# Model identifiers - source of truth for all model references in the codebase
MLX_PARAKEET_V3 = "mlx-community/parakeet-tdt-0.6b-v3"
MLX_PARAKEET_V2 = "mlx-community/parakeet-tdt-0.6b-v2"
MLX_WHISPER_LARGE_V3_TURBO = "mlx-community/whisper-large-v3-turbo"
NVIDIA_PARAKEET_V3 = "nvidia/parakeet-tdt-0.6b-v3"
NVIDIA_PARAKEET_V2 = "nvidia/parakeet-tdt-0.6b-v2"
NVIDIA_CANARY_1B_FLASH = "nvidia/canary-1b-flash"
NVIDIA_CANARY_180M = "nvidia/canary-180m-flash"
NVIDIA_CANARY_V2 = "nvidia/canary-1b-v2"
NVIDIA_NEMOTRON_STREAMING = "nvidia/nemotron-speech-streaming-en-0.6b"
OPENAI_WHISPER_V3 = "openai/whisper-large-v3"
COHERE_TRANSCRIBE = "CohereLabs/cohere-transcribe-03-2026"

# Set of all known/supported models
KNOWN_MODELS = {
    MLX_PARAKEET_V3,
    MLX_PARAKEET_V2,
    MLX_WHISPER_LARGE_V3_TURBO,
    NVIDIA_PARAKEET_V3,
    NVIDIA_PARAKEET_V2,
    NVIDIA_CANARY_1B_FLASH,
    NVIDIA_CANARY_180M,
    NVIDIA_CANARY_V2,
    NVIDIA_NEMOTRON_STREAMING,
    OPENAI_WHISPER_V3,
    COHERE_TRANSCRIBE,
}

audio_manager = None
stt_model = None
model_type = "parakeet"
model_loaded = False

transcribed_chunks = []
failed_recording_id = None
transcription_queue = queue.Queue()
transcription_worker_thread = None
main_loop_active = True


class TranscriptionJob(NamedTuple):
    recording_id: int
    kind: str = "batch"
    audio: object = None
    preview_segment: int = -1
    is_final: bool = False
    backend: object = None
    # For a preview of the whole open segment: how many capture chunks the
    # snapshot held (-1 when it held only the segment's tail).
    preview_chunks: int = -1

keyboard_manager = None

device = None

source_lang = "en"
target_lang = "en"

# Whether the microphone stream stays open while idle. Off by default: the
# always-lit macOS mic indicator reads as "this thing listens to everything",
# even though idle audio is discarded. Standby buys instant starts and the
# pre-tap part of the onset roll for those who opt in.
mic_standby = False

# Whether this recording session shows the live transcript in the pill.
# Read from the config once per session start, so a mid-recording edit of
# "live-preview" cannot half-apply.
live_preview_active = False

# The newest preview that covered a whole open segment, as (recording_id,
# segment, chunks, text). If nothing but quiet audio followed it, it already
# is that segment's transcript, and stop needs no decode of its own.
last_preview = None

# Recording timing
recording_start_time = None

# History configuration
history_enabled = True
history_db_path = None
