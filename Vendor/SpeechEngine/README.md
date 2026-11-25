# Local speech engine prototype

`moriq-speech` is a statically linked arm64/x86_64 helper adapted from the rolling-window approach in whisper.cpp `examples/stream/stream.cpp`, upstream commit `d2c6f05a46dacf663e357bcf0ed40f542a72825d`. Upstream is MIT; see LICENSE.whisper.cpp. It reads 16 kHz mono float32 PCM from stdin, writes partial/final caption lines to stdout, and does not open a microphone or store audio. The helper source is `main.cpp`.

The multilingual GGML base model is bundled for offline use, with a verified download fallback from https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin. Its SHA-256 is `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`, size 147951465 bytes. Whisper's model weights are MIT licensed; see LICENSE.whisper-model and https://github.com/openai/whisper. This is an evaluation candidate, not a claim of competitive transcription quality.


发行验证（2026-11-12）：字幕辅助程序基于上游固定提交 `d2c6f05a46dacf663e357bcf0ed40f542a72825d` 和本目录 main.cpp 构建，arm64 与 x86_64 最低版本均为 macOS 15.0。二进制 SHA-256：`bbc7020ba7d48b9723791f421b8c5f00a825f4caf90dccf0fc29ca4b5d5f13b4`。模型 `ggml-base.bin` 大小 147951465 字节，SHA-256：`60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`。合成音频在两个架构运行通过（x86_64 使用 Rosetta）；尚未在实体 Intel 或 macOS 15 上验收。模型许可见 LICENSE.whisper-model。
