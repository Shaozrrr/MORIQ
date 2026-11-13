# Local speech engine prototype

`moriq-speech` is a statically linked arm64/x86_64 helper adapted from the rolling-window approach in whisper.cpp `examples/stream/stream.cpp`, upstream commit `d2c6f05a46dacf663e357bcf0ed40f542a72825d`. Upstream is MIT; see LICENSE.whisper.cpp. It reads 16 kHz mono float32 PCM from stdin, writes partial/final caption lines to stdout, and does not open a microphone or store audio. The helper source is `main.cpp`.

The multilingual GGML base model is bundled for offline use, with a verified download fallback from https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin. Its SHA-256 is `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`, size 147951465 bytes. Whisper's model weights are MIT licensed; see LICENSE.whisper-model and https://github.com/openai/whisper. This is an evaluation candidate, not a claim of competitive transcription quality.


发行验证（2026-11-12）：字幕辅助程序基于上游固定提交 `d2c6f05a46dacf663e357bcf0ed40f542a72825d` 和本目录 main.cpp 构建，arm64 与 x86_64 最低版本均为 macOS 15.0。二进制 SHA-256：`bbc7020ba7d48b9723791f421b8c5f00a825f4caf90dccf0fc29ca4b5d5f13b4`。模型 `ggml-base.bin` 大小 147951465 字节，SHA-256：`60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`。合成音频在两个架构运行通过（x86_64 使用 Rosetta）；尚未在实体 Intel 或 macOS 15 上验收。模型许可见 LICENSE.whisper-model。

2026-11-13（首版，已由下段替代）：helper 新增可选 `--word-timestamps` 协议，使用同一上游提交的 `whisper_full_get_token_data` 推理结果。兼容旧的 `P/F` 文本行；启用时额外输出 `B` 窗口、`W` 英文词（UTF-8 的十六进制）及 `E` 结束。时间为本进程 16 kHz stdin 样本偏移，只对连续实际接收的 PCM 有效，不能直接当作跨音源时钟。Swift 桥启用时间回调时队列溢出立即停止并报告，避免静默丢帧后错位。非英文暂不输出词级时间；重叠窗口、推理修正、词边界和采集 PTS 到重采样时钟映射仍需上层处理，不应据此声称已准确识别说话人。二进制双架构 minOS 15.0 SHA-256：`933277f06337431661c7d2987c00d8285499cb8b0bf06072f898934face4409a`。使用 LibriSpeech 公开语音验证两个时间窗口、PCM 偏移连续、积压拒绝与 x86_64 Rosetta；未做实体 Intel 或逐词标注误差验收。

2026-11-13 CJK 更新：可选时间协议在 `zh`、`ja`、`ko` 下输出有效 UTF-8 token 文本片段，跨 token UTF-8 片段使用其真实模型 t0/t1 范围，任一组成 token 零时长或无效时该片段不参与归属；不能按字拆解多字 token，也不能声称逐词/逐字时间准确。原有 P/F 文本行不变。公开中文音频已做 helper→Swift 桥测试及开关前后 P/F 原文一致检查，英语与旧协议回归通过；x86_64 运行使用 Rosetta，尚未在真实 Intel 或 macOS 15 上验收；日语、韩语尚无真实音频测试。最新二进制双架构 minOS 15.0 SHA-256：`4085f37ec9dfdf741d2d92a267589a2e243ebe79205ea6e96a641a968cd4ad4e`。
