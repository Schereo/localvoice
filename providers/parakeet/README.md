# Parakeet Worker

Optional Apple Silicon executable for offline Parakeet and Nemotron inference with FluidAudio 0.17.7. Requires Swift 6.2 or later to build. Run v3, Ultra, and Nemotron on macOS 14 or later; Redux requires macOS 15 or later.

## Build

From the LocalVoice repository root with `$scratch` set to an absolute temporary directory:

```sh
swift build --package-path providers/parakeet --scratch-path "$scratch/build" \
  --cache-path "$scratch/cache" --build-system native --configuration release \
  --force-resolved-versions --product localvoice-parakeet
swift build --package-path providers/parakeet --scratch-path "$scratch/build" \
  --cache-path "$scratch/cache" --build-system native --configuration release --show-bin-path
swiftc -swift-version 6 providers/parakeet/Sources/ParakeetWorker/Protocol.swift \
  providers/parakeet/Tests/ProtocolTests.swift -o "$scratch/protocol-tests"
"$scratch/protocol-tests"
```

The first build can fetch Swift dependencies and a checksum-pinned NeMo XCFramework. NeMo is disabled and not linked. `FluidAudio_FluidAudio.bundle` is the only resource sidecar; it holds TTS data that the Parakeet worker does not use. Retain the pinned FluidAudio checkout's `LICENSE` and `ThirdPartyLicenses/` with distributed binaries.

## Local Models

Pass a verified, absolute directory containing `parakeet_vocab.json` and the complete `Preprocessor.mlmodelc/`, `Encoder.mlmodelc/`, `Decoder.mlmodelc/`, and `JointDecisionv3.mlmodelc/` directory trees from the chosen variant:

| Variant | Hugging Face repository | Model revision |
| --- | --- | --- |
| `v3` | `FluidInference/parakeet-tdt-0.6b-v3-coreml` | `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe` |
| `ultra` | `FluidInference/parakeet-ultra-coreml` | `95eaa59a39d4394f047a4dc5cce480388a60d1b6` |
| `redux` | `FluidInference/parakeet-redux-coreml` | `8c5ef97a29cd120dc76b354b3f22b7fec3b486f9` |

The worker never downloads assets. The encoder uses `.cpuAndGPU`; the preprocessor, decoder, and joint use `.cpuOnly`.

For `nemotron`, pass the verified **root** of `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML` at revision `a70b9d1c33594f1f4cf3f4eca9b4a0a8f44a9f59`. The worker opens `multilingual/2240ms/` under that root. This tier supplies `metadata.json`, `tokenizer.json`, and `encoder.mlmodelc/`, `decoder_joint.mlmodelc/`, `decoder.mlmodelc/`, `joint.mlmodelc/`, and `preprocessor.mlmodelc/`. FluidAudio computes mel features in Swift and does not use the compiled preprocessor. The Nemotron encoder uses `.cpuAndGPU`; the fused decoder and other components use `.cpuOnly`.

## Protocol

Start `localvoice-parakeet <v3|ultra|redux> <absolute model directory>`. After loading models once, stdout emits `{"event":"ready"}`. A startup failure instead emits an `error` event and exits nonzero.

Send one newline-terminated `{"pcm":"..."}` per utterance. The payload is base64 of raw little-endian mono float32 PCM sampled at 16 kHz, at most 30 seconds. Each line receives `{"event":"result","text":"..."}` or `{"event":"error","error":"..."}`. Decoder state is fresh for each utterance; the same process handles subsequent requests until stdin closes. Stdout carries only protocol events.

`localvoice-parakeet nemotron <absolute model root>` uses the same response events with a streaming request format:

| Request | Result text |
| --- | --- |
| `{"command":"start","language":"de"}` | Empty. Resets the session and selects `de-DE`; `en` selects `en-US`, and `auto` enables automatic language selection. |
| `{"command":"chunk","pcm":"..."}` | Cumulative partial transcript. PCM encoding and per-request limit are unchanged. |
| `{"command":"finish"}` | Cumulative final transcript. Flushes any audio left in the current window and ends the session. |

The 2240 ms model decodes each full **35,840-sample** window. Smaller requests are buffered until a full window is available; use the returned text to replace the previous partial, not append to it.

## Offline Smoke Test

Provide a verified model directory and a speech fixture in the same raw PCM format:

```sh
/usr/bin/ruby providers/parakeet/smoke-worker.rb \
  "$bin_path/localvoice-parakeet" v3 "$model_directory" "$pcm_fixture" "expected phrase"
```

Run for each variant on a supported OS. The smoke test blocks network access for the worker, checks recovery from malformed input, and requires a matching transcription twice in one session. It reports timing without printing transcripts.

For `nemotron`, use a speech fixture longer than a 2240 ms window and optionally pass `de`, `en`, or `auto` after the expected phrase. The test sends consecutive native windows and requires a partial result before `finish`.
