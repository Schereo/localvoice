"""Offline model catalog and explicit downloads for LocalVoice (stdlib only).

Run this file with Python 3.11:

* ``status`` prints {"models": [...]} with id, name, bytes, source (HF repo
  slug), revision, status ("installed"/"not-installed"), path, location
  ("localvoice"/"hf-cache"), removable, available, and availability_reason
  (empty when available). Missing paths/locations are null.
* ``resolve MODEL`` prints {"event":"success","ok":true,"id":...,"path":...,
  "location":...}. In Python, ``resolve_model(model_id)`` returns an absolute
  Path, or raises ModelStoreError (unknown ID or no verified local model).
* ``download MODEL`` streams flushed JSON lines: event "progress" with id,
  downloaded_bytes and total_bytes, then the same success event as resolve.
  An available model with a verified existing install (including HF cache)
  returns success without network, copying, or progress events.
* ``remove MODEL`` prints event "success" with ok, id and a boolean removed.
  Removing an absent model is a no-op; removing a shared HF model is an error.
  If both copies exist, only LocalVoice's copy is removed.

Failures print event "error" with ok=false, id (null if omitted), and error,
and exit nonzero. SIGTERM/SIGINT during a CLI download clean up staging, exit
143/130, and report cancellation if stdout is still open. Publication happens
by rename only after verification; canceling after publication may leave a
complete model installed. Neither status nor resolve uses the network.

``LOCALVOICE_MODELS_DIR`` overrides ~/Library/Application Support/LocalVoice/
Models. HF_HUB_CACHE, HUGGINGFACE_HUB_CACHE, HF_HOME and XDG_CACHE_HOME follow
Hugging Face's precedence. Local files are checked against the pinned hashes;
the digest is reused within a process only while the file identity is unchanged.
"""

from __future__ import annotations

import argparse
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass
import fcntl
from functools import lru_cache
import hashlib
from http.client import HTTPException
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import ssl
import stat
import sys
import time
from urllib.parse import quote, urlsplit
from urllib.request import HTTPSHandler, HTTPRedirectHandler, build_opener
from uuid import uuid4


_OWNER_FILE = ".localvoice-model"


@dataclass(frozen=True)
class Asset:
    name: str
    size: int
    sha256: str

    def __post_init__(self):
        if any(part in ("", ".", "..", _OWNER_FILE) for part in self.name.split("/")):
            raise ValueError(f"Invalid model asset path: {self.name}")


@dataclass(frozen=True)
class Model:
    id: str
    name: str
    repo: str
    revision: str
    assets: tuple[Asset, ...]
    minimum_macos: int | None = None
    allow_matching_hf_revisions: bool = True

    @property
    def size(self):
        return sum(asset.size for asset in self.assets)


def _compiled_assets(bundle, files):
    return tuple(Asset(f"{bundle}.mlmodelc/{name}", size, digest)
                 for name, size, digest in files)


# Files shared by all three pinned Parakeet revisions. Small files are hashed
# from raw Git blobs (or resolved bytes for LFS); large sizes and SHA256s come
# from the LFS entries in the pinned Hugging Face trees.
_PARAKEET_COMMON = _compiled_assets("Preprocessor", (
    ("analytics/coremldata.bin", 243, "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
    ("coremldata.bin", 486, "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
    ("metadata.json", 2841, "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
    ("model.mil", 28181, "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
    ("weights/weight.bin", 491072, "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
)) + (
    Asset("parakeet_vocab.json", 151122, "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
)


# The Whisper revisions, sizes, and LFS hashes are from the Hugging Face model
# API. The config SHA256s were computed from the small pinned raw files.
# This Q4 repo has weights.npz, which mlx-whisper 0.4.3 can load; it does not
# recognize the similarly named -4bit repo's model.safetensors.
MODELS = {
    model.id: model for model in (
        Model(
            "whisper-turbo-fp16", "Whisper Large V3 Turbo (FP16)",
            "mlx-community/whisper-large-v3-turbo",
            "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb",
            (
                Asset("config.json", 268,
                      "b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379"),
                Asset("weights.safetensors", 1613977612,
                      "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6"),
            ),
        ),
        Model(
            "whisper-turbo-q4", "Whisper Large V3 Turbo (Q4)",
            "mlx-community/whisper-large-v3-turbo-q4",
            "660c343bbf4e52ac257f0b7d952e5388e6f93bef",
            (
                Asset("config.json", 341,
                      "538e24557b8f9bc504700add5e7bbe32087c2353001ff563e64772ad4398671a"),
                Asset("weights.npz", 463664664,
                      "862bbc832b05f3f4ec19dd632b701d61a6d3f5c7906360a10d72a79870642a80"),
            ),
        ),
        # FluidAudio v0.17.7 AsrModels.loadLocal, with the default .int8
        # encoder for v3. No alternative encoders, CTC head or .mlpackages.
        Model(
            "parakeet-v3", "Parakeet V3",
            "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
            _compiled_assets("Encoder", (
                ("analytics/coremldata.bin", 243, "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
                ("coremldata.bin", 485, "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
                ("metadata.json", 2921, "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
                ("model.mil", 959769, "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
                ("weights/weight.bin", 445187200, "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
            )) + _compiled_assets("Decoder", (
                ("analytics/coremldata.bin", 243, "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
                ("coremldata.bin", 554, "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
                ("metadata.json", 3427, "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
                ("model.mil", 13110, "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
                ("weights/weight.bin", 23604992, "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
            )) + _compiled_assets("JointDecisionv3", (
                ("analytics/coremldata.bin", 243, "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
                ("coremldata.bin", 521, "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
                ("metadata.json", 3453, "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
                ("model.mil", 11775, "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
                ("weights/weight.bin", 12642764, "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
            )) + _PARAKEET_COMMON,
            minimum_macos=14,
        ),
        Model(
            "parakeet-ultra", "Parakeet Ultra",
            "FluidInference/parakeet-ultra-coreml",
            "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
            _compiled_assets("Encoder", (
                ("analytics/coremldata.bin", 243, "d87101d824d6723cf95304da33755c3c60e762663b9ef2b0c4bd0aa166a09a0d"),
                ("coremldata.bin", 514, "397a84a4062f563cbc5f56077c674f09a61d85be5090f61d2f1932afb92ac0fe"),
                ("model.mil", 1002653, "f5d601568a4171d99a314c0fe3f6bc67715da2623732a3fb566e050ea83e5848"),
                ("weights/weight.bin", 594211328, "315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b"),
            )) + _compiled_assets("Decoder", (
                ("analytics/coremldata.bin", 243, "fe92b6cfaa012abd5248c0bc877832f19807015abffc60d87b8ccc8ccb48b3b5"),
                ("coremldata.bin", 560, "3b06e66768f0df7e21795f50e2b29300e33eeb1a2579dc42c695279c2d308497"),
                ("model.mil", 13110, "956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955"),
                ("weights/weight.bin", 23604992, "02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4"),
            )) + _compiled_assets("JointDecisionv3", (
                ("analytics/coremldata.bin", 243, "68d38ca646aebafa7a9329e2efda50f5767c49e89fdb5f77f212072bb66f97c4"),
                ("coremldata.bin", 592, "5e3af5a4ce686f6c237cadbd9284e10d333bc0e1546633cd0e430e6194044bc4"),
                ("model.mil", 11777, "791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0"),
                ("weights/weight.bin", 12642764, "3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25"),
            )) + _PARAKEET_COMMON,
            minimum_macos=14,
        ),
        Model(
            "parakeet-redux", "Parakeet Redux",
            "FluidInference/parakeet-redux-coreml",
            "8c5ef97a29cd120dc76b354b3f22b7fec3b486f9",
            _compiled_assets("Encoder", (
                ("analytics/coremldata.bin", 243, "7862e972e09315df099d4bfd320743bf106acbf7fe4343317f9de45b0635d7b7"),
                ("coremldata.bin", 506, "ca0b212fe3c06c3ccd35e508fa61e4dfaad19dd0c55b82e4f5bf8711e7758fd9"),
                ("model.mil", 965906, "165487e314ed93c4a44dfec99d57be4e436e7c3dba6eef49fd3f0daf9de6d0d4"),
                ("weights/weight.bin", 182389312, "adbb5550dc6488717d3a1407b53122fbdb1af5e99c330ee20f8d8cfd9ec49252"),
            )) + _compiled_assets("Decoder", (
                ("analytics/coremldata.bin", 243, "7f24e7248d57024c6f1c5a2ea306f4a6a89db45a363218523bb6410c4b1aecf0"),
                ("coremldata.bin", 560, "422da51d983e93a3e48cd6d46a17d6c32844452414c8e242fb0caaca2b8af5ed"),
                ("model.mil", 13110, "956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955"),
                ("weights/weight.bin", 23604992, "6c6c88c23ee5492a6b229e8cc636ddadb2b01ae0dd559d9cb63123bebf507d77"),
            )) + _compiled_assets("JointDecisionv3", (
                ("analytics/coremldata.bin", 243, "fc857a756b8c9c9f31aa9e1062766cc0a82ac035ef369d6e1cbe97184921479c"),
                ("coremldata.bin", 592, "611ea653e2adede7cc1cfe70da36296844f97e95e2c7dd961d45230e5599389d"),
                ("model.mil", 11777, "791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0"),
                ("weights/weight.bin", 12642764, "73b0288acd115fc4c36038f66b6cbf49233182488febf5d8c787bea4009535f7"),
            )) + _PARAKEET_COMMON,
            minimum_macos=15,
        ),
        # FluidAudio v0.17.7's local multilingual manager computes log-mel in
        # Swift and can decode with the fused B1 bundle alone. Both compiled
        # graphs target ios17, with explicit cache tensors (no macOS 15 MLState).
        Model(
            "nemotron-streaming", "Nemotron Streaming Multilingual",
            "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
            "a70b9d1c33594f1f4cf3f4eca9b4a0a8f44a9f59",
            _compiled_assets("multilingual/2240ms/encoder", (
                ("analytics/coremldata.bin", 243, "af569fd95237bdf8b91d38094691bfc990fcf3534316fa615bac5964c02809e4"),
                ("coremldata.bin", 573, "d5471a4edf55ce02dab51e5d01c86b419a7659bcdd6aac216ba6f0b795eae8bf"),
                ("model.mil", 1010788, "3ee65463908bbc06c92691ea9172499aea3f7ae4ba619d39783c4a639936fae5"),
                ("weights/weight.bin", 565336640, "2e00be98049a22e095452c020f183d2b23728e145cc814ba031436931b4f2e8f"),
            )) + _compiled_assets("multilingual/2240ms/decoder_joint", (
                ("analytics/coremldata.bin", 243, "8a8e98a54ed1f16c3d5125816a002b991e167d620beb8fcc557f26d9a1c092f8"),
                ("coremldata.bin", 454, "6404b542fb5d5faa79648fc96a79a0b981cbd087df0378adefd1f45ae56dd86e"),
                ("model.mil", 15801, "62144df8c1928d571c1df508a576f2d574a6bd6b1f2dba7f3f15cf9605805d6a"),
                ("weights/weight.bin", 48782272, "01f21eb747fbc53bd0ed7efebea1bf0aa655ebf2816f21d0bb6554c9b7fcfc0b"),
            )) + (
                Asset("multilingual/2240ms/metadata.json", 3005,
                      "070ae181941003ff3e7d7ff8e5c5d47aebd026e8458549cef0c9a6803dbec004"),
                Asset("multilingual/2240ms/tokenizer.json", 284969,
                      "fb70c8fcb6472cda2bdb799b156a8941e72762344a7c636d3b1275f1d53c4a6b"),
            ),
            minimum_macos=14,
            allow_matching_hf_revisions=False,
        ),
    )
}

_CHUNK = 1024 * 1024
_TIMEOUT = 30


class ModelStoreError(Exception):
    """The requested model operation could not be completed."""


class _Terminated(KeyboardInterrupt):
    pass


def _model(model_id):
    try:
        return MODELS[model_id]
    except (KeyError, TypeError):
        raise ModelStoreError(f"Unknown model ID: {model_id}") from None


def coreml_worker_path(model_id) -> Path:
    """Return the shared worker executable for a supported Core ML model."""
    model = _model(model_id)
    if model.minimum_macos is None:
        raise ModelStoreError(f"Not a Core ML model: {model.id}")
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise ModelStoreError(f"{model.name} requires an Apple Silicon Mac.")
    major = platform.mac_ver()[0].partition(".")[0]
    if not major.isdigit() or int(major) < model.minimum_macos:
        raise ModelStoreError(f"{model.name} requires macOS {model.minimum_macos} or later.")
    configured = os.environ.get("LOCALVOICE_PARAKEET_WORKER")
    if not configured:
        raise ModelStoreError("The LocalVoice Core ML worker is not configured.")
    try:
        worker = Path(configured).expanduser().absolute()
        if worker.is_file() and os.access(worker, os.X_OK):
            return worker
    except (OSError, RuntimeError, ValueError):
        pass
    raise ModelStoreError("The configured LocalVoice Core ML worker is not executable.")


# The runtime already imports this name; both model families use the worker.
parakeet_worker_path = coreml_worker_path


def _store_dir():
    override = os.environ.get("LOCALVOICE_MODELS_DIR")
    path = Path(override) if override else Path.home() / "Library/Application Support/LocalVoice/Models"
    return path.expanduser().absolute()


def _hf_cache_dir():
    override = os.environ.get("HF_HUB_CACHE", os.environ.get("HUGGINGFACE_HUB_CACHE"))
    if override is not None:
        return Path(override).expanduser().absolute()
    cache_home = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    hf_home = Path(os.environ.get("HF_HOME", cache_home / "huggingface"))
    return hf_home.expanduser().absolute() / "hub"


def _fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


@lru_cache(maxsize=128)
def _digest(path, fingerprint):
    digest = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        if _fingerprint(os.fstat(stream.fileno())) != fingerprint:
            raise ModelStoreError(f"File changed before verification: {path.name}")
        while chunk := stream.read(_CHUNK):
            digest.update(chunk)
        if _fingerprint(os.fstat(stream.fileno())) != fingerprint:
            raise ModelStoreError(f"File changed during verification: {path.name}")
    return digest.hexdigest()


@lru_cache(maxsize=32)
def _asset_tree(model):
    tree = {}
    for asset in model.assets:
        *parents, leaf = asset.name.split("/")
        children = tree
        for part in parents:
            children = children.setdefault(part, {})
        children[leaf] = None
    return tree


def _verified_tree(directory, tree, *, exact=False):
    if not stat.S_ISDIR(directory.lstat().st_mode):
        return False
    if exact and {child.name for child in directory.iterdir()} != tree.keys():
        return False
    return all(_verified_tree(directory / name, subtree, exact=True)
               for name, subtree in tree.items() if subtree is not None)


def _verified(directory, model, blobs=None):
    try:
        tree = _asset_tree(model)
        if not _verified_tree(directory, tree):
            return False
        # An unverified extra weights file can take precedence in MLX loaders.
        # FluidAudio's local loader also probes for an optional CTC head.
        shadowing = set()
        if model.id.startswith("parakeet-"):
            shadowing = {"CtcHead.mlmodelc"}
        elif model.minimum_macos is None:
            shadowing = {"model.safetensors", "weights.safetensors", "weights.npz"}
        for name in shadowing - tree.keys():
            unverified = directory / name
            if unverified.exists() or unverified.is_symlink():
                return False
        for asset in model.assets:
            path = directory / asset.name
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                if blobs is None or not stat.S_ISDIR(blobs.lstat().st_mode):
                    return False
                # HF snapshots link leaf files directly to their repo's blobs.
                # Normalize relative ".." components without following links.
                target = Path(os.path.abspath(path.parent / path.readlink()))
                if target.parent != blobs or path.resolve(strict=True) != target:
                    return False
                path = target
                info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_size != asset.size:
                return False
            if _digest(path, _fingerprint(info)) != asset.sha256:
                return False
        return True
    except (OSError, RuntimeError, ModelStoreError):
        return False


def _owned(directory, model):
    try:
        with _open_directory(directory) as fd:
            return _owns_marker(fd, model)
    except OSError:
        return False


def _legacy_path(model):
    repo = _hf_cache_dir() / f"models--{model.repo.replace('/', '--')}"
    try:
        repo = repo.resolve(strict=True)
        snapshots = repo / "snapshots"
        if snapshots.is_symlink():
            return None
        pinned = snapshots / model.revision
        if _verified(pinned, model, repo / "blobs"):
            return pinned
        if not model.allow_matching_hf_revisions:
            return None
        # Older revisions may differ only in docs. Accept identical assets,
        # not an arbitrary ref such as "main" or an unverified blob name.
        for snapshot in sorted(snapshots.iterdir()):
            if snapshot != pinned and _verified(snapshot, model, repo / "blobs"):
                return snapshot
    except (OSError, RuntimeError):
        pass
    return None


def _locate(model):
    owned = _store_dir() / model.id
    if _owned(owned, model) and _verified(owned, model):
        return owned, "localvoice"
    legacy = _legacy_path(model)
    return (legacy, "hf-cache") if legacy is not None else (None, None)


def _resolve(model):
    path, location = _locate(model)
    if path is None:
        raise ModelStoreError(f"Model is not installed: {model.id}")
    return path, location


def resolve_model(model_id) -> Path:
    """Return a verified local directory, without downloads or filesystem writes."""
    return _resolve(_model(model_id))[0]


def _removal_error(destination, model):
    try:
        _inspect_owned(destination, model)
    except (ModelStoreError, OSError) as exc:
        return str(exc)
    return None


def _status():
    models = []
    for model in MODELS.values():
        path, location = _locate(model)
        reason = ""
        if model.minimum_macos is not None:
            try:
                coreml_worker_path(model.id)
            except ModelStoreError as exc:
                reason = str(exc)
        models.append({
            "id": model.id,
            "name": model.name,
            "bytes": model.size,
            "source": model.repo,
            "revision": model.revision,
            "status": "installed" if path is not None else "not-installed",
            "path": str(path) if path is not None else None,
            "location": location,
            "removable": _removal_error(_store_dir() / model.id, model) is None,
            "available": not reason,
            "availability_reason": reason,
        })
    return {"models": models}


@contextmanager
def _model_lock(root, model):
    # Keep the lock inode stable so simultaneous downloads/removals cannot
    # replace it and accidentally hold different locks for the same model.
    fd = os.open(root / f".{model.id}.lock",
                 os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ModelStoreError(f"Another operation is running for {model.id}") from None
        yield
    finally:
        os.close(fd)


@contextmanager
def _open_directory(path, *, dir_fd=None):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)
    try:
        yield fd
    finally:
        os.close(fd)


def _owns_marker(fd, model):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    expected = (model.id + "\n").encode("ascii")
    try:
        with os.fdopen(os.open(_OWNER_FILE, flags, dir_fd=fd), "rb") as marker:
            info = os.fstat(marker.fileno())
            return (stat.S_ISREG(info.st_mode) and info.st_size == len(expected)
                    and marker.read(len(expected) + 1) == expected)
    except OSError:
        return False


def _walk_owned(fd, tree, device, unexpected, *, remove):
    names = os.listdir(fd)
    if remove and _OWNER_FILE in names:
        # Retain the ownership marker until all assets have been removed.
        names.remove(_OWNER_FILE)
        names.append(_OWNER_FILE)
    for name in names:
        if name not in tree:
            raise unexpected
        entry = os.stat(name, dir_fd=fd, follow_symlinks=False)
        subtree = tree[name]
        if entry.st_dev != device:
            raise unexpected
        if subtree is None and stat.S_ISREG(entry.st_mode):
            if remove:
                os.unlink(name, dir_fd=fd)
        elif subtree is not None and stat.S_ISDIR(entry.st_mode):
            with _open_directory(name, dir_fd=fd) as child:
                if _fingerprint(os.fstat(child)) != _fingerprint(entry):
                    raise unexpected
                _walk_owned(child, subtree, device, unexpected, remove=remove)
            if remove:
                os.rmdir(name, dir_fd=fd)
        else:
            raise unexpected


def _inspect_owned(destination, model, *, remove=False):
    unowned = ModelStoreError(f"Not a LocalVoice-owned model directory: {destination}")
    tree = {**_asset_tree(model), _OWNER_FILE: None}
    unexpected = ModelStoreError(f"Model directory contains unexpected files: {destination}")
    with ExitStack() as stack:
        try:
            fd = stack.enter_context(_open_directory(destination))
        except OSError as exc:
            raise unowned from exc
        if not _owns_marker(fd, model):
            raise unowned
        info = os.fstat(fd)
        if (info.st_dev != destination.parent.stat().st_dev
                or _fingerprint(info) != _fingerprint(destination.lstat())):
            raise unexpected
        _walk_owned(fd, tree, info.st_dev, unexpected, remove=False)
        if remove:
            # Don't recursively delete whatever might appear after preflight.
            # Unlink only manifest leaves and remove only empty directories.
            _walk_owned(fd, tree, info.st_dev, unexpected, remove=True)
            if _fingerprint(os.fstat(fd)) != _fingerprint(destination.lstat()):
                raise unexpected
            destination.rmdir()


class _HTTPSRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlsplit(newurl).scheme.lower() != "https":
            raise ModelStoreError("Model download redirected away from HTTPS")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _open_https(url, *, timeout):
    try:
        import certifi
    except ImportError:
        context = ssl.create_default_context()
    else:
        # Relocatable runtime archives contain certifi but need not have a
        # system Python trust-store path. This keeps TLS verification enabled.
        context = ssl.create_default_context(cafile=certifi.where())
    return build_opener(HTTPSHandler(context=context), _HTTPSRedirects()).open(url, timeout=timeout)


def _fetch(model, asset, stage, advance):
    url = f"https://huggingface.co/{model.repo}/resolve/{model.revision}/{quote(asset.name)}"
    destination = stage / asset.name
    destination.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    written = 0
    with _open_https(url, timeout=_TIMEOUT) as response, destination.open("xb") as out:
        while chunk := response.read(_CHUNK):
            written += len(chunk)
            if written > asset.size:
                raise ModelStoreError(f"File exceeds expected size: {asset.name}")
            out.write(chunk)
            digest.update(chunk)
            advance(len(chunk))
    if written != asset.size:
        raise ModelStoreError(f"Incorrect file size: {asset.name}")
    if digest.hexdigest() != asset.sha256:
        raise ModelStoreError(f"SHA256 mismatch: {asset.name}")


def _sweep_stale_stages(root, model):
    """Delete staging folders a killed download left behind (up to 1.6 GB).

    Call only while holding the model lock: no other download of this model
    can be running then, so every matching folder is stale.
    """
    for stage in root.glob(f".{model.id}.download-*"):
        if stage.is_dir() and not stage.is_symlink():
            shutil.rmtree(stage, ignore_errors=True)


def _download(model, emit):
    if model.minimum_macos is not None:
        coreml_worker_path(model.id)
    path, location = _locate(model)
    if path is not None:
        return path, location
    root = _store_dir()
    root.mkdir(parents=True, exist_ok=True)
    destination = root / model.id
    with _model_lock(root, model):
        _sweep_stale_stages(root, model)
        path, location = _locate(model)
        if path is not None:
            return path, location
        replace = destination.exists() or destination.is_symlink()
        if replace:
            _inspect_owned(destination, model)

        downloaded = 0
        last_progress = -float("inf")

        def advance(count, force=False):
            nonlocal downloaded, last_progress
            downloaded += count
            now = time.monotonic()
            if force or now - last_progress >= 0.1:
                emit({"event": "progress", "id": model.id,
                      "downloaded_bytes": downloaded, "total_bytes": model.size})
                last_progress = now

        advance(0, force=True)
        stage = root / f".{model.id}.download-{uuid4().hex}"
        owns_stage = True
        try:
            try:
                stage.mkdir(mode=0o700)
            except FileExistsError:
                owns_stage = False
                raise
            for asset in model.assets:
                _fetch(model, asset, stage, advance)
            (stage / _OWNER_FILE).write_text(model.id + "\n", encoding="ascii")
            advance(0, force=True)
            if replace:
                _inspect_owned(destination, model, remove=True)
            if destination.exists() or destination.is_symlink():
                raise ModelStoreError(f"Model directory appeared during download: {destination}")
            stage.rename(destination)
            owns_stage = False
        finally:
            if owns_stage and stage.is_dir():
                shutil.rmtree(stage)
    return destination, "localvoice"


def _remove(model):
    root = _store_dir()
    destination = root / model.id
    if root.is_dir():
        with _model_lock(root, model):
            _sweep_stale_stages(root, model)
            if destination.exists() or destination.is_symlink():
                _inspect_owned(destination, model, remove=True)
                return True
    if _legacy_path(model) is not None:
        raise ModelStoreError("This model is in the shared Hugging Face cache and cannot be removed by LocalVoice")
    return False


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ModelStoreError(message)


def _emit(payload):
    print(json.dumps(payload), flush=True)


def _terminate(signum, frame):
    # Let an in-flight download unwind through its staging and lock contexts.
    signal.signal(signum, signal.SIG_IGN)
    raise _Terminated


def main(argv=None):
    parser = _Parser(description="Manage LocalVoice's offline models")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status")
    for command in ("download", "remove", "resolve"):
        subparsers.add_parser(command).add_argument("model_id")
    model_id = None
    try:
        args = parser.parse_args(argv)
        if args.command == "status":
            _emit(_status())
            return 0
        model_id = args.model_id
        model = _model(model_id)
        success = {"event": "success", "ok": True, "id": model.id}
        if args.command == "remove":
            success["removed"] = _remove(model)
        else:
            if args.command == "download":
                path, location = _download(model, _emit)
            else:
                path, location = _resolve(model)
            success.update(path=str(path), location=location)
        _emit(success)
        return 0
    except (KeyboardInterrupt, ModelStoreError, OSError, HTTPException) as exc:
        interrupted = isinstance(exc, KeyboardInterrupt)
        try:
            _emit({"event": "error", "ok": False, "id": model_id,
                   "error": "Cancelled" if interrupted else str(exc)})
        except BrokenPipeError:
            pass
        if interrupted:
            return 143 if isinstance(exc, _Terminated) else 130
        return 1


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _terminate)
    sys.exit(main())
