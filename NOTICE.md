# Third-party notice

This repository includes modified files from [ctrlSPEAK](https://github.com/patelnav/ctrlspeak) version 1.8.0.

ctrlSPEAK is Copyright (c) Nav Patel and distributed under the MIT License. The modified files are included under the same terms. The custom Swift recording overlay and installation scripts are also distributed under the repository's MIT License.

## Parakeet

The optional Core ML worker uses [FluidAudio](https://github.com/FluidInference/FluidAudio). See the staged FluidAudio license for the worker's library terms.

[Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) is by NVIDIA under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) and [Parakeet Redux](https://huggingface.co/moondream/parakeet-redux) are adaptations by Moondream under the same license. LocalVoice fetches the converted Core ML assets from Fluid Inference, not the original training checkpoints. Models are installed separately on request, not included in the app download.

[Nemotron 3.5 ASR Streaming](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) is by NVIDIA. The [Fluid Inference Core ML conversion](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML) specifies the [OpenMDW 1.1 license](https://openmdw.ai/license/1-1/). Like Parakeet, these weights are not bundled in the app.

[Qwen3-ASR 1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) is by the Qwen team at Alibaba Cloud under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). LocalVoice fetches the [8-bit MLX conversion](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit) from the MLX Community and runs it with [mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr) (Apache 2.0). Like the other models, these weights are not bundled in the app.
