"""Open the reviewed Silero TorchScript asset without running a Hub checkout."""

import hashlib
import io
import os
from pathlib import Path


# Silero VAD v6.2.1, src/silero_vad/data/silero_vad.jit (MIT).
SILERO_SHA256 = "e1122837f4154c511485fe0b9c64455f7b929c96fbb8d79fbdb336383ebd3720"
SILERO_BYTES = 2_272_526


def load_local_vad(torch):
    configured = os.environ.get("LOCALVOICE_VAD_PATH")
    if configured:
        asset = Path(configured)
    else:
        # Migration for existing installations. Read the verified weights
        # only; never execute hubconf.py or ask GitHub which branch is current.
        legacy = Path(torch.hub.get_dir())
        asset = legacy / "snakers4_silero-vad_master/src/silero_vad/data/silero_vad.jit"

    with asset.open("rb") as handle:
        # Hash and deserialize the very same bytes (the legacy path is mutable).
        data = handle.read(SILERO_BYTES + 1)
    if len(data) != SILERO_BYTES or hashlib.sha256(data).hexdigest() != SILERO_SHA256:
        raise ValueError("The local Silero VAD asset does not match its release digest.")

    model = torch.jit.load(io.BytesIO(data), map_location="cpu")
    return model.eval()
