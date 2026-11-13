# 实验性字幕说话人适配器测试

此测试在 DEBUG 条件下验证：未明确设置 `MORIQ_EXPERIMENTAL_SPEAKER=1` 时不创建适配器；仅接受实验支持的英文和中文（日语、韩语等仍拒绝）；公开双人录音经过真实本机 Whisper、真实说话人分离辅助进程、同源时间对齐后输出两个匿名说话人；辅助进程立即退出时，即使尚无字幕窗口也必须恰好报告一次错误。

准备本地构建的 [MORIQSpeakerEngine](../../Tools/SpeakerEngine/README.md)、单独取得的 Core ML 模型，以及按照 [多人分离研究](../../docs/SPEAKER_DIARIZATION_RESEARCH_2026-11-13.md) 中方法制作的公开双人 LibriSpeech 测试 WAV。项目内还需要 `Vendor/SpeechEngine/moriq-speech`、其 `ggml-base.bin` 模型及 `Vendor/MediaEngine/ffmpeg`；这些资源的分发及许可证须单独核对。本测试不下载模型或录音、不使用麦克风，不向在线服务发送声音。仅使用已授权的公开测试音频。

```sh
MORIQ_SPEAKER_HELPER=/absolute/path/to/MORIQSpeakerEngine \
MORIQ_SPEAKER_MODEL=/absolute/path/to/Sortformer_v2.1.mlmodelc \
MORIQ_SPEAKER_SAMPLE=/absolute/path/to/public-two-speaker.wav \
sh Tests/ExperimentalCaptionSpeakerAdapter/run.sh
```

2026-11-13 在 Apple Silicon 开发机以公开双人交替拼接录音运行：接受 1,081,440 个 16 kHz 样本，产生 112 个已归属词候选及 2 个匿名槽位；失败测试通过。音频快速输入而非按真实时间播放，候选可能重复；该结果不代表词级归属准确率、多人重叠、真实会议、姓名识别或端到端延迟。门限 `0.7 / 0.2` 仅用于测试，未校准为生产默认。适配器尚未接入正式应用，模型完整性、许可和 Intel 兼容性仍待处理。

## 公开四人中文音频实时速率检查

使用公开中文四人样本（参见 [多人分离研究](../../docs/SPEAKER_DIARIZATION_RESEARCH_2026-11-13.md)），通过 `MORIQ_PUBLIC_CJK_AUDIO` 指定 WAV，并设置同样的 `MORIQ_SPEAKER_HELPER` 和 `MORIQ_SPEAKER_MODEL`，运行 `sh Tests/ExperimentalCaptionSpeakerAdapter/run-cjk.sh`。测试通过 0.2 秒 PCM 块按单调时钟 1× 投喂，不打开音频设备。

2026-11-13 单次 Apple Silicon 本机：909,771 个 16 kHz 样本、7 个 final 窗口、119 个中文 token 文本片段，其中 82 个有匿名槽位、37 个未知、4 个槽位；首条原文在输入开始后 2.02 秒、首个归属 2.87 秒、首个归属相对该片段结束时间 2.07 秒。该数值仅是一轮包含模型启动的实测，不能推广为延迟分布；片段会随滚动窗口重复，无法证明四个 ID 对应四个不同真实人物，也不代表准确率/DER、姓名识别或重叠发言质量。`0.7/0.2` 仅为未校准的测试参数。该测试也未覆盖真实麦克风、网络通话或多来源统一时钟。
