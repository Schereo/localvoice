"""Run the verified Silero VAD v6.2.1 asset in pure NumPy without PyTorch.

The pinned upstream ``silero_vad.jit`` is a TorchScript ZIP archive whose
16 kHz model consists of 15 raw little-endian float32 weight/buffer tensors
(STFT basis, four Conv1d encoder blocks, an LSTMCell, and a 1x1 output head).
After verifying the release SHA-256 digest of the exact bytes read from disk,
this module reads those 15 tensors directly from the verified ZIP bytes and
executes the forward pass in NumPy — eliminating the ~630 MB PyTorch runtime
dependency, ~600 ms import cost, and ~200 MB of process memory.
"""

import hashlib
import io
import os
from pathlib import Path
import zipfile


# Silero VAD v6.2.1, src/silero_vad/data/silero_vad.jit (MIT).
SILERO_SHA256 = "e1122837f4154c511485fe0b9c64455f7b929c96fbb8d79fbdb336383ebd3720"
SILERO_BYTES = 2_272_526

_ARCHIVE_PREFIX = "VADr_v6_10_25_noths_re/data/"
_TENSOR_SPECS = (
    ("stft_basis", "2", (258, 256)),
    ("enc0_w", "3", (128, 129, 3)),
    ("enc0_b", "4", (128,)),
    ("enc1_w", "5", (64, 128, 3)),
    ("enc1_b", "6", (64,)),
    ("enc2_w", "7", (64, 64, 3)),
    ("enc2_b", "8", (64,)),
    ("enc3_w", "9", (128, 64, 3)),
    ("enc3_b", "10", (128,)),
    ("rnn_w_ih", "11", (512, 128)),
    ("rnn_w_hh", "12", (512, 128)),
    ("rnn_b_ih", "13", (512,)),
    ("rnn_b_hh", "14", (512,)),
    ("dec_w", "15", (128,)),
    ("dec_b", "16", (1,)),
)


def _sigmoid(x, np):
    return 1.0 / (1.0 + np.exp(-x))


class SileroVAD:
    """Pure-NumPy implementation of Silero VAD v6.2.1 (16 kHz, 512-sample blocks)."""

    SAMPLE_RATE = 16_000
    CHUNK_SAMPLES = 512
    CONTEXT_SAMPLES = 64

    def __init__(self, tensors):
        import numpy as np

        self._np = np
        # Transpose weights once into contiguous BLAS-friendly layouts for time-first ops.
        self._stft_basis_t = np.ascontiguousarray(tensors["stft_basis"].T)  # (256, 258)
        # Conv1d weights are stored as (C_out, C_in, K=3); reorder to (K * C_in, C_out)
        # so each padded (T, C_in) window slice maps directly to a single GEMM.
        self._enc0_w = np.ascontiguousarray(tensors["enc0_w"].transpose(2, 1, 0).reshape(3 * 129, 128))
        self._enc0_b = np.ascontiguousarray(tensors["enc0_b"])
        self._enc1_w = np.ascontiguousarray(tensors["enc1_w"].transpose(2, 1, 0).reshape(3 * 128, 64))
        self._enc1_b = np.ascontiguousarray(tensors["enc1_b"])
        self._enc2_w = np.ascontiguousarray(tensors["enc2_w"].transpose(2, 1, 0).reshape(3 * 64, 64))
        self._enc2_b = np.ascontiguousarray(tensors["enc2_b"])
        # Encoder block 3 sees T=1 with pad=1, so only the center kernel slice (k=1) is non-zero.
        self._enc3_w_center = np.ascontiguousarray(tensors["enc3_w"][:, :, 1].T)  # (64, 128)
        self._enc3_b = np.ascontiguousarray(tensors["enc3_b"])

        self._rnn_w_ih_t = np.ascontiguousarray(tensors["rnn_w_ih"].T)  # (128, 512)
        self._rnn_w_hh_t = np.ascontiguousarray(tensors["rnn_w_hh"].T)  # (128, 512)
        self._rnn_b = np.ascontiguousarray(tensors["rnn_b_ih"] + tensors["rnn_b_hh"])  # (512,)

        self._dec_w = np.ascontiguousarray(tensors["dec_w"])  # (128,)
        self._dec_b = float(tensors["dec_b"][0])

        # Preallocated scratch buffers to avoid per-chunk heap allocations.
        self._x_pad = np.empty(self.CONTEXT_SAMPLES + self.CHUNK_SAMPLES + 64, dtype=np.float32)
        self._enc0_pad = np.zeros((6, 129), dtype=np.float32)
        self._enc1_pad = np.zeros((6, 128), dtype=np.float32)
        self._enc2_pad = np.zeros((3, 64), dtype=np.float32)

        self._context = np.zeros(self.CONTEXT_SAMPLES, dtype=np.float32)
        self._h = np.zeros(128, dtype=np.float32)
        self._c = np.zeros(128, dtype=np.float32)

    def reset_states(self):
        self._context.fill(0.0)
        self._h.fill(0.0)
        self._c.fill(0.0)

    def __call__(self, audio_chunk, sample_rate=16_000) -> float:
        np = self._np
        if sample_rate != self.SAMPLE_RATE:
            raise ValueError(f"SileroVAD only supports {self.SAMPLE_RATE} Hz audio.")
        x = np.asarray(audio_chunk, dtype=np.float32)
        if x.ndim != 1 or x.shape[0] != self.CHUNK_SAMPLES:
            raise ValueError(f"SileroVAD requires {self.CHUNK_SAMPLES} mono samples.")

        # Concatenate 64-sample context + 512 samples + 64-sample right reflection pad -> 640.
        buf = self._x_pad
        buf[:64] = self._context
        buf[64:576] = x
        buf[576:] = buf[574:510:-1]
        self._context[:] = buf[512:576]

        # STFT: 4 frames of length 256 at hop 128 -> magnitude (4, 129).
        frames = np.lib.stride_tricks.as_strided(
            buf, shape=(4, 256), strides=(128 * buf.strides[0], buf.strides[0])
        )
        spec = frames @ self._stft_basis_t  # (4, 258)
        re = spec[:, :129]
        im = spec[:, 129:]
        mag = np.sqrt(re * re + im * im)

        # Encoder block 0: Conv1d(129 -> 128, k=3, s=1, p=1) + ReLU -> (4, 128).
        p0 = self._enc0_pad
        p0[1:5] = mag
        w0 = np.lib.stride_tricks.as_strided(
            p0, shape=(4, 3 * 129), strides=(p0.strides[0], p0.strides[1])
        )
        x0 = w0 @ self._enc0_w + self._enc0_b
        np.maximum(x0, 0.0, out=x0)

        # Encoder block 1: Conv1d(128 -> 64, k=3, s=2, p=1) + ReLU -> (2, 64).
        p1 = self._enc1_pad
        p1[1:5] = x0
        w1 = np.lib.stride_tricks.as_strided(
            p1, shape=(2, 3 * 128), strides=(2 * p1.strides[0], p1.strides[1])
        )
        x1 = w1 @ self._enc1_w + self._enc1_b
        np.maximum(x1, 0.0, out=x1)

        # Encoder block 2: Conv1d(64 -> 64, k=3, s=2, p=1) + ReLU -> (1, 64).
        p2 = self._enc2_pad
        p2[1:3] = x1
        x2 = p2.reshape(192) @ self._enc2_w + self._enc2_b
        np.maximum(x2, 0.0, out=x2)

        # Encoder block 3: Conv1d(64 -> 128, k=3, s=1, p=1) on T=1 + ReLU -> (128,).
        x3 = x2 @ self._enc3_w_center + self._enc3_b
        np.maximum(x3, 0.0, out=x3)

        # Decoder LSTMCell (128 -> 128).
        gates = x3 @ self._rnn_w_ih_t + self._h @ self._rnn_w_hh_t + self._rnn_b
        i = _sigmoid(gates[:128], np)
        f = _sigmoid(gates[128:256], np)
        g = np.tanh(gates[256:384])
        o = _sigmoid(gates[384:], np)
        self._c = f * self._c + i * g
        self._h = o * np.tanh(self._c)

        # Output head: ReLU -> 1x1 Conv -> Sigmoid.
        out = np.maximum(self._h, 0.0)
        logit = float(np.dot(out, self._dec_w)) + self._dec_b
        return float(1.0 / (1.0 + np.exp(-logit)))


def _legacy_torch_hub_dir():
    torch_home = os.environ.get("TORCH_HOME")
    if torch_home:
        return Path(torch_home).expanduser() / "hub"
    xdg_cache = os.environ.get("XDG_CACHE_HOME")
    if xdg_cache:
        return Path(xdg_cache).expanduser() / "torch" / "hub"
    return Path.home() / ".cache" / "torch" / "hub"


def _extract_weights(data: bytes) -> dict:
    import numpy as np

    tensors = {}
    with zipfile.ZipFile(io.BytesIO(data), "r") as archive:
        for name, entry, shape in _TENSOR_SPECS:
            raw = archive.read(_ARCHIVE_PREFIX + entry)
            array = np.frombuffer(raw, dtype="<f4")
            expected = 1
            for dim in shape:
                expected *= dim
            if array.size != expected:
                raise ValueError(f"Unexpected Silero VAD tensor size for {name}.")
            tensors[name] = array.reshape(shape).astype(np.float32, copy=True)
    return tensors


def load_local_vad(_torch=None):
    configured = os.environ.get("LOCALVOICE_VAD_PATH")
    if configured:
        asset = Path(configured)
    else:
        # Migration for existing installations. Read the verified weights
        # only; never execute hubconf.py or ask GitHub which branch is current.
        asset = _legacy_torch_hub_dir() / "snakers4_silero-vad_master/src/silero_vad/data/silero_vad.jit"

    with asset.open("rb") as handle:
        # Hash and deserialize the very same bytes (the legacy path is mutable).
        data = handle.read(SILERO_BYTES + 1)
    if len(data) != SILERO_BYTES or hashlib.sha256(data).hexdigest() != SILERO_SHA256:
        raise ValueError("The local Silero VAD asset does not match its release digest.")

    return SileroVAD(_extract_weights(data))
